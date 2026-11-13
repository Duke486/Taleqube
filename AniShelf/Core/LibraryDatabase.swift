import Foundation
import SQLite3
import CryptoKit

/// Mutable roots point to immutable, content-addressed versions. Shared metadata, evidence,
/// mappings and sync payloads therefore occupy one physical copy, including historical versions.
final class LibraryDatabase: @unchecked Sendable {
    static let filename = "library.sqlite"
    private var connection: OpaquePointer?
    private let lock = NSRecursiveLock()
    private var transactionDepth = 0
    private var knownNodes = Set<String>()
    private var knownDataVersion = ""
    private var garbageCandidates = Set<String>()
    let url: URL
    init(directory:URL) throws {
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        url = directory.appendingPathComponent(Self.filename)
        guard sqlite3_open_v2(url.path,&connection,SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,nil) == SQLITE_OK else { throw failure() }
        sqlite3_busy_timeout(connection,5000)
        try execute("PRAGMA foreign_keys=ON")
        try execute("PRAGMA journal_mode=WAL")
        try execute("PRAGMA synchronous=FULL")
        let version = try query("PRAGMA user_version").first?.first.flatMap(Int.init) ?? 0
        guard version <= 1 else { throw APIError.message("此资料库需要更新版本的 AniShelf") }
        try transaction {
            try execute("CREATE TABLE IF NOT EXISTS nodes (id TEXT PRIMARY KEY, payload BLOB NOT NULL) WITHOUT ROWID")
            try execute("CREATE TABLE IF NOT EXISTS roots (collection TEXT NOT NULL, key TEXT NOT NULL, node TEXT NOT NULL REFERENCES nodes(id), PRIMARY KEY(collection,key)) WITHOUT ROWID")
            try execute("CREATE TABLE IF NOT EXISTS edges (parent TEXT NOT NULL REFERENCES nodes(id) ON DELETE CASCADE, child TEXT NOT NULL REFERENCES nodes(id), PRIMARY KEY(parent,child)) WITHOUT ROWID")
            try execute("CREATE INDEX IF NOT EXISTS edges_child ON edges(child)")
            try execute("CREATE INDEX IF NOT EXISTS roots_node ON roots(node)")
            try execute("CREATE TABLE IF NOT EXISTS state (key TEXT PRIMARY KEY, value TEXT NOT NULL) WITHOUT ROWID")
            try execute("CREATE TABLE IF NOT EXISTS item_identity (identity TEXT PRIMARY KEY, item_id TEXT NOT NULL) WITHOUT ROWID")
            try execute("CREATE INDEX IF NOT EXISTS item_identity_item ON item_identity(item_id)")
            if try state("cloud.draftsRemoved") == nil {
                try removeRetiredDrafts()
                try setState("cloud.draftsRemoved","1")
            }
            try execute("PRAGMA user_version=1")
        }
    }
    deinit { sqlite3_close(connection) }
    private func failure() -> Error { APIError.message("资料库操作失败：" + (connection.map { String(cString:sqlite3_errmsg($0)) } ?? "无法打开 SQLite")) }
    private func statement(_ sql:String,_ arguments:[Data]) throws -> OpaquePointer {
        var statement:OpaquePointer?
        guard sqlite3_prepare_v2(connection,sql,-1,&statement,nil) == SQLITE_OK, let statement else { throw failure() }
        for (index,value) in arguments.enumerated() {
            let result = value.withUnsafeBytes { sqlite3_bind_blob(statement,Int32(index+1),$0.baseAddress,Int32(value.count),unsafeBitCast(-1,to:sqlite3_destructor_type.self)) }
            if result != SQLITE_OK { sqlite3_finalize(statement); throw failure() }
        }
        return statement
    }
    // All bind values use BLOB consistently; SQL text identifiers are internal constants only.
    func execute(_ sql:String,_ arguments:[String] = []) throws { try executeData(sql,arguments.map { Data($0.utf8) }) }
    private func executeData(_ sql:String,_ arguments:[Data]) throws {
        lock.lock(); defer { lock.unlock() }
        let s = try statement(sql,arguments); defer { sqlite3_finalize(s) }
        var result = sqlite3_step(s)
        while result == SQLITE_ROW { result = sqlite3_step(s) }
        guard result == SQLITE_DONE else { throw APIError.message("资料库语句失败 [" + sql + "]：" + failure().localizedDescription) }
    }
    func query(_ sql:String,_ arguments:[String] = []) throws -> [[String]] {
        try queryData(sql,arguments.map { Data($0.utf8) }).map { $0.map { String(decoding:$0,as:UTF8.self) } }
    }
    private func queryData(_ sql:String,_ arguments:[Data] = []) throws -> [[Data]] {
        lock.lock(); defer { lock.unlock() }
        let s = try statement(sql,arguments); defer { sqlite3_finalize(s) }
        var rows:[[Data]] = []
        while true {
            let result = sqlite3_step(s)
            if result == SQLITE_DONE { return rows }
            guard result == SQLITE_ROW else { throw failure() }
            rows.append((0..<sqlite3_column_count(s)).map { column in
                guard let bytes = sqlite3_column_blob(s,column) else { return Data() }
                return Data(bytes:bytes,count:Int(sqlite3_column_bytes(s,column)))
            })
        }
    }
    func transaction<T>(_ body:() throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        if transactionDepth > 0 { return try body() }
        try execute("BEGIN IMMEDIATE"); transactionDepth = 1
        do {
            let version = try query("PRAGMA data_version").first?.first ?? ""
            if version != knownDataVersion { knownNodes.removeAll(); knownDataVersion = version }
            let value = try body(); try collectGarbage(); try execute("COMMIT"); transactionDepth = 0; return value
        }
        catch { try? execute("ROLLBACK"); transactionDepth = 0; knownNodes.removeAll(); garbageCandidates.removeAll(); throw error }
    }
    func state(_ key:String) throws -> String? { try query("SELECT value FROM state WHERE key=?",[key]).first?.first }
    func setState(_ key:String,_ value:String) throws { try execute("INSERT INTO state VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",[key,value]) }
    static func json(_ value:Any) throws -> Data { try JSONSerialization.data(withJSONObject:value,options:[.sortedKeys,.fragmentsAllowed,.withoutEscapingSlashes]) }
    static func digest(_ data:Data) -> String { SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined() }
    private func node(_ value:Any) throws -> String {
        // Typed envelopes prevent user JSON keys from being confused with internal references.
        var envelope:[String:Any]
        if let object = value as? [String:Any] {
            envelope = ["object":try object.mapValues { try reference($0) }]
        } else if let array = value as? [Any] {
            if let run = Self.episodeRun(array) { envelope = ["episodeRun":run] }
            else { envelope = ["array":try array.map { try reference($0) }] }
        } else { envelope = ["value":value] }
        let bytes = try Self.json(envelope), id = Self.digest(bytes)
        if !knownNodes.contains(id) {
            if let previous = try queryData("SELECT payload FROM nodes WHERE id=?",[Data(id.utf8)]).first?.first {
                guard previous == bytes else { throw APIError.message("内容校验冲突，已停止保存") }
            } else {
                try executeData("INSERT INTO nodes VALUES(?,?)",[Data(id.utf8),bytes])
                let refs = (envelope["object"] as? [String:Any]).map { Array($0.values) } ?? (envelope["array"] as? [Any] ?? [])
                for child in Set(refs.compactMap { ($0 as? [String:Any])?["ref"] as? String }) { try execute("INSERT INTO edges VALUES(?,?)",[id,child]) }
            }
            if knownNodes.count >= 16384 { knownNodes.removeAll(keepingCapacity:true) }
            knownNodes.insert(id)
        }
        return id
    }
    private static func episodeRun(_ values:[Any]) -> [String:Any]? {
        guard values.count >= 3, let first = values.first as? [String:Any],
              let start = (first["platformEpisodes"] as? [Int])?.first,
              let address = (first["tmdbEpisodes"] as? [[String:Int]])?.first,
              let season = address["season"], let number = address["number"],
              let evidence = first["evidenceIDs"] as? [String] else { return nil }
        for (offset,value) in values.enumerated() {
            guard let group = value as? [String:Any], Set(group.keys) == ["platformEpisodes","tmdbEpisodes","evidenceIDs"],
                  group["platformEpisodes"] as? [Int] == [start+offset],
                  group["tmdbEpisodes"] as? [[String:Int]] == [["season":season,"number":number+offset]],
                  group["evidenceIDs"] as? [String] == evidence else { return nil }
        }
        return ["platform":start,"number":number,"season":season,"count":values.count,"evidence":evidence]
    }
    private func reference(_ value:Any) throws -> [String:Any] {
        if value is [String:Any] || value is [Any] || (value as? String)?.utf8.count ?? 0 > 256 { return ["ref":try node(value)] }
        return ["inline":value]
    }
    private func expand(_ id:String,_ active:inout Set<String>,_ budget:inout Int) throws -> Any {
        guard active.count < 128, active.insert(id).inserted, budget > 0 else { throw APIError.message("备份引用循环或数据过大") }
        defer { active.remove(id) }
        guard let bytes = try queryData("SELECT payload FROM nodes WHERE id=?",[Data(id.utf8)]).first?.first,
              Self.digest(bytes) == id,
              let object = try JSONSerialization.jsonObject(with:bytes) as? [String:Any] else { throw APIError.message("资料库内容缺失或校验失败") }
        budget -= bytes.count
        func dereference(_ value:Any) throws -> Any {
            guard let ref = value as? [String:Any] else { throw APIError.message("资料库引用无效") }
            if let id = ref["ref"] as? String { return try expand(id,&active,&budget) }
            guard let inline = ref["inline"] else { throw APIError.message("资料库值无效") }; return inline
        }
        if let run = object["episodeRun"] as? [String:Any],
           let count = run["count"] as? Int, let platform = run["platform"] as? Int,
           let number = run["number"] as? Int, let season = run["season"] as? Int,
           let evidence = run["evidence"] as? [String], count > 0, count <= 100000 {
            return (0..<count).map { offset -> [String:Any] in
                ["platformEpisodes":[platform+offset],"tmdbEpisodes":[["season":season,"number":number+offset]],"evidenceIDs":evidence]
            }
        }
        if let fields = object["object"] as? [String:Any] { return try fields.mapValues(dereference) }
        if let array = object["array"] as? [Any] { return try array.map(dereference) }
        guard let value = object["value"] else { throw APIError.message("资料库节点无效") }; return value
    }
    func read<T:Decodable>(_ type:T.Type,collection:String,key:String = "value") throws -> T? {
        lock.lock(); defer { lock.unlock() }
        guard let id = try query("SELECT node FROM roots WHERE collection=? AND key=?",[collection,key]).first?.first else { return nil }
        var active = Set<String>(), budget = 512 * 1024 * 1024
        return try JSONDecoder().decode(type,from:Self.json(expand(id,&active,&budget)))
    }
    func put<T:Encodable>(_ value:T,collection:String,key:String = "value") throws {
        try transaction {
            let object = try JSONSerialization.jsonObject(with:JSONEncoder().encode(value),options:.fragmentsAllowed)
            let id = try node(object)
            if let old = try query("SELECT node FROM roots WHERE collection=? AND key=?",[collection,key]).first?.first, old != id { garbageCandidates.insert(old) }
            try execute("INSERT INTO roots VALUES(?,?,?) ON CONFLICT(collection,key) DO UPDATE SET node=excluded.node WHERE node<>excluded.node",[collection,key,id])
        }
    }
    func delete(collection:String,key:String) throws {
        try transaction {
            if let old = try query("SELECT node FROM roots WHERE collection=? AND key=?",[collection,key]).first?.first { garbageCandidates.insert(old) }
            try execute("DELETE FROM roots WHERE collection=? AND key=?",[collection,key])
        }
    }
    private func collectGarbage() throws {
        while let id = garbageCandidates.popFirst() {
            guard try query("SELECT 1 FROM roots WHERE node=? LIMIT 1",[id]).isEmpty,
                  try query("SELECT 1 FROM edges WHERE child=? LIMIT 1",[id]).isEmpty else { continue }
            let children = try query("SELECT child FROM edges WHERE parent=?",[id]).map { $0[0] }
            try execute("DELETE FROM nodes WHERE id=?",[id]); knownNodes.remove(id)
            garbageCandidates.formUnion(children)
        }
    }
    func keys(_ collection:String) throws -> [String] { try query("SELECT key FROM roots WHERE collection=? ORDER BY key",[collection]).map { $0[0] } }
    func check() throws {
        guard try query("PRAGMA quick_check").first?.first == "ok", try query("PRAGMA foreign_key_check").isEmpty else { throw APIError.message("资料库完整性检查失败") }
    }
    func stableItemID(for identities:Set<String>) throws -> String {
        for identity in identities.sorted() {
            if let id = try query("SELECT item_id FROM item_identity WHERE identity=?",[identity]).first?.first { return id }
        }
        return UUID().uuidString
    }
    func register(_ record:TrackingRecord) throws {
        let identities = record.relatedWorkIDs, id = try stableItemID(for:identities)
        for identity in identities { try execute("INSERT INTO item_identity VALUES(?,?) ON CONFLICT(identity) DO UPDATE SET item_id=excluded.item_id",[identity,id]) }
    }
    /// Archive uses only reachable immutable objects, excluding abandoned transaction versions.
    func archiveRows(collections:Set<String>? = nil) throws -> (roots:[[String]],nodes:[[String]]) {
        lock.lock(); defer { lock.unlock() }
        let roots = try query("SELECT collection,key,node FROM roots ORDER BY collection,key").filter { collections?.contains($0[0]) ?? true }
        var pending = roots.map { $0[2] }, visited = Set<String>(), nodes:[[String]] = []
        while let id = pending.popLast() {
            guard visited.insert(id).inserted else { continue }
            guard let bytes = try queryData("SELECT payload FROM nodes WHERE id=?",[Data(id.utf8)]).first?.first else { throw APIError.message("备份内容缺失") }
            guard Self.digest(bytes) == id else { throw APIError.message("备份内容校验失败") }
            nodes.append([id,String(decoding:bytes,as:UTF8.self)])
            let object = try JSONSerialization.jsonObject(with:bytes) as! [String:Any]
            let refs = (object["object"] as? [String:Any]).map { Array($0.values) } ?? (object["array"] as? [Any] ?? [])
            pending += refs.compactMap { ($0 as? [String:Any])?["ref"] as? String }
        }
        return (roots,nodes.sorted { $0[0] < $1[0] })
    }
    func importRows(roots:[[String]],nodes:[[String]]) throws {
        try transaction {
            for row in nodes {
                guard row.count == 2, Self.digest(Data(row[1].utf8)) == row[0] else { throw APIError.message("备份节点校验失败") }
                try execute("INSERT OR IGNORE INTO nodes VALUES(?,?)",row)
            }
            for row in nodes {
                let object = try JSONSerialization.jsonObject(with:Data(row[1].utf8)) as? [String:Any] ?? [:]
                let refs = (object["object"] as? [String:Any]).map { Array($0.values) } ?? (object["array"] as? [Any] ?? [])
                for child in Set(refs.compactMap { ($0 as? [String:Any])?["ref"] as? String }) { try execute("INSERT OR IGNORE INTO edges VALUES(?,?)",[row[0],child]) }
            }
            for row in roots {
                guard row.count == 3 else { throw APIError.message("备份索引无效") }
                try execute("INSERT INTO roots VALUES(?,?,?)",row)
            }
            try check()
        }
    }
}

extension LibraryDatabase {
    private func saveDictionary<T:Codable & Equatable>(_ values:[String:T],previous:[String:T],collection:String) throws {
        for key in previous.keys where values[key] == nil { try delete(collection:collection,key:key) }
        for (key,value) in values where previous[key] != value { try put(value,collection:collection,key:key) }
    }
    private func dictionary<T:Decodable>(_ type:T.Type,collection:String) throws -> [String:T] {
        var values:[String:T] = [:]
        for key in try keys(collection) { values[key] = try read(type,collection:collection,key:key) }
        return values
    }
    func loadBackup() throws -> Backup? {
        guard var value = try read(Backup.self,collection:"library") else { return nil }
        value.records = try dictionary(TrackingRecord.self,collection:"items")
        let order = try read([String].self,collection:"delivery-order") ?? []
        let jobs = try dictionary(Delivery.self,collection:"deliveries")
        value.deliveries = try order.map { id in guard let job = jobs[id] else { throw APIError.message("同步任务索引缺失") }; return job }
        value.associations = try dictionary(AssociationState.self,collection:"associations")
        value.localizations = LocalizationArchive(titles:try dictionary(LocalizedText.self,collection:"titles"),overviews:try dictionary(LocalizedText.self,collection:"overviews"))
        value.translations = try dictionary([String].self,collection:"translations")
        value.history = try read([ArchivedHistory].self,collection:"history")
        value.recommendations = try dictionary([Work].self,collection:"recommendations")
        return value
    }
    func saveBackup(_ value:Backup,previous:Backup?) throws {
        try transaction {
            let old = previous ?? Backup()
            try saveDictionary(value.records,previous:old.records,collection:"items")
            for (key,record) in value.records where old.records[key] != record { try register(record) }
            let jobs = Dictionary(uniqueKeysWithValues:value.deliveries.map { ($0.id.uuidString,$0) })
            let oldJobs = Dictionary(uniqueKeysWithValues:old.deliveries.map { ($0.id.uuidString,$0) })
            try saveDictionary(jobs,previous:oldJobs,collection:"deliveries")
            if previous == nil || value.deliveries.map(\.id) != old.deliveries.map(\.id) { try put(value.deliveries.map { $0.id.uuidString },collection:"delivery-order") }
            try saveDictionary(value.associations ?? [:],previous:old.associations ?? [:],collection:"associations")
            try saveDictionary(value.localizations?.titles ?? [:],previous:old.localizations?.titles ?? [:],collection:"titles")
            try saveDictionary(value.localizations?.overviews ?? [:],previous:old.localizations?.overviews ?? [:],collection:"overviews")
            try saveDictionary(value.translations,previous:old.translations,collection:"translations")
            try saveDictionary(value.recommendations ?? [:],previous:old.recommendations ?? [:],collection:"recommendations")
            if previous == nil || value.history != old.history { try put(value.history ?? [],collection:"history") }
            func header(_ source:Backup) -> Backup {
                var result = source
                result.records = [:]; result.deliveries = []; result.associations = nil
                result.localizations = nil; result.translations = [:]; result.history = nil; result.recommendations = nil
                return result
            }
            let current = header(value)
            if try previous == nil || StorageJSON.data(current) != StorageJSON.data(header(old)) || keys("library").isEmpty { try put(current,collection:"library") }
        }
    }
    func saveSnapshots(_ values:[String:LibrarySnapshot]) throws {
        let previous = try dictionary(LibrarySnapshot.self,collection:"snapshots")
        try transaction { try saveDictionary(values,previous:previous,collection:"snapshots") }
    }
    func removeRetiredDrafts() throws {
        for key in try keys("drafts") { try delete(collection:"drafts",key:key) }
        for collection in ["cloud-registers","cloud-field-baseline"] {
            for key in try keys(collection) where key.hasPrefix("drafts/") { try delete(collection:collection,key:key) }
        }
        for operation in try pendingCloudOperations() where operation.field.hasPrefix("drafts/") {
            try delete(collection:"cloud-outbox",key:operation.id)
        }
    }
    func loadSnapshots() throws -> [String:LibrarySnapshot] { try dictionary(LibrarySnapshot.self,collection:"snapshots") }

}

enum StorageJSON {
    static func data<T:Encodable>(_ value:T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
}

enum LibraryValidation {
    static func validate(backup:Backup) throws {
        guard backup.version == 1, backup.records.allSatisfy({ $0.key == $0.value.id }),
              Set(backup.deliveries.map(\.id)).count == backup.deliveries.count else { throw APIError.message("备份作品或同步任务标识无效") }
    }
}
