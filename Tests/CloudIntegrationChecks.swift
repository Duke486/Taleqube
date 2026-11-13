import Foundation

final class CloudS3Server:URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    static var objects:[String:Data] = [:]
    static var failListing = false
    static var loseNextPutResponse = false
    static var injectDuringCommit:(String,Data)?
    override class func canInit(with request:URLRequest) -> Bool { true }
    override class func canonicalRequest(for request:URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        let path = request.url!.path
        var status = 200, body = Data(), lost = false, headers:[String:String] = [:]
        if request.httpMethod == "PUT" {
            var payload = request.httpBody
            if payload == nil, let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var bytes = Data(), buffer = [UInt8](repeating:0,count:4096)
                while stream.hasBytesAvailable { let count = stream.read(&buffer,maxLength:buffer.count); if count <= 0 { break }; bytes.append(buffer,count:count) }
                payload = bytes
            }
            Self.objects[path] = payload ?? Data()
            if path.contains("/anishelf/v2/") && path.contains("/staging/"), let injected = Self.injectDuringCommit {
                Self.objects[injected.0] = injected.1
                Self.injectDuringCommit = nil
            }
            if Self.loseNextPutResponse { Self.loseNextPutResponse = false; lost = true }
        } else if request.url!.query?.contains("list-type") == true {
            if Self.failListing { status = 403 }
            else {
                let query = URLComponents(url:request.url!,resolvingAgainstBaseURL:false)?.queryItems ?? []
                let prefix = query.first(where:{ $0.name == "prefix" })?.value ?? ""
                let bucketPrefix = path.hasSuffix("/") ? path : path + "/"
                let entries = Self.objects.keys.filter { $0.hasPrefix(bucketPrefix + prefix) }.sorted().map { "<Contents><Key>" + String($0.dropFirst(bucketPrefix.count)) + "</Key></Contents>" }.joined()
                body = Data(("<ListBucketResult>"+entries+"<IsTruncated>false</IsTruncated></ListBucketResult>").utf8)
            }
        } else if let data = Self.objects[path] {
            headers["ETag"] = "\"" + S3Signer.hex(data) + "\""
            if request.httpMethod != "HEAD" { body = data }
        } else { status = 404 }
        Self.lock.unlock()
        if lost { client?.urlProtocol(self,didFailWithError:URLError(.networkConnectionLost)); return }
        client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:status,httpVersion:nil,headerFields:headers)!,cacheStoragePolicy:.notAllowed)
        client?.urlProtocol(self,didLoad:body); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
@main struct CloudIntegrationChecks {
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        var count = 0
        func check(_ value:Bool,_ label:String) { precondition(value,label); count += 1; print("PASS: " + label) }
        var keychain:[String:String] = [:]
        let savedMaterial = CloudKeyMaterial.generate()
        try CloudKeyStore.install(savedMaterial,read:{ keychain[$0] ?? "" },write:{ keychain[$0] = $1 })
        let readMaterial = try CloudKeyStore.load(read:{ keychain[$0] ?? "" })
        check(readMaterial == savedMaterial,"Library recovery material survives key store round-trip")
        do {
            try CloudKeyStore.install(CloudKeyMaterial.generate(),read:{ keychain[$0] ?? "" },write:{ keychain[$0] = $1 })
            fatalError("Overwrote a different library key")
        } catch S3Failure.message { }
        check(try CloudKeyStore.load(read:{ keychain[$0] ?? "" }) == savedMaterial,"Another library cannot overwrite the saved key")
        func device(_ name:String) -> (TrackingStore,CloudSync) {
            let suiteName = "Taleqube.CloudTest." + UUID().uuidString
            let defaults = UserDefaults(suiteName:suiteName)!
            let diagnostics = DiagnosticLog(directory:root.appendingPathComponent(name+"-logs"))
            let store = TrackingStore(directory:root.appendingPathComponent(name),api:CatalogAPI(credential:{ _ in "" },diagnostics:diagnostics))
            store.cloudPreferences = defaults; store.cloudReadCredentials = { names in Dictionary(uniqueKeysWithValues:names.map { ($0,"") }) }; store.cloudWriteCredentials = { _ in }
            let sync = CloudSync(preferences:defaults)
            sync.configuration.bucket = "bucket"; sync.configuration.enabled = true
            sync.makeTransport = { config in
                let sessionConfig = URLSessionConfiguration.ephemeral; sessionConfig.protocolClasses = [CloudS3Server.self]
                return S3Transport(config:config,access:"test",secret:"secret",session:URLSession(configuration:sessionConfig))
            }
            sync.start(store,automatic:false)
            return (store,sync)
        }
        let packageMaterial = CloudKeyMaterial.generate()
        var packageConfig = S3Configuration(); packageConfig.bucket = "package-test"
        let packageSession = URLSessionConfiguration.ephemeral; packageSession.protocolClasses = [CloudS3Server.self]
        var objectVersions:[String:String] = [:]
        let packageTransport = try CloudEncryptedTransport(transport:S3Transport(config:packageConfig,access:"test",secret:"secret",session:URLSession(configuration:packageSession)),material:packageMaterial,cachedVersion:{ objectVersions[$0] },saveVersion:{ objectVersions[$0] = $1 })
        let packagePayload = Data("secret-metadata-secret-metadata".utf8)
        let packageKey = try await packageTransport.publish(packagePayload,chunkSize:8)
        let packageRestored = try await packageTransport.read(packageKey)
        check(packageRestored == packagePayload,"Encrypted chunks and manifest round-trip through S3")
        check(CloudS3Server.objects.filter { $0.key.hasPrefix("/package-test/") }.values.allSatisfy { $0.range(of:Data("secret-metadata".utf8)) == nil },"Encrypted S3 objects do not contain plaintext")
        let objectPrefix = "/package-test/" + packageTransport.prefix + "objects/"
        let originalChunks = CloudS3Server.objects.filter { $0.key.hasPrefix(objectPrefix) }
        let beforeReuse = packageTransport.transport.traffic
        _ = try await packageTransport.publish(packagePayload,chunkSize:8)
        let afterReuse = packageTransport.transport.traffic
        check(originalChunks == CloudS3Server.objects.filter { $0.key.hasPrefix(objectPrefix) },"Published encrypted chunks are reused without rewriting")
        check(afterReuse.verification - beforeReuse.verification == CloudS3Server.objects["/package-test/"+packageKey]!.count,"Unchanged chunk versions avoid downloading chunk bodies")
        let damagedKey = originalChunks.keys.first!
        CloudS3Server.objects[damagedKey] = Data("corrupt".utf8)
        let repairedKey = try await packageTransport.publish(packagePayload,chunkSize:8)
        let repairedPayload = try await packageTransport.read(repairedKey)
        check(repairedPayload == packagePayload,"Corrupt existing chunk is repaired before publication")
        let chunkDB = try LibraryDatabase(directory:root.appendingPathComponent("chunk-cache"))
        let cachedTransport = try CloudEncryptedTransport(transport:packageTransport.transport,material:packageMaterial,
            cachedChunk:{ try chunkDB.read(Data.self,collection:"chunks",key:$0) },
            saveChunk:{ try chunkDB.put($1,collection:"chunks",key:$0) })
        _ = try await cachedTransport.read(packageKey)
        let beforeCachedRead = packageTransport.transport.traffic.download
        let cachedPayload = try await cachedTransport.read(packageKey)
        check(cachedPayload == packagePayload && packageTransport.transport.traffic.download - beforeCachedRead == CloudS3Server.objects["/package-test/"+packageKey]!.count,"Repeated reads reuse authenticated chunks and download only the manifest")
        let cachedKey = try chunkDB.keys("chunks").first!
        try chunkDB.put(Data("corrupt local cache".utf8),collection:"chunks",key:cachedKey)
        let repairedCachePayload = try await cachedTransport.read(packageKey)
        check(repairedCachePayload == packagePayload,"A corrupt cached chunk is fetched and authenticated again")
        let (encryptedA,syncA) = device("encrypted-a"), (encryptedB,syncB) = device("encrypted-b")
        let coordinatorMaterial = CloudKeyMaterial.generate()
        syncA.makeEncryptedMaterial = { coordinatorMaterial }; syncB.makeEncryptedMaterial = { coordinatorMaterial }
        let encryptedWork = Work(source:.tmdb,remoteID:"encrypted-test",kind:.movie,title:"Encrypted movie")
        encryptedA.backup.records[encryptedWork.id] = TrackingRecord(work:encryptedWork,score:7)
        await syncA.synchronize(); await syncB.synchronize()
        check(syncA.error == nil && syncB.error == nil && encryptedB.backup.records[encryptedWork.id]?.score == 7,"Encrypted coordinator synchronizes a new device")
        encryptedB.backup.records[encryptedWork.id]?.score = 9
        await syncB.synchronize(); await syncA.synchronize()
        check(syncA.error == nil && encryptedA.backup.records[encryptedWork.id]?.score == 9,"Encrypted incremental edit reaches the original device")
        await syncA.synchronize()
        check(syncA.error == nil && syncA.traffic.upload == 0 && syncA.traffic.download == 0 && syncA.traffic.verification == 0,"Encrypted empty sync transfers no object bodies")
        check(syncA.transferred == syncA.traffic.total && syncA.traffic.listing > 0,"Displayed total includes the same request bodies as the traffic breakdown")
        syncA.configuration.endpoint += "/"
        await syncA.synchronize()
        check(syncA.error == nil && syncA.traffic.upload == 0,"Equivalent endpoint spelling does not resend history")
        var random:UInt64 = 114514
        let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789".utf8)
        var text = [UInt8](); text.reserveCapacity(180_000)
        for _ in 0..<180_000 { random ^= random << 13; random ^= random >> 7; random ^= random << 17; text.append(alphabet[Int(random % UInt64(alphabet.count))]) }
        var heavy = TrackingRecord(work:encryptedWork); heavy.work.overview = String(decoding:text,as:UTF8.self)
        let delivery = Delivery(record:heavy,target:encryptedWork,state:"等待同步")
        encryptedA.backup.deliveries.append(delivery)
        await syncA.synchronize()
        let firstDeliveryBytes = syncA.traffic.upload
        encryptedA.backup.deliveries[0].state = "已同步"
        await syncA.synchronize()
        check(syncA.error == nil && syncA.traffic.upload * 4 < firstDeliveryBytes,"Delivery status update reuses the unchanged large record")
        await syncB.synchronize()
        check(syncB.error == nil && syncB.deliveryHistory.contains { $0.id == delivery.id && $0.state == "已同步" && $0.record == heavy },"Referenced delivery record is restored exactly on another device")
        encryptedA.backup.deliveries[0].state = "已跳过"
        await syncA.synchronize(); await syncB.synchronize()
        check(syncB.error == nil && syncB.traffic.download < 20_000 && syncB.deliveryHistory.contains { $0.id == delivery.id && $0.state == "已跳过" && $0.record == heavy },"Receiving a status update reuses the authenticated local record")
        var checkpointConfig = S3Configuration(); checkpointConfig.bucket = "bucket"
        let checkpointSession = URLSessionConfiguration.ephemeral; checkpointSession.protocolClasses = [CloudS3Server.self]
        let checkpointTransport = try CloudEncryptedTransport(transport:S3Transport(config:checkpointConfig,access:"test",secret:"secret",session:URLSession(configuration:checkpointSession)),material:coordinatorMaterial)
        let checkpointKey = try await CloudSync.publishCheckpoint(encryptedA.cloudStorage(),encrypted:checkpointTransport,libraryID:coordinatorMaterial.libraryID)
        let checkpointData = try await checkpointTransport.read(checkpointKey)
        let checkpoint = try JSONDecoder().decode(CloudCheckpoint.self,from:checkpointData)
        try checkpoint.validate()
        check(!checkpoint.covered.isEmpty && checkpoint.snapshot.batches.last!.operations.count > 0,"Encrypted checkpoint contains covered commits and causal snapshot")
        check(checkpoint.snapshot.batches.last!.operations.contains { $0.field.hasPrefix("deliveryHistory/") && $0.compactedHash != nil && $0.value == nil },"Checkpoint removes superseded delivery bodies while retaining causal identity")
        let (fromCheckpoint,checkpointSync) = device("from-checkpoint")
        checkpointSync.makeEncryptedMaterial = { coordinatorMaterial }
        await checkpointSync.synchronize()
        let checkpointDB = try fromCheckpoint.cloudStorage().db
        let acceptedCheckpoint = try checkpointDB.state("cloud.received/"+checkpointKey)
        check(checkpointSync.error == nil && fromCheckpoint.backup.records[encryptedWork.id]?.score == 9 && acceptedCheckpoint != nil,"New device restores a checkpoint and marks coverage after merging")
        let retiredPaths = checkpoint.covered.map { "/bucket/" + $0 }
        let retiredObjects = Dictionary(uniqueKeysWithValues:retiredPaths.compactMap { path in CloudS3Server.objects[path].map { (path,$0) } })
        for path in retiredPaths { CloudS3Server.objects.removeValue(forKey:path) }
        let (checkpointOnly,checkpointOnlySync) = device("checkpoint-only")
        try await checkpointOnlySync.joinEncrypted(material:coordinatorMaterial,storeKey:{ _ in })
        checkpointOnlySync.makeEncryptedMaterial = { coordinatorMaterial }
        await checkpointOnlySync.synchronize()
        check(checkpointOnlySync.error == nil && checkpointOnly.backup.records[encryptedWork.id]?.score == 9,"A new device can join from a checkpoint after covered commits are removed")
        for (path,data) in retiredObjects { CloudS3Server.objects[path] = data }
        let publishedAutomatically = try await CloudSync.publishCheckpointIfNeeded(encryptedA.cloudStorage(),encrypted:checkpointTransport,libraryID:coordinatorMaterial.libraryID,threshold:2)
        let publishedAgain = try await CloudSync.publishCheckpointIfNeeded(encryptedA.cloudStorage(),encrypted:checkpointTransport,libraryID:coordinatorMaterial.libraryID,threshold:2)
        check(publishedAutomatically && !publishedAgain,"Checkpoint publishing waits for additional acknowledged commits")
        let checkpointPath = "/bucket/" + checkpointKey
        let savedCheckpoint = CloudS3Server.objects[checkpointPath]!
        CloudS3Server.objects[checkpointPath] = Data("damaged".utf8)
        let (fallback,fallbackSync) = device("checkpoint-fallback")
        fallbackSync.makeEncryptedMaterial = { coordinatorMaterial }
        await fallbackSync.synchronize()
        check(fallbackSync.error == nil && fallback.backup.records[encryptedWork.id]?.score == 9,"Damaged checkpoint falls back to complete commits")
        CloudS3Server.objects[checkpointPath] = savedCheckpoint
        let offlineMaterial = CloudKeyMaterial.generate()
        let (online,onlineSync) = device("checkpoint-online"), (offline,offlineSync) = device("checkpoint-offline")
        onlineSync.makeEncryptedMaterial = { offlineMaterial }; offlineSync.makeEncryptedMaterial = { offlineMaterial }
        let offlineWork = Work(source:.tmdb,remoteID:"checkpoint-offline",kind:.movie,title:"Offline conflict")
        online.backup.records[offlineWork.id] = TrackingRecord(work:offlineWork,score:7)
        await onlineSync.synchronize(); await offlineSync.synchronize()
        let offlineTransport = try CloudEncryptedTransport(transport:S3Transport(config:checkpointConfig,access:"test",secret:"secret",session:URLSession(configuration:checkpointSession)),material:offlineMaterial)
        let olderCheckpointKey = try await CloudSync.publishCheckpoint(online.cloudStorage(),encrypted:offlineTransport,libraryID:offlineMaterial.libraryID)
        online.backup.records[offlineWork.id]?.score = 8
        await onlineSync.synchronize()
        let offlineCheckpointKey = try await CloudSync.publishCheckpoint(online.cloudStorage(),encrypted:offlineTransport,libraryID:offlineMaterial.libraryID)
        let offlineCheckpoint = try JSONDecoder().decode(CloudCheckpoint.self,from:await offlineTransport.read(offlineCheckpointKey))
        for key in offlineCheckpoint.covered { CloudS3Server.objects.removeValue(forKey:"/bucket/"+key) }
        offline.backup.records[offlineWork.id]?.score = 3
        _ = try await offline.cloudBackup()
        await offlineSync.synchronize()
        check(offlineSync.error == nil && offlineSync.conflictRows.contains { $0.id.hasSuffix("/group/rating") && $0.versions.count == 2 },"An existing offline device reads the checkpoint after all covered commits are retired")
        let (afterOffline,afterOfflineSync) = device("checkpoint-after-offline")
        afterOfflineSync.makeEncryptedMaterial = { offlineMaterial }
        await afterOfflineSync.synchronize()
        check(afterOfflineSync.error == nil && afterOffline.backup.records[offlineWork.id] != nil && afterOfflineSync.conflictRows.contains { $0.id.hasSuffix("/group/rating") && $0.versions.count == 2 },"Offline edits referencing compacted ancestors preserve both conflict branches")
        await afterOfflineSync.synchronize()
        check(afterOfflineSync.error == nil && afterOfflineSync.traffic.download == CloudS3Server.objects["/bucket/"+olderCheckpointKey]!.count,"An already covered checkpoint downloads its coverage manifest without its snapshot")
        offline.backup.records[offlineWork.id]?.status = "已完成"
        await offlineSync.preferCloudConflicts()
        await onlineSync.synchronize()
        check(offlineSync.error == nil && offlineSync.conflicts == 0 && online.backup.records[offlineWork.id]?.score == 8 && online.backup.records[offlineWork.id]?.status == "已完成","Prefer cloud resolves local conflicts and preserves unrelated local edits")
        encryptedA.backup.records[encryptedWork.id]?.score = 6
        encryptedB.backup.records[encryptedWork.id]?.status = "已完成"
        await syncA.synchronize(); await syncB.synchronize(); await syncA.synchronize()
        check(syncA.error == nil && syncB.error == nil && encryptedA.backup.records == encryptedB.backup.records && encryptedA.backup.records[encryptedWork.id]?.score == 6 && encryptedA.backup.records[encryptedWork.id]?.status == "已完成","Encrypted concurrent independent edits converge")
        encryptedA.backup.records.removeValue(forKey:encryptedWork.id)
        await syncA.synchronize(); await syncB.synchronize()
        check(syncB.error == nil && encryptedB.backup.records.isEmpty && syncB.deletedItems.count == 1,"Encrypted deletion retains restoration data")
        if let deleted = syncB.deletedItems.first { await syncB.restoreItem(deleted.id) }
        await syncA.synchronize()
        check(syncA.error == nil && encryptedA.backup.records[encryptedWork.id]?.score == 6,"Encrypted deletion can be restored")
        await syncA.replaceCloudWithLocal(); await syncB.synchronize()
        check(syncA.error == nil && syncB.error == nil && encryptedA.backup.records == encryptedB.backup.records,"Encrypted reset converges")
        let (joining,joiningSync) = device("joining-with-local-data")
        let localWork = Work(source:.tmdb,remoteID:"local-before-join",kind:.movie,title:"Local before joining")
        joining.backup.records[localWork.id] = TrackingRecord(work:localWork,score:8)
        _ = try await joining.cloudBackup()
        try await joiningSync.joinEncrypted(material:coordinatorMaterial,storeKey:{ _ in })
        joining.backup.records[localWork.id]?.score = 9
        _ = try await joining.cloudBackup()
        joiningSync.makeEncryptedMaterial = { coordinatorMaterial }
        await joiningSync.synchronize(); await syncA.synchronize()
        check(joiningSync.error == nil && syncA.error == nil && joining.backup.records[localWork.id]?.score == 9 && joining.backup.records[encryptedWork.id] != nil && encryptedA.backup.records[localWork.id]?.score == 9,"Joining a reset epoch preserves and shares local edits made during joining")
        let (a,sa) = device("a"), (b,sb) = device("b")
        let work = Work(source:.tmdb,remoteID:"123",kind:.movie,title:"Test")
        a.backup.records[work.id] = TrackingRecord(work:work,score:7)
        CloudS3Server.loseNextPutResponse = true
        await sa.synchronize()
        check(sa.error == nil && sa.pending == 0,"Lost PUT response retries without losing local operation")
        check(sa.queueCategories.contains { $0.id.hasPrefix("作品/") && $0.count > 0 && $0.bytes > 0 },"Queue breakdown records encoded item operations")
        await sb.synchronize()
        check(sb.error == nil && b.backup.records[work.id]?.score == 7,"Empty device downloads complete library")
        a.backup.records[work.id]?.score = 9
        b.backup.records[work.id]?.status = "已完成"
        await sa.synchronize(); await sb.synchronize(); await sa.synchronize()
        check(sa.error == nil && sb.error == nil,"Concurrent device synchronization succeeds")
        check(a.backup.records[work.id]?.score == 9 && a.backup.records[work.id]?.status == "已完成","Independent rating and status edits merge")
        check(a.backup.records == b.backup.records,"Both devices converge")
        CloudS3Server.failListing = true
        a.backup.records[work.id]?.score = 6
        await sa.synchronize()
        check(sa.error != nil && a.backup.records[work.id]?.score == 6,"Listing failure preserves new local edit")
        CloudS3Server.failListing = false
        await sa.synchronize(); await sb.synchronize()
        check(sb.error == nil && b.backup.records[work.id]?.score == 6,"Reconnect drains durable queue")
        a.backup.records.removeValue(forKey:work.id)
        await sa.synchronize(); await sb.synchronize()
        check(sb.error == nil && b.backup.records.isEmpty,"Deletion converges through real coordinator")
        check(sb.deletedItems.count == 1 && sb.deletedItems[0].title == "Test","Deleted record retains complete recovery snapshot")
        await sb.restoreItem(sb.deletedItems[0].id)
        await sb.synchronize(); await sa.synchronize()
        check(sa.error == nil && a.backup.records[work.id]?.score == 6,"Explicit restore creates a new convergent version")
        a.backup.records.removeValue(forKey:work.id)
        b.backup.records[work.id]?.score = 4
        await sa.synchronize(); await sb.synchronize()
        check(b.backup.records.isEmpty && !sb.conflictRows.isEmpty,"Offline edit cannot silently resurrect deletion")
        let conflict = sb.conflictRows.first { $0.id.hasSuffix("/group/rating") }!
        let edited = conflict.versions.first { $0.value != nil }!
        await sb.resolve(conflict.id,operation:edited.id)
        await sb.synchronize(); await sa.synchronize()
        check(sa.error == nil && sb.error == nil && a.backup.records[work.id]?.score == 4,"Choosing edited branch restores complete record and chosen rating")
        // Simulate an old client that published its UI settings into the shared journal.
        let preference = CloudOperation(id:"legacy:1",device:"legacy",sequence:1,field:"settings/shelf.cardWidth",
                                        parents:[],timestamp:Date(),value:Data("330".utf8))
        let legacy = try StorageJSON.data(CloudBatch(operations:[preference]))
        CloudS3Server.objects["/bucket/"+CloudSync.prefix+S3Signer.hex(legacy)+".json"] = legacy
        a.cloudPreferences.set(145,forKey:"shelf.cardWidth")
        b.cloudPreferences.set(205,forKey:"shelf.cardWidth")
        await sa.synchronize(); await sb.synchronize()
        check(a.cloudPreferences.integer(forKey:"shelf.cardWidth") == 145 &&
              b.cloudPreferences.integer(forKey:"shelf.cardWidth") == 205,"Legacy cloud preferences leave both devices' display settings intact")

        let (c,sc) = device("c")
        await sc.synchronize()
        a.backup.records[work.id]?.score = 7
        _ = try await a.cloudBackup()
        b.backup.records[work.id]?.score = 9
        let remoteOnly = Work(source:.tmdb,remoteID:"999",kind:.movie,title:"Remote only")
        b.backup.records[remoteOnly.id] = TrackingRecord(work:remoteOnly)
        await sb.synchronize(); await sa.synchronize()
        check(sa.conflicts > 0,"Reset starts with a real rating conflict")
        // Keep the remote-only work out of the reset source, but preserve the existing conflict.
        a.backup.records.removeValue(forKey:remoteOnly.id)
        a.backup.records[work.id]?.score = 8
        c.backup.records[work.id]?.score = 2
        _ = try await c.cloudBackup() // A durable offline outbox must be discarded upon adoption.
        CloudS3Server.failListing = true
        await sa.replaceCloudWithLocal()
        check(sa.error != nil && a.backup.records[work.id]?.score == 8,"A failed reset scan leaves the local authority intact")
        CloudS3Server.failListing = false
        await sa.replaceCloudWithLocal()
        await sb.synchronize(); await sc.synchronize()
        check([sa,sb,sc].allSatisfy { $0.error == nil && $0.conflicts == 0 } &&
              [a,b,c].allSatisfy { $0.backup.records[work.id]?.score == 8 && $0.backup.records[remoteOnly.id] == nil },
              "Reset replaces remote-only data and discards old conflict branches and the offline outbox")
        check(b.cloudPreferences.integer(forKey:"shelf.cardWidth") == 205,"Reset preserves device-local preferences")
        let (d,sd) = device("d")
        await sd.synchronize()
        check(sd.error == nil && d.backup.records == a.backup.records,"A fresh device selects the reset over historical submissions")
        c.backup.records[work.id]?.score = 5
        await sc.synchronize(); await sa.synchronize(); await sd.synchronize()
        check(sa.error == nil && sd.error == nil && a.backup.records[work.id]?.score == 5 &&
              d.backup.records == a.backup.records,"Fresh changes in the reset epoch propagate normally")
        await sb.replaceCloudWithLocal(); await sa.synchronize()
        check(sa.error == nil && a.backup.records[work.id]?.score == 8,"A later reset wins over the preceding epoch")

        let overwrite = Task { await sa.replaceCloudWithLocal() }
        let deadline = ContinuousClock.now.advanced(by:.seconds(5))
        while sa.phase != "正在以本机版本覆盖云端" && ContinuousClock.now < deadline { await Task.yield() }
        precondition(sa.phase == "正在以本机版本覆盖云端",sa.error ?? "Reset upload did not start")
        a.backup.records[work.id]?.score = 3
        _ = try await a.cloudBackup()
        await overwrite.value
        await sd.synchronize()
        check(sa.error == nil && sd.error == nil && d.backup.records[work.id]?.score == 3,
              "An edit made while publishing a reset is replayed in the new epoch")

        var configuration = sa.configuration
        configuration.concurrentReqs = 7
        configuration.tlsVerify = false
        let settings = S3SettingsTransfer(configuration:configuration,access:"access",secret:"secret + 汉字")
        let decoded = try S3SettingsTransfer.decode("  "+settings.encoded()+"\n")
        check(decoded.configuration == configuration && decoded.access == settings.access && decoded.secret == settings.secret,
              "Base64 settings round-trip every connection option and both keys")
        check((try? S3SettingsTransfer.decode("not base64")) == nil,"Invalid import is rejected before saving")
        @MainActor func waitForSync(_ sync:CloudSync,after previous:Date?,timeout:Duration) async -> Bool {
            let deadline = ContinuousClock.now.advanced(by:timeout)
            while sync.lastSuccess == previous && ContinuousClock.now < deadline {
                try? await Task.sleep(for:.milliseconds(20))
            }
            return sync.lastSuccess != previous
        }
        let (e,se) = device("e")
        se.start(e)
        let startup = await waitForSync(se,after:nil,timeout:.seconds(4))
        check(startup && e.backup.records[work.id]?.score == 3,"Startup immediately downloads the current differences")
        let startupSuccess = se.lastSuccess
        let admission = Work(source:.tmdb,remoteID:"222",kind:.movie,title:"Admission")
        let admitted = await e.save(TrackingRecord(work:admission))
        check(admitted,"Admission commits locally")
        try await Task.sleep(for:.milliseconds(250))
        let associated = await e.saveAssociationsAsync(e.record(admission))
        let associationTime = Date()
        let debounced = await waitForSync(se,after:startupSuccess,timeout:.seconds(14))
        check(associated && debounced && (se.lastSuccess?.timeIntervalSince(associationTime) ?? 0) >= 9.9,
              "Admission and association share the quiet period after the latest operation")
        let associationSuccess = se.lastSuccess
        var updated = e.record(admission)
        updated.score = 7
        let saved = await e.save(updated)
        let immediately = await waitForSync(se,after:associationSuccess,timeout:.seconds(4))
        check(saved && immediately,"Saving a rating triggers sync without waiting for the quiet period")
        if CommandLine.arguments.contains("--benchmark") {
            var fixture = Backup(), random:UInt64 = 21847
            let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789".utf8)
            for index in 0..<100 {
                var bytes = [UInt8](); bytes.reserveCapacity(3000)
                for _ in 0..<3000 { random ^= random << 13; random ^= random >> 7; random ^= random << 17; bytes.append(alphabet[Int(random % UInt64(alphabet.count))]) }
                let item = Work(source:.tmdb,remoteID:"bench-\(index)",kind:.movie,title:"Fixture \(index)",overview:String(decoding:bytes,as:UTF8.self))
                let record = TrackingRecord(work:item,score:7)
                fixture.records[item.id] = record
                fixture.deliveries += (0..<2).map { _ in Delivery(record:record,target:item,state:"已同步") }
            }
            let diagnostics = DiagnosticLog(directory:root.appendingPathComponent("benchmark-diagnostics"))
            let archive = ApplicationArchive(backup:fixture,snapshots:[:],history:[],recommendations:[:],preferences:[:],credentials:[:],diagnostics:try diagnostics.archiveData())
            let exportBytes = try LibraryArchive.encode(archive).count
            func transferred(_ traffic:S3Traffic) -> Int { traffic.total }
            let (old,oldSync) = device("benchmark-old"), (fresh,freshSync) = device("benchmark-new")
            oldSync.configuration.bucket = "benchmark-old"; freshSync.configuration.bucket = "benchmark-new"
            freshSync.makeEncryptedMaterial = { CloudKeyMaterial(version:1,libraryID:"86d344c7-19f8-4554-a142-1c7d0944dacf",key:Data(repeating:42,count:32)) }
            old.backup = fixture; fresh.backup = fixture
            await oldSync.synchronize(); await freshSync.synchronize()
            let oldInitial = transferred(oldSync.traffic), newInitial = transferred(freshSync.traffic)
            check(oldSync.error == nil && freshSync.error == nil,"100-work benchmark uploads both protocols")
            await oldSync.synchronize(); await freshSync.synchronize()
            let oldEmpty = transferred(oldSync.traffic), newEmpty = transferred(freshSync.traffic)
            check(freshSync.traffic.upload == 0 && freshSync.traffic.download == 0 && freshSync.traffic.verification == 0,"100-work empty sync transfers only discovery responses")
            let firstID = fixture.records.keys.sorted()[0]
            old.backup.records[firstID]?.score = 8; fresh.backup.records[firstID]?.score = 8
            await oldSync.synchronize(); await freshSync.synchronize()
            check(oldSync.error == nil && freshSync.error == nil,"100-work benchmark uploads rating edits")
            check(freshSync.traffic.upload + freshSync.traffic.verification < 20_000,"100-work rating edit stays below 20 KB of upload and verification")
            print("BENCHMARK: 100 works, 200 deliveries; export=\(exportBytes); initial legacy=\(oldInitial), encrypted=\(newInitial); empty legacy=\(oldEmpty), encrypted=\(newEmpty); rating legacy=\(transferred(oldSync.traffic)), encrypted=\(transferred(freshSync.traffic)) bytes")
        }
        let (credentialSource,credentialSync) = device("credential-source")
        let (credentialReceiver,receiverSync) = device("credential-receiver")
        let credentialMaterial = CloudKeyMaterial.generate()
        credentialSync.configuration.bucket = "credential-sync"; receiverSync.configuration.bucket = "credential-sync"
        credentialSync.makeEncryptedMaterial = { credentialMaterial }; receiverSync.makeEncryptedMaterial = { credentialMaterial }
        var localCredentials = ["trakt.clientID":"client","trakt.token":"private-access-1","trakt.refresh":"private-refresh-1"]
        var receivedCredentials:[String:String] = [:]
        credentialSource.cloudReadCredentials = { names in Dictionary(uniqueKeysWithValues:names.map { ($0,localCredentials[$0] ?? "") }) }
        credentialReceiver.cloudReadCredentials = { names in Dictionary(uniqueKeysWithValues:names.map { ($0,receivedCredentials[$0] ?? "") }) }
        credentialReceiver.cloudWriteCredentials = { receivedCredentials.merge($0) { _,new in new } }
        credentialSync.credentialsChanged()
        localCredentials["trakt.token"] = "private-access-2"; localCredentials["trakt.refresh"] = "private-refresh-2"
        credentialSync.credentialsChanged()
        for _ in 0..<100 {
            if credentialSync.lastSuccess != nil || credentialSync.error != nil { break }
            try await Task.sleep(for:.milliseconds(50))
        }
        check(credentialSync.error == nil && credentialSync.lastSuccess != nil && !credentialSync.credentialsPending,"Credential changes coalesce and synchronize without waiting for the periodic loop")
        await receiverSync.synchronize()
        check(receiverSync.error == nil && receivedCredentials["trakt.token"] == "private-access-2" && receivedCredentials["trakt.refresh"] == "private-refresh-2","Encrypted cloud synchronization delivers the latest complete login to a second device")
        let credentialObjects = CloudS3Server.objects.filter { $0.key.hasPrefix("/credential-sync/") }
        check(!credentialObjects.isEmpty && credentialObjects.values.allSatisfy { $0.range(of:Data("private-access".utf8)) == nil && $0.range(of:Data("private-refresh".utf8)) == nil },"Encrypted credential synchronization never uploads plaintext tokens")
        let credentialSuccess = credentialSync.lastSuccess
        credentialSync.credentialsChanged()
        try await Task.sleep(for:.milliseconds(1200))
        check(credentialSync.lastSuccess == credentialSuccess && !credentialSync.credentialsPending,"Unchanged credentials do not start another cloud round trip")
        localCredentials["trakt.token"] = ""; localCredentials["trakt.refresh"] = ""
        credentialSync.credentialsChanged()
        for _ in 0..<100 {
            if credentialSync.lastSuccess != credentialSuccess || credentialSync.error != nil { break }
            try await Task.sleep(for:.milliseconds(50))
        }
        await receiverSync.synchronize()
        check(receiverSync.error == nil && receivedCredentials["trakt.token"] == "" && receivedCredentials["trakt.refresh"] == "","Automatic credential sync propagates an explicit logout through encrypted S3")
        print("\(count) cloud integration checks passed")
    }
}
