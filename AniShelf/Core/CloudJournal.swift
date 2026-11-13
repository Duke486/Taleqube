import Foundation
import CryptoKit

/// Immutable operations. Parent IDs are the complete observed frontier for a field.
struct CloudOperation: Codable, Equatable, Identifiable {
    var id: String
    var device: String
    var sequence: Int64
    var field: String
    var parents: [String]
    var timestamp: Date
    var value: Data?
    var restoration: [String:Data]? = nil
    var epoch: CloudEpoch? = nil
    var compactedHash:String? = nil
    func commitment() throws -> String {
        guard compactedHash == nil else { throw CloudJournalError.invalidOperation }
        return SHA256.hash(data:try CloudEncoding.data(self)).map { String(format:"%02x",$0) }.joined()
    }
    func compacted() throws -> Self {
        var copy = self
        copy.compactedHash = try commitment(); copy.value = nil; copy.restoration = nil
        return copy
    }
}
struct CloudEpoch: Codable, Equatable, Comparable {
    var number: Int64
    var id: String
    static func < (lhs:Self,rhs:Self) -> Bool {
        lhs.number == rhs.number ? lhs.id < rhs.id : lhs.number < rhs.number
    }
}
struct CloudBatch: Codable {
    var version = 1
    var operations: [CloudOperation]
    var reset: CloudEpoch? = nil
    var clearsDrafts: Bool? = nil

    func validateVersion() throws {
        guard version == 1 || version == 2 else { throw CloudJournalError.unsupportedVersion }
        guard clearsDrafts != true || reset != nil else { throw CloudJournalError.invalidOperation }
        if let reset {
            guard version == 2, reset.number > 0, UUID(uuidString:reset.id) != nil,
                  operations.allSatisfy({ $0.epoch == reset && $0.parents.isEmpty }) else { throw CloudJournalError.invalidOperation }
        }
        guard version == 2 || operations.allSatisfy({ $0.epoch == nil }) else { throw CloudJournalError.invalidOperation }
    }
}
struct CloudRecordBatch:Codable {
    let format:String
    var batch:CloudBatch
    let records:[String:String]
}
struct CloudMigrationBundle:Codable {
    let version:Int
    let batches:[CloudBatch]
    init(batches:[CloudBatch]) { self.version = 1; self.batches = batches }
    func validate() throws {
        guard version == 1, (1...2).contains(batches.count), let last = batches.last, last.reset == nil else {
            throw CloudJournalError.invalidOperation
        }
        for batch in batches { try batch.validateVersion() }
        if batches.count == 2 {
            guard let epoch = batches[0].reset, last.version == 2,
                  last.operations.allSatisfy({ $0.epoch == epoch }) else { throw CloudJournalError.invalidOperation }
        } else if last.version != 1 { throw CloudJournalError.invalidOperation }
    }
}
struct CloudCheckpoint:Codable {
    let version:Int
    let libraryID:String
    let covered:[String]
    let snapshot:CloudMigrationBundle
    func validate() throws {
        guard version == 1, let id = UUID(uuidString:libraryID) else { throw CloudJournalError.invalidOperation }
        let prefix = "anishelf/v2/" + id.uuidString.lowercased() + "/commits/"
        guard Set(covered).count == covered.count, covered.allSatisfy({ key in
            let suffix = key.dropFirst(prefix.count).utf8
            return key.hasPrefix(prefix) && suffix.count == 64 && suffix.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
        }) else { throw CloudJournalError.invalidOperation }
        try snapshot.validate()
    }
}
struct CloudRegister: Codable {
    var operations: [String:CloudOperation] = [:]
    var frontier: [CloudOperation] {
        let superseded = Set(operations.values.flatMap(\.parents))
        return operations.values.filter { !superseded.contains($0.id) }.sorted {
            if $0.timestamp != $1.timestamp { return $0.timestamp < $1.timestamp }
            return $0.id < $1.id
        }
    }
    var winner: CloudOperation? {
        let candidates = frontier
        // Concurrent explicit deletions win visibility; the edited branch remains recoverable.
        if let deleted = candidates.last(where:{ $0.value == nil }) { return deleted }
        if let manual = candidates.last(where:{ operation in
            guard operation.field.contains("/link/"), let data = operation.value,
                  let object = try? JSONSerialization.jsonObject(with:data) as? [String:Any],
                  let mapping = object["mapping"] as? [String:Any] else { return false }
            return mapping["manual"] as? Bool == true
        }) { return manual }
        return candidates.last
    }
    mutating func insert(_ operation:CloudOperation) throws {
        if let old = operations[operation.id], old != operation {
            if old.compactedHash != nil, operation.compactedHash == nil, try operation.compacted() == old {
                operations[operation.id] = operation; return
            }
            if operation.compactedHash != nil, old.compactedHash == nil, try old.compacted() == operation { return }
            throw CloudJournalError.invalidOperation
        }
        operations[operation.id] = operation
    }
}
enum CloudJournalError: LocalizedError {
    case invalidOperation, unsupportedVersion, missingAncestors
    var errorDescription:String? {
        switch self {
        case .invalidOperation: return "云端操作标识冲突或内容无效"
        case .missingAncestors: return "云端前置版本尚未完整列出，已保留下载内容并等待下次补齐"
        case .unsupportedVersion: return "云端同步协议需要更新 AniShelf"
        }
    }
}

struct CloudConflict:Identifiable { var id:String; var versions:[CloudOperation] }
struct CloudDeletedItem:Identifiable { var id:String; var title:String; var date:Date }

extension LibraryDatabase {
    func cloudEpoch() throws -> CloudEpoch? { try read(CloudEpoch.self,collection:"cloud-epoch") }

    func cloudInstallEpoch(_ epoch:CloudEpoch) throws {
        for collection in ["cloud-registers","cloud-outbox","cloud-field-baseline","cloud-baseline"] {
            for key in try keys(collection) { try delete(collection:collection,key:key) }
        }
        try put(epoch,collection:"cloud-epoch")
    }

    func cloudDeviceID() throws -> String {
        if let device = try state("cloud.device") { return device }
        let device = UUID().uuidString; try setState("cloud.device",device); return device
    }
    func migrateCloudBaseline(namespace:String) throws {
        if let old = try read([String:Data].self,collection:"cloud-baseline",key:namespace) {
            for (key,value) in old { try put(value,collection:"cloud-field-baseline",key:namespace+"/"+key) }
            try delete(collection:"cloud-baseline",key:namespace)
        }
    }
    func cloudBaseline(namespace:String) throws -> [String:Data] {
        try migrateCloudBaseline(namespace:namespace)
        var result:[String:Data] = [:]
        for key in try keys("cloud-field-baseline") where key.hasPrefix(namespace+"/") {
            result[String(key.dropFirst(namespace.count+1))] = try read(Data.self,collection:"cloud-field-baseline",key:key)
        }
        return result
    }
    func acceptCloudBaseline(_ fields:[String:Data],namespace:String) throws {
        try transaction {
            let old = try cloudBaseline(namespace:namespace)
            for key in old.keys where fields[key] == nil { try delete(collection:"cloud-field-baseline",key:namespace+"/"+key) }
            for (key,value) in fields where old[key] != value { try put(value,collection:"cloud-field-baseline",key:namespace+"/"+key) }
        }
    }
    func captureCloudChanges(_ fields:[String:Data],removed:Set<String>,namespace:String) throws {
        try transaction {
            try migrateCloudBaseline(namespace:namespace)
            let device = try cloudDeviceID(), epoch = try cloudEpoch()
            var snapshots:[String:[String:Data]] = [:]
            for field in removed where namespace == "library" && field.hasPrefix("item/") && field.hasSuffix("/exists") {
                let prefix = String(field.dropLast(6))
                var snapshot:[String:Data] = [:]
                for key in try keys("cloud-field-baseline") where key.hasPrefix(namespace+"/"+prefix) {
                    snapshot[String(key.dropFirst(namespace.count+1))] = try read(Data.self,collection:"cloud-field-baseline",key:key)
                }
                snapshots[field] = snapshot
            }
            for field in Set(fields.keys).union(removed).sorted() {
                let key = namespace + "/" + field
                let previous = try read(Data.self,collection:"cloud-field-baseline",key:key)
                guard previous != fields[field] else { continue }
                var register = try read(CloudRegister.self,collection:"cloud-registers",key:key) ?? CloudRegister()
                let sequence = (Int64(try state("cloud.sequence") ?? "0") ?? 0) + 1
                let operation = CloudOperation(id:device + ":" + String(sequence),device:device,sequence:sequence,field:key,parents:register.frontier.map(\.id),timestamp:Date(),value:fields[field],restoration:snapshots[field],epoch:epoch)
                try register.insert(operation)
                try put(register,collection:"cloud-registers",key:key)
                try put(operation,collection:"cloud-outbox",key:operation.id)
                try setState("cloud.sequence",String(sequence))
                if let value = fields[field] { try put(value,collection:"cloud-field-baseline",key:key) }
                else { try delete(collection:"cloud-field-baseline",key:key) }
            }
        }
    }
    func captureCloudFields(_ fields:[String:Data], namespace:String) throws {
        try transaction {
            let previous = try cloudBaseline(namespace:namespace)
            try captureCloudChanges(fields,removed:Set(previous.keys).subtracting(fields.keys),namespace:namespace)
        }
    }
    func cloudValues(namespace:String) throws -> [String:Data] {
        var result:[String:Data] = [:]
        for key in try keys("cloud-registers") where key.hasPrefix(namespace + "/") {
            if let register = try read(CloudRegister.self,collection:"cloud-registers",key:key), let winner = register.winner, let value = winner.value {
                result[String(key.dropFirst(namespace.count+1))] = value
            }
        }
        return result
    }
    func cloudConflictCount() throws -> Int {
        try keys("cloud-registers").reduce(0) { count,key in
            count + ((try read(CloudRegister.self,collection:"cloud-registers",key:key)?.frontier.count ?? 0) > 1 ? 1 : 0)
        }
    }
    func cloudConflictRows() throws -> [CloudConflict] {
        try keys("cloud-registers").compactMap { key in
            guard let register = try read(CloudRegister.self,collection:"cloud-registers",key:key), register.frontier.count > 1 else { return nil }
            return CloudConflict(id:key,versions:register.frontier)
        }
    }
    func cloudDeletedItems() throws -> [CloudDeletedItem] {
        var result:[CloudDeletedItem] = []
        for key in try keys("cloud-registers") where key.hasPrefix("library/item/") && key.hasSuffix("/exists") {
            guard let register = try read(CloudRegister.self,collection:"cloud-registers",key:key), let deleted = register.winner,
                  deleted.value == nil, let snapshot = deleted.restoration else { continue }
            let workKey = String(key.dropFirst(8).dropLast(6)) + "field/work"
            let work = snapshot[workKey].flatMap { try? JSONSerialization.jsonObject(with:$0) as? [String:Any] }
            result.append(CloudDeletedItem(id:key,title:work?["title"] as? String ?? key,date:deleted.timestamp))
        }
        return result.sorted { $0.date > $1.date }
    }
    func restoreCloudItem(_ key:String) throws {
        try transaction {
            guard let register = try read(CloudRegister.self,collection:"cloud-registers",key:key), let deleted = register.winner,
                  deleted.value == nil, let snapshot = deleted.restoration else { throw CloudJournalError.invalidOperation }
            let prefix = String(key.dropFirst(8).dropLast(6))
            guard snapshot.keys.allSatisfy({ $0.hasPrefix(prefix) }), snapshot[prefix+"exists"] != nil else { throw CloudJournalError.invalidOperation }
            try captureCloudChanges(snapshot,removed:[],namespace:"library")
        }
    }
    func preferRemoteCloudConflicts() throws {
        let device = try cloudDeviceID()
        for conflict in try cloudConflictRows() where !CloudProjection.isDevicePreference(conflict.id) {
            guard conflict.versions.contains(where:{ $0.device == device }) else { continue }
            let remote = conflict.versions.filter { $0.device != device }
            let candidates = CloudRegister(operations:Dictionary(uniqueKeysWithValues:remote.map { ($0.id,$0) }))
            if let selected = candidates.winner {
                try resolveCloudConflict(field:conflict.id,operationID:selected.id,restoreDeletedItem:false)
            }
        }
    }
    func resolveCloudConflict(field:String,operationID:String,restoreDeletedItem:Bool = true) throws {
        try transaction {
            guard var register = try read(CloudRegister.self,collection:"cloud-registers",key:field),
                  let selected = register.operations[operationID],
                  let device = try state("cloud.device") else { throw CloudJournalError.invalidOperation }
            if restoreDeletedItem, selected.value != nil, field.hasPrefix("library/item/") {
                let pieces = field.split(separator:"/",maxSplits:3)
                if pieces.count == 4 {
                    let existence = pieces.prefix(3).joined(separator:"/") + "/exists"
                    if let deleted = try read(CloudRegister.self,collection:"cloud-registers",key:existence)?.winner, deleted.value == nil {
                        try restoreCloudItem(existence)
                        register = try read(CloudRegister.self,collection:"cloud-registers",key:field) ?? register
                    }
                }
            }
            let sequence = (Int64(try state("cloud.sequence") ?? "0") ?? 0) + 1
            let operation = CloudOperation(id:device + ":" + String(sequence),device:device,sequence:sequence,field:field,parents:register.frontier.map(\.id),timestamp:Date(),value:selected.value,epoch:try cloudEpoch())
            try register.insert(operation)
            try put(register,collection:"cloud-registers",key:field)
            try put(operation,collection:"cloud-outbox",key:operation.id)
            try setState("cloud.sequence",String(sequence))
        }
    }
    func pendingCloudOperations() throws -> [CloudOperation] {
        try keys("cloud-outbox").compactMap { try read(CloudOperation.self,collection:"cloud-outbox",key:$0) }
    }
    func acknowledgeCloudOperations(_ ids:[String]) throws {
        try transaction { for id in ids { try delete(collection:"cloud-outbox",key:id) } }
    }
    func validateCloudAncestry(fields:Set<String>) throws {
        for field in fields {
            guard let register = try read(CloudRegister.self,collection:"cloud-registers",key:field) else { continue }
            var indegree:[String:Int] = [:], children:[String:[String]] = [:]
            let superseded = Set(register.operations.values.flatMap(\.parents))
            for operation in register.operations.values {
                if let hash = operation.compactedHash {
                    guard operation.value == nil, operation.restoration == nil,
                          hash.utf8.count == 64, hash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
                          superseded.contains(operation.id) else { throw CloudJournalError.invalidOperation }
                }
                let parents = Set(operation.parents)
                guard parents.allSatisfy({ register.operations[$0] != nil }) else { throw CloudJournalError.missingAncestors }
                indegree[operation.id] = parents.count
                for parent in parents { children[parent,default:[]].append(operation.id) }
            }
            var ready = indegree.filter { $0.value == 0 }.map(\.key), visited = 0
            while let id = ready.popLast() {
                visited += 1
                for child in children[id] ?? [] { indegree[child,default:0] -= 1; if indegree[child] == 0 { ready.append(child) } }
            }
            guard visited == register.operations.count else { throw CloudJournalError.invalidOperation }
        }
    }
    func receiveCloudBatch(_ batch:CloudBatch) throws {
        try batch.validateVersion()
        try transaction {
            for (field,operations) in Dictionary(grouping:batch.operations,by:\.field) {
                var register = try read(CloudRegister.self,collection:"cloud-registers",key:field) ?? CloudRegister()
                for operation in operations {
                    guard operation.sequence > 0, operation.id == operation.device + ":" + String(operation.sequence), !field.isEmpty,
                          !operation.parents.contains(operation.id), operation.timestamp.timeIntervalSince1970.isFinite else { throw CloudJournalError.invalidOperation }
                    try register.insert(operation)
                }
                try put(register,collection:"cloud-registers",key:field)
            }
        }
    }
}

/// Codable Set iteration order differs across processes. Normalize only unordered schema fields.
enum CloudEncoding {
    private static let unordered:Set<String> = ["noEntryPlatforms","confirmedProgress","progressDisabled","retiredAssociationIDs","handledHistory","syncFields","fields","watched","parents"]
    static func canonical(_ value:Any,key:String = "") throws -> Any {
        if let object = value as? [String:Any] { return try object.mapValuesWithKeys { key,value in try canonical(value,key:key) } }
        if let array = value as? [Any] {
            let normalized = try array.map { try canonical($0) }
            if unordered.contains(key) {
                return try normalized.map { (try JSONSerialization.data(withJSONObject:$0,options:[.sortedKeys,.fragmentsAllowed]).base64EncodedString(),$0) }.sorted { $0.0 < $1.0 }.map { $0.1 }
            }
            return normalized
        }
        return value
    }
    static func json(_ value:Any) throws -> Data { try JSONSerialization.data(withJSONObject:canonical(value),options:[.sortedKeys,.fragmentsAllowed]) }
    static func data<T:Encodable>(_ value:T) throws -> Data { try json(JSONSerialization.jsonObject(with:JSONEncoder().encode(value),options:.fragmentsAllowed)) }
}
private extension Dictionary where Key == String, Value == Any {
    func mapValuesWithKeys(_ transform:(String,Any) throws -> Any) rethrows -> [String:Any] {
        var result:[String:Any] = [:]
        for (key,value) in self { result[key] = try transform(key,value) }
        return result
    }
}
