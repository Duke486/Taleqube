import Foundation
import Observation

enum CloudKeyStore {
    private static let name = "cloud.libraryKey"
    static func load(read:(String) throws -> String = Credentials.readChecked) throws -> CloudKeyMaterial? {
        let encoded = try read(name)
        return encoded.isEmpty ? nil : try CloudKeyMaterial.decode(encoded)
    }
    static func install(_ material:CloudKeyMaterial,read:(String) throws -> String = Credentials.readChecked,
                        write:(String,String) throws -> Void = Credentials.write) throws {
        try material.validate()
        if let current = try load(read:read), current != material {
            throw S3Failure.message("本机已有不同的加密资料库密钥，不能直接覆盖")
        }
        try write(name,material.encoded())
    }
}

struct CloudQueueCategory:Identifiable {
    let id:String
    var count:Int
    var bytes:Int
}

@MainActor @Observable final class CloudSync {
    static let shared = CloudSync()
    var configuration:S3Configuration
    var phase = "未启用"
    var encryptedLibraryID:String?
    var credentialsPending = false
    var running = false
    var importingBackup = false
    var completed = 0
    var total = 0
    var pending = 0
    var conflicts = 0
    var conflictRows:[CloudConflict] = []
    var deletedItems:[CloudDeletedItem] = []
    var deliveryHistory:[Delivery] = []
    var transferred = 0
    var traffic = S3Traffic()
    var queueCategories:[CloudQueueCategory] = []
    var lastSuccess:Date?
    var error:String?
    var events:[String] = []
    @ObservationIgnored var makeTransport:@Sendable (S3Configuration) throws -> S3Transport = { config in
        S3Transport(config:config,access:try Credentials.readChecked("cloud.access"),secret:try Credentials.readChecked("cloud.secret"))
    }
    @ObservationIgnored var makeEncryptedMaterial:@Sendable () throws -> CloudKeyMaterial? = { nil }
    @ObservationIgnored private var tracker:TrackingStore?
    @ObservationIgnored private var loop:Task<Void,Never>?
    @ObservationIgnored private var credentialObserver:NSObjectProtocol?
    @ObservationIgnored private var credentialTask:Task<Void,Never>?
    @ObservationIgnored private var associationTask:Task<Void,Never>?
    @ObservationIgnored private var rerun = false
    @ObservationIgnored private var lastCheck = Date.distantPast
    @ObservationIgnored private let preferences:UserDefaults
    nonisolated static let prefix = "anishelf/v1/journal/"
    init(preferences:UserDefaults = .standard) {
        self.preferences = preferences
        configuration = preferences.data(forKey:"cloud.configuration").flatMap { try? JSONDecoder().decode(S3Configuration.self,from:$0) } ?? S3Configuration()
        lastSuccess = preferences.object(forKey:"cloud.lastSuccess") as? Date
        events = preferences.stringArray(forKey:"cloud.events") ?? []
        phase = configuration.enabled ? "等待同步" : "未启用"
    }
    func reloadAfterImport(_ tracker:TrackingStore) {
        configuration = preferences.data(forKey:"cloud.configuration").flatMap { try? JSONDecoder().decode(S3Configuration.self,from:$0) } ?? S3Configuration()
        encryptedLibraryID = try? tracker.cloudStorage().db.state("cloud.encryptedLibrary")
        lastSuccess = preferences.object(forKey:"cloud.lastSuccess") as? Date
        events = preferences.stringArray(forKey:"cloud.events") ?? []
        phase = configuration.enabled ? "等待同步" : "未启用"
    }
    func start(_ tracker:TrackingStore,automatic:Bool = true) {
        self.tracker = tracker
        encryptedLibraryID = try? tracker.cloudStorage().db.state("cloud.encryptedLibrary")
        guard automatic, loop == nil else { return }
        tracker.cloudChange = { [weak self] trigger in self?.schedule(trigger) }
        credentialObserver = NotificationCenter.default.addObserver(forName:Credentials.didChange,object:nil,queue:nil) { [weak self] notification in
            guard let name = notification.object as? String, Credentials.names.contains(name) else { return }
            Task { @MainActor [weak self] in self?.credentialsChanged() }
        }
        loop = Task { [weak self] in
            guard let self else { return }
            if configuration.enabled { await synchronize() }
            else {
                do {
                    let storage = try tracker.cloudStorage()
                    apply(try await Self.localReport(storage))
                } catch { self.error = error.localizedDescription }
            }
            while !Task.isCancelled {
                try? await Task.sleep(for:.seconds(2))
                guard configuration.enabled, !running, associationTask == nil, Date().timeIntervalSince(lastCheck) >= 30 else { continue }
                await synchronize()
            }
        }
    }

    func credentialsChanged() {
        credentialsPending = true
        credentialTask?.cancel()
        credentialTask = Task { [weak self] in
            do { try await Task.sleep(for:.seconds(1)) } catch { return }
            guard let self, configuration.enabled, let tracker else { return }
            do {
                let storage = try tracker.cloudStorage()
                credentialsPending = try await Self.credentialsNeedSync(storage)
                if credentialsPending { await synchronize() }
            } catch { self.error = error.localizedDescription }
        }
    }

    private nonisolated static func credentialsNeedSync(_ storage:CloudStorage) async throws -> Bool {
        try await Task.detached(priority:.utility) {
            let fields = try storage.settingsFields().filter { $0.key.hasPrefix("credential/") }
            let baseline = try storage.db.cloudBaseline(namespace:"settings").filter { $0.key.hasPrefix("credential/") }
            if fields != baseline { return true }
            return try storage.db.pendingCloudOperations().contains { $0.field.hasPrefix("settings/credential/") }
        }.value
    }

    private func schedule(_ trigger:CloudChangeTrigger) {
        guard configuration.enabled else { return }
        if trigger == .immediate {
            Task { await synchronize() }
        } else {
            associationTask?.cancel()
            associationTask = Task { [weak self] in
                do { try await Task.sleep(for:.seconds(10)) } catch { return }
                guard let self else { return }
                associationTask = nil
                await synchronize()
            }
        }
    }

    func save(_ value:S3Configuration,access:String,secret:String) async throws {
        guard !running else { throw S3Failure.message("请等待当前同步结束后修改连接") }
        running = true
        defer { running = false }
        try await saveConnection(value,access:access,secret:secret)
    }

    private func saveConnection(_ value:S3Configuration,access:String,secret:String) async throws {
        let encoded = try await Task.detached(priority:.utility) {
            if value.enabled { try value.validate(); guard !access.isEmpty,!secret.isEmpty else { throw S3Failure.message("请填写访问密钥") } }
            let oldAccess = try Credentials.readChecked("cloud.access"), oldSecret = try Credentials.readChecked("cloud.secret")
            do { try Credentials.write("cloud.access",access); try Credentials.write("cloud.secret",secret) }
            catch {
                let original = error
                do { try Credentials.write("cloud.access",oldAccess); try Credentials.write("cloud.secret",oldSecret) }
                catch { throw S3Failure.message("连接密钥保存及恢复失败，请重新填写：" + error.localizedDescription) }
                throw original
            }
            return try StorageJSON.data(value)
        }.value
        preferences.set(encoded,forKey:"cloud.configuration")
        configuration = value; phase = value.enabled ? "等待同步" : "已停用"; error = nil
        lastCheck = .distantPast
    }
    func restoreItem(_ id:String) async {
        await editJournal { try $0.restoreCloudItem(id) }
    }
    func resolve(_ field:String,operation:String) async {
        await editJournal { try $0.resolveCloudConflict(field:field,operationID:operation) }
    }
    func replaceCloudWithLocal() async { await run(reset:true) }
    func preferCloudConflicts() async { await run(preferRemote:true) }

    private func editJournal(_ mutation:@escaping @Sendable (LibraryDatabase) throws -> Void) async {
        guard !running, let tracker else { return }
        running = true; error = nil
        do {
            let storage = try tracker.cloudStorage()
            try await tracker.cloudMerge(storage,mutation:mutation)
            let (report,count) = try await Self.localEditReport(storage)
            apply(report); pending = count
        } catch { self.error = error.localizedDescription }
        running = false
        if configuration.enabled, error == nil || rerun {
            rerun = false
            await synchronize()
        }
    }

    private func log(_ text:String) {
        events.insert(Date().formatted(date:.omitted,time:.standard) + "  " + text,at:0)
        if events.count > 100 { events.removeLast(events.count-100) }
        preferences.set(events,forKey:"cloud.events")
    }
    func synchronize() async {
        if running {
            rerun = true
            return
        }
        await run()
    }

    func createEncryptedLibrary() async throws {
        guard !running, configuration.enabled, let tracker else { throw S3Failure.message("请先保存连接设置") }
        let storage = try tracker.cloudStorage()
        guard try storage.db.state("cloud.encryptedLibrary") == nil else { return }
        guard try CloudKeyStore.load() == nil else { throw S3Failure.message("已有资料库密钥，请使用恢复码加入") }
        let material = CloudKeyMaterial.generate()
        try CloudKeyStore.install(material)
        try storage.db.setState("cloud.encryptedLibrary",material.libraryID.lowercased())
        encryptedLibraryID = material.libraryID.lowercased()
        await run(reset:true)
        if let error { throw S3Failure.message(error) }
    }

    func joinEncrypted(material:CloudKeyMaterial,connection:S3SettingsTransfer? = nil,storeKey:(CloudKeyMaterial) throws -> Void) async throws {
        guard !running, (connection?.configuration.enabled ?? configuration.enabled), let tracker else { throw S3Failure.message("请先启用同步并等待当前操作结束") }
        try material.validate()
        let storage = try tracker.cloudStorage()
        let existing = try storage.db.state("cloud.encryptedLibrary")
        guard existing == nil || existing == material.libraryID.lowercased() else { throw S3Failure.message("本机已加入其他加密资料库") }
        running = true; error = nil; phase = "验证加密资料库"
        defer { running = false }
        do {
            let config = configuration, factory = makeTransport
            let transport = try await Task.detached(priority:.utility) {
                if let connection {
                    return S3Transport(config:connection.configuration,access:connection.access,secret:connection.secret)
                }
                return try factory(config)
            }.value
            let encrypted = try Self.encryptedTransport(transport,material:material,storage:storage)
            try await Self.verifyEncryptedLibrary(encrypted)
            try storeKey(material)
            if let connection {
                try await saveConnection(connection.configuration,access:connection.access,secret:connection.secret)
            }
            if existing == nil {
                let backup = try await tracker.cloudBackup()
                try await Task.detached(priority:.utility) {
                    try storage.captureMetadata(backup)
                    try storage.prepareEncryptedJoin(libraryID:material.libraryID)
                }.value
            }
            encryptedLibraryID = material.libraryID.lowercased()
            phase = "已加入加密资料库，等待同步"
        } catch {
            self.error = error.localizedDescription; phase = "加入加密资料库失败"
            throw error
        }
    }

    private func run(reset:Bool = false,preferRemote:Bool = false) async {
        guard !LocalReset.pending, !importingBackup, !running, configuration.enabled, let tracker else { return }
        running = true; error = nil; completed = 0; total = 0; transferred = 0; traffic = S3Traffic(); queueCategories = []; lastCheck = Date()
        defer {
            running = false
            if rerun {
                rerun = false
                Task { await synchronize() }
            }
        }
        let config = configuration, factory = makeTransport, materialFactory = makeEncryptedMaterial
        do {
            let storage = try tracker.cloudStorage()
            phase = "扫描云端提交"; log(phase)
            let transport = try await Task.detached(priority:.utility) { try factory(config) }.value
            let libraryID = try storage.db.state("cloud.encryptedLibrary")
            let material = try await Task.detached(priority:.utility) {
                let supplied = try materialFactory()
                guard let libraryID else { return supplied }
                guard let resolved = try supplied ?? CloudKeyStore.load(), resolved.libraryID.lowercased() == libraryID else {
                    throw S3Failure.message("缺少加密资料库密钥，请导入该资料库的恢复码")
                }
                return resolved
            }.value
            let encrypted = try material.map { try Self.encryptedTransport(transport,material:$0,storage:storage) }
            encryptedLibraryID = material?.libraryID.lowercased()
            defer { traffic = transport.traffic; transferred = traffic.total }
            try await Self.scan(transport,encrypted:encrypted,storage:storage,config:config) { [self] done,count,bytes in
                completed = done; total = count; transferred += bytes
                if count > 0 { phase = "下载 \(done)/\(count) 个提交" }
            }

            var resetContext:(CloudEpoch,Backup)?
            if reset {
                let local = try await tracker.cloudBackup()
                phase = "正在以本机版本覆盖云端"
                let (epoch,bytes) = try await Self.publishReset(local,transport:transport,encrypted:encrypted,storage:storage)
                transferred += bytes
                resetContext = (epoch,local)
            }
            phase = "应用云端差异"; log(phase)
            try await tracker.cloudMerge(storage,reset:resetContext)
            if preferRemote {
                try await tracker.cloudMerge(storage,mutation:{ try $0.preferRemoteCloudConflicts() })
            }
            phase = "准备上传本机修改"; log(phase)
            let local = try await tracker.cloudBackup()
            let report = try await Self.upload(local,transport:transport,encrypted:encrypted,storage:storage,
                destination:try config.destination(namespace:encrypted?.prefix ?? ""),breakdown:{ [self] categories in
                    queueCategories = categories
                }) { [self] uploaded,count,bytes in
                if uploaded == 0 { total = completed + count }
                completed += uploaded; pending = count-uploaded
                transferred += bytes
                if pending > 0 { phase = "正在上传 \(pending) 项修改" }
            }
            apply(report)
            if let encrypted, let material {
                do {
                    let before = transport.traffic
                    _ = try await Self.publishCheckpointIfNeeded(storage,encrypted:encrypted,libraryID:material.libraryID)
                    let after = transport.traffic
                    transferred += after.upload-before.upload + after.download-before.download + after.verification-before.verification + after.retryUpload-before.retryUpload + after.retryDownload-before.retryDownload
                } catch { log("检查点发布失败：" + error.localizedDescription) }
            }
            credentialsPending = try await Self.credentialsNeedSync(storage)
            if credentialsPending { rerun = true }
            lastSuccess = Date(); preferences.set(lastSuccess,forKey:"cloud.lastSuccess")
            phase = conflicts == 0 ? "已同步" : "已同步，\(conflicts) 项并发版本已保留"
            let measured = transport.traffic
            log(phase + " · 上传 \(measured.upload) B · 下载 \(measured.download) B · 校验 \(measured.verification) B · 列表 \(measured.listing) B · 重试 \(measured.retryUpload + measured.retryDownload) B")
        } catch { self.error = error.localizedDescription; phase = "同步未完成"; log(error.localizedDescription) }
    }

    private func apply(_ report:Report) {
        conflictRows = report.conflicts; conflicts = conflictRows.count
        deletedItems = report.deleted
        deliveryHistory = report.deliveries
    }

    private struct Report {
        let conflicts:[CloudConflict]
        let deleted:[CloudDeletedItem]
        let deliveries:[Delivery]
    }
    private nonisolated static func encryptedTransport(_ transport:S3Transport,material:CloudKeyMaterial,storage:CloudStorage) throws -> CloudEncryptedTransport {
        let destination = try transport.config.destination()
        func stateKey(_ key:String) -> String { "cloud.objectVersion/" + S3Signer.hex(Data((destination + "\u{0}" + key).utf8)) }
        return try CloudEncryptedTransport(transport:transport,material:material,
            cachedVersion:{ try storage.db.state(stateKey($0)) },
            saveVersion:{ try storage.db.setState(stateKey($0),$1) },
            cachedChunk:{ try storage.db.read(Data.self,collection:"cloud-chunk-cache",key:$0) },
            saveChunk:{ key,data in
                try storage.db.transaction {
                    try storage.db.put(data,collection:"cloud-chunk-cache",key:key)
                    let keys = try storage.db.keys("cloud-chunk-cache")
                    for old in keys.prefix(max(0,keys.count - 256)) { try storage.db.delete(collection:"cloud-chunk-cache",key:old) }
                }
            })
    }
    private nonisolated static func queueBreakdown(_ operations:[CloudOperation]) throws -> [CloudQueueCategory] {
        var groups:[String:CloudQueueCategory] = [:]
        for operation in operations {
            let parts = operation.field.split(separator:"/")
            let category:String
            if parts.first == "library", parts.count > 3, parts[1] == "item" {
                category = "作品/" + String(parts[3])
            } else if parts.first == "library", parts.count > 1 {
                category = "资料库/" + String(parts[1])
            } else { category = String(parts.first ?? "其他") }
            var group = groups[category] ?? CloudQueueCategory(id:category,count:0,bytes:0)
            group.count += 1
            group.bytes += try StorageJSON.data(operation).count
            groups[category] = group
        }
        return groups.values.sorted { $0.bytes > $1.bytes }
    }
    nonisolated static func publishCheckpoint(_ storage:CloudStorage,encrypted:CloudEncryptedTransport,libraryID:String) async throws -> String {
        let checkpoint = try storage.makeCheckpoint(libraryID:libraryID)
        let data = try StorageJSON.data(checkpoint)
        let key = try await encrypted.publish(data,checkpointCovered:checkpoint.covered)
        guard try await encrypted.read(key) == data else { throw CloudJournalError.invalidOperation }
        try storage.db.setState("cloud.received/"+key,"1")
        return key
    }
    nonisolated static func publishCheckpointIfNeeded(_ storage:CloudStorage,encrypted:CloudEncryptedTransport,libraryID:String,threshold:Int = 32) async throws -> Bool {
        guard threshold > 0, try storage.db.pendingCloudOperations().isEmpty, try storage.db.keys("cloud-inbox").isEmpty else { return false }
        let statePrefix = "cloud.received/" + encrypted.prefix + "commits/"
        let count = try storage.db.query("SELECT key FROM state").filter { $0.first?.hasPrefix(statePrefix) == true }.count
        let marker = "cloud.checkpoint.count/" + encrypted.prefix
        let previous = Int(try storage.db.state(marker) ?? "0") ?? 0
        guard count >= previous, count - previous >= threshold else { return false }
        _ = try await publishCheckpoint(storage,encrypted:encrypted,libraryID:libraryID)
        try storage.db.setState(marker,String(count))
        return true
    }
    nonisolated static func verifyEncryptedLibrary(_ encrypted:CloudEncryptedTransport) async throws {
        let prefix = encrypted.prefix + "commits/"
        var token:String?, visited = Set<String>()
        repeat {
            let page = try await encrypted.transport.list(prefix:prefix,token:token)
            if let key = page.keys.first(where:{ $0.hasPrefix(prefix) }) {
                let data = try await encrypted.read(key)
                if let wire = try? JSONDecoder().decode(CloudRecordBatch.self,from:data) { try await unpackRecords(wire,encrypted:encrypted).validateVersion() }
                else if let batch = try? JSONDecoder().decode(CloudBatch.self,from:data) { try batch.validateVersion() }
                else { try JSONDecoder().decode(CloudMigrationBundle.self,from:data).validate() }
                return
            }
            token = page.next
            if let token, !visited.insert(token).inserted { throw S3Failure.message("S3 分页游标重复") }
        } while token != nil
        let checkpoints = try await encrypted.transport.list(prefix:encrypted.prefix + "checkpoints/")
        if let key = checkpoints.keys.filter({ $0.hasPrefix(encrypted.prefix + "checkpoints/") }).sorted(by:>).first {
            let checkpoint = try JSONDecoder().decode(CloudCheckpoint.self,from:await encrypted.read(key))
            try checkpoint.validate()
            guard encrypted.prefix == "anishelf/v2/" + checkpoint.libraryID.lowercased() + "/" else { throw CloudJournalError.invalidOperation }
            return
        }
        throw S3Failure.message("没有找到此加密资料库，请检查 S3 设置和恢复码")
    }
    private nonisolated static func scan(_ transport:S3Transport,encrypted:CloudEncryptedTransport?,storage:CloudStorage,config:S3Configuration,
                                         progress:@MainActor (Int,Int,Int) -> Void) async throws {
        var token:String?, visited = Set<String>(), missing = Set<String>()
        let listingPrefix = encrypted.map { $0.prefix + "commits/" } ?? prefix
        repeat {
            let page = try await transport.list(prefix:listingPrefix,token:token)
            for key in page.keys where key.hasPrefix(listingPrefix) && (encrypted != nil || key.hasSuffix(".json")) {
                if try !storage.cloudHasBatch(key) { missing.insert(key) }
            }
            token = page.next
            if let token, !visited.insert(token).inserted { throw S3Failure.message("S3 分页游标重复") }
        } while token != nil
        if let encrypted {
            var pendingCheckpoint = false
            for key in try storage.db.keys("cloud-checkpoint-pending") {
                if let checkpoint = try storage.db.read(CloudCheckpoint.self,collection:"cloud-checkpoint-pending",key:key) {
                    try checkpoint.validate()
                    if encrypted.prefix == "anishelf/v2/" + checkpoint.libraryID.lowercased() + "/" { missing.subtract(checkpoint.covered); pendingCheckpoint = true }
                }
            }
            do {
                let checkpointPrefix = encrypted.prefix + "checkpoints/"
                var checkpointToken:String?, checkpointVisited = Set<String>(), candidates:[String] = []
                repeat {
                    let page = try await transport.list(prefix:checkpointPrefix,token:checkpointToken)
                    candidates.append(contentsOf:page.keys.filter { $0.hasPrefix(checkpointPrefix) })
                    checkpointToken = page.next
                    if let checkpointToken, !checkpointVisited.insert(checkpointToken).inserted { throw S3Failure.message("S3 分页游标重复") }
                } while checkpointToken != nil
                var installed = pendingCheckpoint, failedCheckpoint = false
                for key in candidates.sorted(by:>) {
                    if try storage.cloudHasBatch(key) { continue }
                    let before = transport.traffic.download
                    do {
                        let coverage = try await encrypted.checkpointCoverage(key)
                        if let coverage, try !coverage.contains(where:{ try !storage.cloudHasBatch($0) }) {
                            try storage.db.setState("cloud.received/"+key,"1")
                            await progress(0,missing.count,transport.traffic.download-before)
                            continue
                        }
                        let data = try await encrypted.read(key)
                        let checkpoint = try JSONDecoder().decode(CloudCheckpoint.self,from:data)
                        try checkpoint.validate()
                        guard coverage == nil || coverage == checkpoint.covered else { throw CloudJournalError.invalidOperation }
                        guard encrypted.prefix == "anishelf/v2/" + checkpoint.libraryID.lowercased() + "/" else { throw CloudJournalError.invalidOperation }
                        // Covered commits may have been retired while this device was offline.
                        let unseen = try checkpoint.covered.contains { try !storage.cloudHasBatch($0) }
                        if unseen {
                            try storage.cloudReceiveCheckpoint(checkpoint,key:key)
                            missing.subtract(checkpoint.covered)
                            installed = true
                            await progress(0,missing.count,transport.traffic.download-before)
                            break
                        }
                        try storage.db.setState("cloud.received/"+key,"1")
                    } catch is CancellationError { throw CancellationError() }
                    catch { failedCheckpoint = true }
                    await progress(0,missing.count,transport.traffic.download-before)
                }
                if missing.isEmpty && failedCheckpoint && !installed { throw S3Failure.message("云端检查点无法读取，本地数据已保留") }
            }
        }
        let keys = missing.sorted()
        var completed = 0
        await progress(0,keys.count,0)
        if let encrypted {
            for key in keys {
                let before = transport.traffic.download
                let data = try await encrypted.read(key)
                if let wire = try? JSONDecoder().decode(CloudRecordBatch.self,from:data) {
                    try storage.cloudReceive(try await Self.unpackRecords(wire,encrypted:encrypted),key:key)
                } else if let batch = try? JSONDecoder().decode(CloudBatch.self,from:data) {
                    try storage.cloudReceive(batch,key:key)
                } else {
                    try storage.cloudReceiveMigration(JSONDecoder().decode(CloudMigrationBundle.self,from:data),key:key)
                }
                completed += 1
                await progress(completed,keys.count,transport.traffic.download-before)
            }
            return
        }
        for offset in stride(from:0,to:keys.count,by:config.concurrentReqs) {
            let chunk = Array(keys[offset..<min(keys.count,offset+config.concurrentReqs)])
            try await withThrowingTaskGroup(of:(String,Data).self) { group in
                for key in chunk { group.addTask { (key,try await transport.request("GET",key:key)) } }
                for try await (key,data) in group {
                    let expected = String(key.split(separator:"/").last!.dropLast(5))
                    guard S3Signer.hex(data) == expected else { throw S3Failure.message("云端提交摘要不符，本地数据已保留") }
                    try storage.cloudReceive(JSONDecoder().decode(CloudBatch.self,from:data),key:key)
                    completed += 1
                    await progress(completed,keys.count,data.count)
                }
            }
        }
    }


    private nonisolated static func put(_ batch:CloudBatch,transport:S3Transport,encrypted:CloudEncryptedTransport?) async throws -> (String,Int) {
        let data = try StorageJSON.data(batch)
        if let encrypted {
            let before = transport.traffic
            let wire = try await packRecords(batch,encrypted:encrypted)
            let key = try await encrypted.publish(wire.map { try StorageJSON.data($0) } ?? data)
            let after = transport.traffic
            return (key,after.upload-before.upload + after.verification-before.verification + after.retryUpload-before.retryUpload + after.retryDownload-before.retryDownload)
        }
        let key = prefix + S3Signer.hex(data) + ".json"
        _ = try await transport.request("PUT",key:key,body:data)
        guard try await transport.request("GET",key:key,verification:true) == data else {
            throw S3Failure.message("上传后校验失败，修改保留在待同步队列")
        }
        return (key,data.count*2)
    }

    private nonisolated static func packRecords(_ batch:CloudBatch,encrypted:CloudEncryptedTransport) async throws -> CloudRecordBatch? {
        var result = batch, records:[String:String] = [:]
        for index in result.operations.indices {
            let operation = result.operations[index]
            guard operation.field.hasPrefix("deliveryHistory/"),
                  let value = operation.value, var object = try? JSONSerialization.jsonObject(with:value) as? [String:Any],
                  let record = object["record"], (try? CloudEncoding.json(object)) == value else { continue }
            let recordData = try CloudEncoding.json(record)
            object.removeValue(forKey:"record")
            let key = try await encrypted.publish(recordData,staged:true)
            result.operations[index].value = try CloudEncoding.json(object)
            records[operation.id] = key
        }
        return records.isEmpty ? nil : CloudRecordBatch(format:"records-v1",batch:result,records:records)
    }
    private nonisolated static func unpackRecords(_ wire:CloudRecordBatch,encrypted:CloudEncryptedTransport) async throws -> CloudBatch {
        let ids = wire.batch.operations.map(\.id)
        guard wire.format == "records-v1", Set(ids).count == ids.count, Set(wire.records.keys).isSubset(of:Set(ids)) else { throw CloudJournalError.invalidOperation }
        var batch = wire.batch, cache:[String:Any] = [:]
        for index in batch.operations.indices {
            guard let key = wire.records[batch.operations[index].id] else { continue }
            if batch.operations[index].field.hasPrefix("drafts/") { continue }
            guard batch.operations[index].field.hasPrefix("deliveryHistory/"),
                  key.hasPrefix(encrypted.prefix + "staging/"),
                  CloudObjectCipher.validIdentifier(String(key.dropFirst((encrypted.prefix + "staging/").count))),
                  let value = batch.operations[index].value,
                  var object = try JSONSerialization.jsonObject(with:value) as? [String:Any], object["record"] == nil else { throw CloudJournalError.invalidOperation }
            if cache[key] == nil {
                let data = try await encrypted.read(key)
                cache[key] = try JSONSerialization.jsonObject(with:data)
            }
            object["record"] = cache[key]
            batch.operations[index].value = try CloudEncoding.json(object)
        }
        return batch
    }

    private nonisolated static func publishReset(_ local:Backup,transport:S3Transport,encrypted:CloudEncryptedTransport?,storage:CloudStorage) async throws -> (CloudEpoch,Int) {
        try storage.captureMetadata(local)
        let batch = try storage.db.transaction { try storage.makeReset(local) }
        let (key,bytes) = try await put(batch,transport:transport,encrypted:encrypted)
        try storage.cloudReceive(batch,key:key)
        return (batch.reset!,bytes)
    }

    private nonisolated static func upload(_ local:Backup,transport:S3Transport,encrypted:CloudEncryptedTransport?,storage:CloudStorage,destination:String,
                                           breakdown:@MainActor ([CloudQueueCategory]) -> Void,
                                           progress:@MainActor (Int,Int,Int) -> Void) async throws -> Report {
        let db = storage.db
        let previous = try db.state("cloud.destination")
        let equivalent = previous.map { transport.config.matchesDestination($0,namespace:encrypted?.prefix ?? "") } ?? false
        if let previous, previous != destination, !equivalent,
           let reset = try db.read(CloudBatch.self,collection:"cloud-reset") {
            _ = try await put(reset,transport:transport,encrypted:encrypted)
        }
        try storage.cloudBindDestination(destination,equivalent:equivalent)
        try storage.captureMetadata(local)
        let operations = try db.pendingCloudOperations()
        await breakdown(try queueBreakdown(operations))
        await progress(0,operations.count,0)
        if !operations.isEmpty {
            let version = try db.cloudEpoch() == nil ? 1 : 2
            let (key,bytes) = try await put(CloudBatch(version:version,operations:operations),transport:transport,encrypted:encrypted)
            try storage.cloudAcknowledge(operations.map(\.id),key:key)
            await progress(operations.count,operations.count,bytes)
        }
        return try report(storage)
    }

    private nonisolated static func localReport(_ storage:CloudStorage) async throws -> Report {
        try storage.cloudApplySettings()
        return try report(storage)
    }

    private nonisolated static func localEditReport(_ storage:CloudStorage) async throws -> (Report,Int) {
        try (report(storage),storage.db.pendingCloudOperations().count)
    }

    private nonisolated static func report(_ storage:CloudStorage) throws -> Report {
        try Report(conflicts:storage.db.cloudConflictRows().filter { !CloudProjection.isDevicePreference($0.id) },
                   deleted:storage.db.cloudDeletedItems(),deliveries:storage.cloudDeliveryHistory())
    }
}

struct S3SettingsTransfer:Codable {
    var version = 1
    var configuration:S3Configuration
    var access:String
    var secret:String
    var recovery:String? = nil

    func encoded() throws -> String { try StorageJSON.data(self).base64EncodedString() }

    static func decode(_ text:String) throws -> Self {
        let compact = text.filter { !$0.isWhitespace }
        guard compact.count <= 65536, let data = Data(base64Encoded:compact),
              let value = try? JSONDecoder().decode(Self.self,from:data), value.version == 1 else {
            throw S3Failure.message("无效的 S3 设置 Base64")
        }
        let config = value.configuration
        guard config.timeout >= 1, config.timeout <= 300, (1...16).contains(config.concurrentReqs),
              ["auto","path","virtual"].contains(config.addressingStyle) else {
            throw S3Failure.message("S3 设置包含无效的超时、并发数或寻址方式")
        }
        if config.enabled {
            try config.validate()
            guard !value.access.isEmpty, !value.secret.isEmpty else { throw S3Failure.message("请填写访问密钥") }
        }
        return value
    }
}
