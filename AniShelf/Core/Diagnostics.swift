import Foundation

struct DiagnosticEvent: Codable, Equatable, Identifiable {
    var id: Int
    var date: Date
    var level: String
    var component: String
    var message: String
    var method: String?
    var host: String?
    var path: String?
    var status: Int?
}
struct DiagnosticExport: Codable {
    var from: Date
    var through: Date
    var throughID: Int
    var events: [DiagnosticEvent]
    func data() throws -> Data { let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys]; encoder.dateEncodingStrategy = .iso8601; return try encoder.encode(self) }
}
private struct DiagnosticState: Codable {
    var nextID = 1
    var exportedID = 0
    var lastExport: Date?
    var events: [DiagnosticEvent] = []
}
@MainActor final class DiagnosticLog {
    static let shared = DiagnosticLog()
    private var state = DiagnosticState()
    private var database: LibraryDatabase?
    private var storageError: Error?
    private let writer = DispatchQueue(label:"AniShelf.Diagnostics",qos:.utility)
    init(directory:URL = URL.applicationSupportDirectory.appending(path:"AniShelf")) {
        do {
            let db = try LibraryDatabase(directory:directory.appendingPathComponent("DiagnosticStore"))
            state = try db.read(DiagnosticState.self,collection:"header") ?? DiagnosticState()
            state.events = try db.keys("events").compactMap { try db.read(DiagnosticEvent.self,collection:"events",key:$0) }.sorted { $0.id < $1.id }
            database = db
        } catch { storageError = error }
    }
    static func redacted(_ message:String) -> String {
        var result = String(message.prefix(1000))
        for pattern in ["(?i)Bearer\\s+[^\\s,;]+", "(?i)(?:access_token|refresh_token|api[_-]?key|client_secret|authorization)[\\s\"':=]+[^\\s,;}]+", "sk-[A-Za-z0-9_-]+"] {
            result = result.replacingOccurrences(of:pattern,with:"[REDACTED]",options:.regularExpression)
        }
        return result
    }
    func record(_ level:String = "error", component:String, message:String, url:URL? = nil, method:String? = nil, status:Int? = nil, now:Date = Date()) {
        state.events.removeAll { $0.date < now.addingTimeInterval(-86400) }
        state.events.append(DiagnosticEvent(id:state.nextID,date:now,level:level,component:component,message:Self.redacted(message),method:method,host:url?.host,path:url?.path,status:status))
        state.nextID += 1
        guard storageError == nil else { return }
        guard let database else { return }
        let snapshot = state
        writer.async { try? Self.write(snapshot,to:database) }
    }
    func prepareExport(now:Date = Date()) -> DiagnosticExport {
        let start = max(state.lastExport ?? .distantPast,now.addingTimeInterval(-86400))
        return DiagnosticExport(from:start,through:now,throughID:state.nextID-1,events:state.events.filter { $0.id > state.exportedID && $0.date >= start && $0.date <= now })
    }
    func markExported(_ export:DiagnosticExport) {
        guard export.throughID >= state.exportedID else { return }
        state.exportedID = export.throughID; state.lastExport = export.through
        let exportedID = state.exportedID
        state.events.removeAll { $0.id <= exportedID || $0.date < export.through.addingTimeInterval(-86400) }
        persist()
    }
    func checkStorage() throws { if let storageError { throw storageError } }
    func archiveData() throws -> Data {
        if let storageError { throw storageError }
        return try JSONEncoder().encode(state)
    }
    func validateArchive(_ data:Data) throws { _ = try JSONDecoder().decode(DiagnosticState.self,from:data) }
    func restoreArchive(_ data:Data) throws {
        let restored = try JSONDecoder().decode(DiagnosticState.self,from:data)
        if let storageError { throw storageError }
        guard let database else { throw APIError.message("诊断存储不可用") }
        try writer.sync { try Self.write(restored,to:database) }; state = restored
    }
    nonisolated private static func write(_ state:DiagnosticState,to database:LibraryDatabase) throws {
        try database.transaction {
            let existing = Set(try database.keys("events")), wanted = Set(state.events.map { String($0.id) })
            for key in existing.subtracting(wanted) { try database.delete(collection:"events",key:key) }
            for event in state.events {
                let key = String(event.id)
                if try !existing.contains(key) || database.read(DiagnosticEvent.self,collection:"events",key:key) != event { try database.put(event,collection:"events",key:key) }
            }
            var header = state; header.events = []
            try database.put(header,collection:"header")
        }
    }
    private func persist() {
        guard storageError == nil else { return }
        guard let database else { return }
        let snapshot = state
        writer.async { try? Self.write(snapshot,to:database) }
    }
}
