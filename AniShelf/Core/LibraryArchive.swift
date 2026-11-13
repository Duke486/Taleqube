import Foundation
import CoreFoundation
import zlib
import CryptoKit
import CommonCrypto

struct PreparedApplicationImport: @unchecked Sendable {
    let archive:ApplicationArchive
}

struct ArchivedCloudJournal: Codable {
    static let collections: Set<String> = ["cloud-registers","cloud-outbox","cloud-field-baseline","cloud-baseline",
        "cloud-inbox","cloud-epoch","cloud-reset","cloud-checkpoint-pending","cloud-settings-pending","cloud-join-pending"]
    let roots:[[String]]
    let nodes:[[String]]
    let state:[String:String]

    private static func includesState(_ key:String) -> Bool {
        ["cloud.destination","cloud.librarySeeded","cloud.device","cloud.sequence"].contains(key) ||
            key.hasPrefix("cloud.received/") || key.hasPrefix("cloud.checkpoint.count/")
    }
    static func capture(_ db:LibraryDatabase) throws -> Self {
        try db.transaction {
            let rows = try db.archiveRows(collections:collections)
            let state = try db.query("SELECT key,value FROM state").filter { includesState($0[0]) }
            return Self(roots:rows.roots,nodes:rows.nodes,state:Dictionary(uniqueKeysWithValues:state.map { ($0[0],$0[1]) }))
        }
    }
    func restore(_ db:LibraryDatabase) throws {
        let device = try db.state("cloud.device")
        let sequence = Int64(try db.state("cloud.sequence") ?? "") ?? 0
        for collection in Self.collections {
            for key in try db.keys(collection) { try db.delete(collection:collection,key:key) }
        }
        for row in try db.query("SELECT key FROM state") where Self.includesState(row[0]) && row[0] != "cloud.device" && row[0] != "cloud.sequence" {
            try db.execute("DELETE FROM state WHERE key=?",[row[0]])
        }
        try db.importRows(roots:roots,nodes:nodes)
        for (key,value) in state where Self.includesState(key) && key != "cloud.device" && key != "cloud.sequence" {
            try db.setState(key,value)
        }
        if let device, device == state["cloud.device"] {
            try db.setState("cloud.sequence",String(max(sequence,Int64(state["cloud.sequence"] ?? "") ?? 0)))
        }
    }
}

/// Portable ZIP format, independent of SQLite schema. SHA-256 authenticates accidental corruption,
/// not the origin of a file. Credentials retain the existing explicit full-backup behavior.
enum LibraryArchive {
    static let typeIdentifier = "app.anishelf.archive"
    private static let encryptedHeader = Data("AniShelfEncrypted3\0".utf8)
    static func isEncrypted(_ data:Data) -> Bool { data.starts(with:encryptedHeader) }
    static func isNative(_ data:Data) -> Bool { isEncrypted(data) || data.starts(with:[0x50,0x4b,0x03,0x04]) }
    static func version(_ data:Data) throws -> Int {
        if isEncrypted(data) { guard data.count > encryptedHeader.count+44 else { throw APIError.message("加密备份文件截断") }; return 3 }
        if isNative(data) { _ = try entries(data); return 3 }
        throw APIError.message("仅支持当前 AniShelf 备份格式")
    }
    static func prepare(_ data:Data,password:String = "") throws -> PreparedApplicationImport {
        PreparedApplicationImport(archive:try decode(data,password:password))
    }
    static func encode(_ archive:ApplicationArchive,password:String = "") throws -> Data {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:directory) }
        let db = try LibraryDatabase(directory:directory)
        try db.transaction {
            var backup = archive.backup
            backup.history = archive.history; backup.recommendations = archive.recommendations
            try db.saveBackup(backup,previous:nil)
            try db.saveSnapshots(archive.snapshots)
            if let journal = archive.cloudJournal {
                try db.importRows(roots:journal.roots,nodes:journal.nodes)
                try db.put(journal.state,collection:"archive-cloud-state")
            }
            try db.put(archive.preferences,collection:"preferences")
            try db.put(archive.credentials,collection:"credentials")
            // Encode diagnostics as structured JSON, avoiding nested Base64 expansion.
            let diagnostics = try JSONSerialization.jsonObject(with:archive.diagnostics)
            try db.put(JSONValue(diagnostics),collection:"diagnostics")
        }
        let rows = try db.archiveRows()
        let roots = try lines(rows.roots), nodes = try lines(rows.nodes)
        let manifest = try LibraryDatabase.json(["format":"app.anishelf.archive","version":3,"minimumReader":3,
            "checksums":["data/roots.jsonl":LibraryDatabase.digest(roots),"data/nodes.jsonl":LibraryDatabase.digest(nodes)]])
        let data = try zip([("manifest.json",manifest),("data/roots.jsonl",roots),("data/nodes.jsonl",nodes)])
        guard !password.isEmpty else { return data }
        let salt = SymmetricKey(size:.bits128).withUnsafeBytes { Data($0) }
        let key = try passwordKey(password,salt:salt)
        return encryptedHeader + salt + (try AES.GCM.seal(data,using:key).combined!)
    }
    static func decode(_ data:Data,password:String = "") throws -> ApplicationArchive {
        if isEncrypted(data) {
            guard !password.isEmpty else { throw APIError.message("请输入备份密码") }
            guard data.count > encryptedHeader.count+44 else { throw APIError.message("加密备份文件截断") }
            let salt = data.subdata(in:encryptedHeader.count..<encryptedHeader.count+16)
            let key = try passwordKey(password,salt:salt)
            let bytes:Data
            do { bytes = try AES.GCM.open(AES.GCM.SealedBox(combined:data.dropFirst(encryptedHeader.count+16)),using:key) }
            catch { throw APIError.message("备份密码错误或文件损坏") }
            guard bytes.starts(with:[0x50,0x4b,0x03,0x04]) else { throw APIError.message("加密备份内容无效") }
            return try decode(bytes)
        }
        guard isNative(data) else { throw APIError.message("仅支持当前 AniShelf 备份格式") }
        let files = try entries(data)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:directory) }
        let db = try LibraryDatabase(directory:directory)
        func rows(_ name:String) throws -> [[String]] {
            guard let bytes = files[name] else { throw APIError.message("备份数据缺失") }
            return try bytes.split(separator:10).map { try JSONDecoder().decode([String].self,from:Data($0)) }
        }
        try db.importRows(roots:rows("data/roots.jsonl"),nodes:rows("data/nodes.jsonl"))
        guard let backup = try db.loadBackup(), let diagnostic = try db.read(JSONValue.self,collection:"diagnostics") else { throw APIError.message("备份资料库缺失") }
        try LibraryValidation.validate(backup:backup)
        let journal:ArchivedCloudJournal?
        if let state = try db.read([String:String].self,collection:"archive-cloud-state") {
            let rows = try db.archiveRows(collections:ArchivedCloudJournal.collections)
            journal = ArchivedCloudJournal(roots:rows.roots,nodes:rows.nodes,state:state)
        } else { journal = nil }
        return ApplicationArchive(backup:backup,snapshots:try db.loadSnapshots(),history:backup.history ?? [],recommendations:backup.recommendations ?? [:],
            preferences:try db.read([String:String].self,collection:"preferences") ?? [:],credentials:try db.read([String:String].self,collection:"credentials") ?? [:],diagnostics:try LibraryDatabase.json(diagnostic.value),cloudJournal:journal)
    }
    private static func passwordKey(_ password:String,salt:Data) throws -> SymmetricKey {
        let bytes = Array(password.utf8)
        var output = [UInt8](repeating:0,count:32)
        let status = bytes.withUnsafeBytes { input in salt.withUnsafeBytes { saltBytes in
            CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),input.bindMemory(to:Int8.self).baseAddress,bytes.count,
                                saltBytes.bindMemory(to:UInt8.self).baseAddress,salt.count,CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),600_000,&output,output.count)
        } }
        guard status == kCCSuccess else { throw APIError.message("无法处理备份密码") }
        return SymmetricKey(data:output)
    }
    private static func lines(_ values:[[String]]) throws -> Data {
        var data = Data()
        for row in values { data.append(try JSONEncoder().encode(row)); data.append(10) }; return data
    }
    private static func crc(_ data:Data) -> UInt32 { data.withUnsafeBytes { UInt32(crc32(0,$0.bindMemory(to:Bytef.self).baseAddress,uInt(data.count))) } }
    private static func transform(_ input:Data,inflate:Bool,limit:Int = 512 * 1024 * 1024) throws -> Data {
        var stream = z_stream()
        let status = inflate ? inflateInit2_(&stream,-MAX_WBITS,ZLIB_VERSION,Int32(MemoryLayout<z_stream>.size)) : deflateInit2_(&stream,Z_DEFAULT_COMPRESSION,Z_DEFLATED,-MAX_WBITS,8,Z_DEFAULT_STRATEGY,ZLIB_VERSION,Int32(MemoryLayout<z_stream>.size))
        guard status == Z_OK else { throw APIError.message("备份压缩初始化失败") }
        defer { if inflate { inflateEnd(&stream) } else { deflateEnd(&stream) } }
        return try input.withUnsafeBytes { source in
            stream.next_in = UnsafeMutablePointer(mutating:source.bindMemory(to:Bytef.self).baseAddress); stream.avail_in = uInt(input.count)
            var result = Data(), buffer = [UInt8](repeating:0,count:65536)
            while true {
                let (code,count) = buffer.withUnsafeMutableBytes { destination -> (Int32,Int) in
                    stream.next_out = destination.bindMemory(to:Bytef.self).baseAddress; stream.avail_out = uInt(destination.count)
                    let code = inflate ? zlib.inflate(&stream,Z_NO_FLUSH) : deflate(&stream,Z_FINISH)
                    return (code,destination.count - Int(stream.avail_out))
                }
                guard result.count + count <= limit else { throw APIError.message("备份解压数据超过上限") }
                result.append(contentsOf:buffer.prefix(count))
                if code == Z_STREAM_END { guard stream.avail_in == 0 else { throw APIError.message("备份压缩数据尾部无效") }; return result }
                guard code == Z_OK else { throw APIError.message("备份压缩数据损坏") }
            }
        }
    }
    private static func zip(_ files:[(String,Data)]) throws -> Data {
        var output = Data(), central = Data()
        for (name,bytes) in files {
            let payload = try transform(bytes,inflate:false), filename = Data(name.utf8), offset = output.count, checksum = crc(bytes)
            output.le(0x04034b50,4); output.le(20,2); output.le(0,2); output.le(8,2); output.le(0,4)
            output.le(Int(checksum),4); output.le(payload.count,4); output.le(bytes.count,4); output.le(filename.count,2); output.le(0,2); output.append(filename); output.append(payload)
            central.le(0x02014b50,4); central.le(20,2); central.le(20,2); central.le(0,2); central.le(8,2); central.le(0,4)
            central.le(Int(checksum),4); central.le(payload.count,4); central.le(bytes.count,4); central.le(filename.count,2); central.le(0,2); central.le(0,2); central.le(0,2); central.le(0,2); central.le(0,4); central.le(offset,4); central.append(filename)
        }
        let start = output.count; output.append(central)
        output.le(0x06054b50,4); output.le(0,2); output.le(0,2); output.le(files.count,2); output.le(files.count,2); output.le(central.count,4); output.le(start,4); output.le(0,2)
        return output
    }
    private static func entries(_ data:Data) throws -> [String:Data] {
        var offset = 0, files:[String:Data] = [:], total = 0
        while try data.integer(offset,4) == 0x04034b50 {
            guard try data.integer(offset+6,2) == 0, try data.integer(offset+8,2) == 8 else { throw APIError.message("不支持此备份压缩方式") }
            let checksum = try data.integer(offset+14,4), size = try data.integer(offset+18,4), original = try data.integer(offset+22,4)
            let length = try data.integer(offset+26,2), extra = try data.integer(offset+28,2), start = offset + 30 + length + extra
            guard start <= data.count, size <= data.count-start, original <= 512*1024*1024-total,
                  let name = String(data:data.subdata(in:offset+30..<offset+30+length),encoding:.utf8),
                  ["manifest.json","data/roots.jsonl","data/nodes.jsonl"].contains(name), files[name] == nil else { throw APIError.message("备份文件目录无效") }
            let bytes = try transform(data.subdata(in:start..<start+size),inflate:true,limit:original)
            guard bytes.count == original, Int(crc(bytes)) == checksum else { throw APIError.message("备份文件校验失败") }
            files[name] = bytes; total += bytes.count; offset = start+size
        }
        guard files.count == 3, try data.integer(offset,4) == 0x02014b50,
              let manifestData = files["manifest.json"], let manifest = try JSONSerialization.jsonObject(with:manifestData) as? [String:Any],
              manifest["format"] as? String == "app.anishelf.archive", manifest["version"] as? Int == 3,
              manifest["minimumReader"] as? Int == 3, let checksums = manifest["checksums"] as? [String:String] else { throw APIError.message("不支持此备份版本或文件不完整") }
        for name in ["data/roots.jsonl","data/nodes.jsonl"] { guard let bytes = files[name], checksums[name] == LibraryDatabase.digest(bytes) else { throw APIError.message("备份内容摘要不一致") } }
        guard data.count >= 22, try data.integer(data.count-22,4) == 0x06054b50 else { throw APIError.message("备份文件尾部缺失") }
        return files
    }
}
private extension Data {
    mutating func le(_ value:Int,_ count:Int) { for shift in 0..<count { append(UInt8(truncatingIfNeeded:value >> (shift*8))) } }
    func integer(_ offset:Int,_ count:Int) throws -> Int {
        guard offset >= 0, count <= self.count-offset else { throw APIError.message("备份文件截断") }
        return (0..<count).reduce(0) { $0 | Int(self[offset+$1]) << ($1*8) }
    }
}
/// Lossless JSON value used only at interchange boundaries.
struct JSONValue: Codable {
    let value:Any
    init(_ value:Any) { self.value = value }
    init(from decoder:Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { value = NSNull() }
        else if let v = try? c.decode(Bool.self) { value = v }
        else if let v = try? c.decode(String.self) { value = v }
        else if let v = try? c.decode(Int64.self) { value = v }
        else if let v = try? c.decode(Double.self) { value = v }
        else if let v = try? c.decode([String:JSONValue].self) { value = v.mapValues(\.value) }
        else { value = try c.decode([JSONValue].self).map(\.value) }
    }
    func encode(to encoder:Encoder) throws {
        var c = encoder.singleValueContainer()
        switch value {
        case is NSNull: try c.encodeNil()
        case let v as String: try c.encode(v)
        case let v as [String:Any]: try c.encode(v.mapValues(JSONValue.init))
        case let v as [Any]: try c.encode(v.map(JSONValue.init))
        case let v as NSNumber:
            if CFGetTypeID(v) == CFBooleanGetTypeID() { try c.encode(v.boolValue) } else { try c.encode(v.doubleValue) }
        default: throw APIError.message("无法编码备份值")
        }
    }
}

/// A small encrypted intent makes the SQLite/Keychain boundary recoverable after process death.
/// A committed transaction finishes preferences; an uncommitted one restores external state.
enum LocalReset {
    static let pendingKey = "localReset.pending"
    private static let lock = NSLock()
    static var pending:Bool { UserDefaults.standard.bool(forKey:pendingKey) }

    static func apply(directory:URL) throws {
        lock.lock(); defer { lock.unlock() }
        guard pending else { return }
        guard let domain = Bundle.main.bundleIdentifier else { throw APIError.message("无法识别本机设置") }
        let names = Credentials.names + ["cloud.access","cloud.secret","cloud.libraryKey",LibraryImportRecovery.keyName(directory)]
        try Credentials.writeValues(Dictionary(uniqueKeysWithValues:names.map { ($0,"") }))
        #if os(iOS)
        try TokenVault.delete()
        #endif
        for url in [directory, URL.cachesDirectory.appending(path:"AniShelf")] {
            if FileManager.default.fileExists(atPath:url.path) { try FileManager.default.removeItem(at:url) }
        }
        UserDefaults.standard.removePersistentDomain(forName:domain)
    }
}

@MainActor enum LibraryImportRecovery {
    nonisolated static let cloudCredentialNames = ["cloud.access","cloud.secret","cloud.libraryKey"]
    nonisolated static let layoutKeys = ["shelf.cardWidth","shelf.phoneStillWidth","shelf.stillWidth","shelf.phoneEpisodeWidth","shelf.episodeWidth"]
    private struct Intent:Codable {
        var id:String
        var credentials:[String:String]
        var diagnostics:Data
        var preferences:[String:String]
        var oauth:String?
    }
    private static func file(_ directory:URL) -> URL { directory.appendingPathComponent("import-recovery.sealed") }
    nonisolated static func keyName(_ directory:URL) -> String { "storage.recovery." + LibraryDatabase.digest(Data(directory.standardizedFileURL.path.utf8)) }
    static func prepare(directory:URL,credentials:[String:String],diagnostics:Data,preferences:[String:String],write:([String:String]) throws -> Void) throws -> String {
        guard !FileManager.default.fileExists(atPath:file(directory).path) else { throw APIError.message("请先重新打开应用完成上次导入恢复") }
        let key = SymmetricKey(size:.bits256), id = UUID().uuidString
        var intent = Intent(id:id,credentials:credentials,diagnostics:diagnostics,preferences:preferences)
        #if os(iOS)
        intent.oauth = try TokenVault.readChecked()
        #endif
        try write([keyName(directory):key.withUnsafeBytes { Data($0).base64EncodedString() }])
        do {
            let data = try AES.GCM.seal(JSONEncoder().encode(intent),using:key).combined!
            try data.write(to:file(directory),options:.atomic)
        } catch { try? write([keyName(directory):""]); throw error }
        return id
    }
    static func recover(directory:URL,database:LibraryDatabase,diagnostics:DiagnosticLog,defaults:UserDefaults = .standard,
                        read:(String) throws -> String = Credentials.readChecked,write:([String:String]) throws -> Void = Credentials.writeValues) throws {
        guard FileManager.default.fileExists(atPath:file(directory).path) else { return }
        guard let bytes = Data(base64Encoded:try read(keyName(directory))), bytes.count == 32 else { throw APIError.message("无法读取导入恢复密钥，已停止修改资料库") }
        let plaintext = try AES.GCM.open(AES.GCM.SealedBox(combined:Data(contentsOf:file(directory))),using:SymmetricKey(data:bytes))
        let intent = try JSONDecoder().decode(Intent.self,from:plaintext)
        if try database.state("import.committed") == intent.id {
            applyPreferences(intent.preferences,defaults:defaults)
            #if os(iOS)
            let token = try read("anilist.token")
            if token.isEmpty { try TokenVault.delete() } else { try TokenVault.write(token) }
            #endif
        } else {
            try write(intent.credentials)
            try diagnostics.restoreArchive(intent.diagnostics)
            #if os(iOS)
            if let token = intent.oauth { try TokenVault.write(token) } else { try TokenVault.delete() }
            #endif
        }
        // Removing the intent first is safe: all required recovery has finished.
        try FileManager.default.removeItem(at:file(directory))
        try? write([keyName(directory):""])
    }
    static func applyPreferences(_ values:[String:String],defaults:UserDefaults) {
        for key in ["workspace.destination","artwork.cacheLimitMB"] { if let text = values[key], let value = Int(text) { defaults.set(key == "artwork.cacheLimitMB" ? min(4096,max(0,value)) : value,forKey:key) } }
        for key in layoutKeys {
            if let text = values[key], let value = Double(text), value.isFinite, value > 0 { defaults.set(value,forKey:key) }
        }
        let cloudConfiguration = values["cloud.configuration"].flatMap { Data(base64Encoded:$0) } ?? defaults.data(forKey:"cloud.configuration")
        if let data = cloudConfiguration, var config = (try? JSONSerialization.jsonObject(with:data)) as? [String:Any] {
            config["enabled"] = false
            if let encoded = try? JSONSerialization.data(withJSONObject:config) { defaults.set(encoded,forKey:"cloud.configuration") }
        }
        if let text = values["cloud.events"], let data = Data(base64Encoded:text),
           let events = try? JSONDecoder().decode([String].self,from:data) {
            defaults.set(Array(events.prefix(100)),forKey:"cloud.events")
        }
        if let text = values["cloud.lastSuccess"], let seconds = Double(text), seconds.isFinite {
            defaults.set(Date(timeIntervalSince1970:seconds),forKey:"cloud.lastSuccess")
        }
        defaults.set(values["anilist.clientID"] ?? "",forKey:"anilist.clientID")
    }
}
