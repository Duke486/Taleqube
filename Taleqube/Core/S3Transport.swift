import Foundation
import CryptoKit
import zlib

/// Secret material is stored separately from the S3 connection credentials.
struct CloudKeyMaterial:Codable, Equatable {
    let version:Int
    let libraryID:String
    let key:Data

    static func generate() -> CloudKeyMaterial {
        let key = SymmetricKey(size:.bits256).withUnsafeBytes { Data($0) }
        return CloudKeyMaterial(version:1,libraryID:UUID().uuidString.lowercased(),key:key)
    }
    func validate() throws {
        guard version == 1, UUID(uuidString:libraryID) != nil, key.count == 32 else {
            throw CloudObjectCipher.Failure.invalidKey
        }
    }
    func encoded() throws -> String {
        try validate()
        return try JSONEncoder().encode(self).base64EncodedString()
    }
    static func decode(_ text:String) throws -> CloudKeyMaterial {
        let compact = text.filter { !$0.isWhitespace }
        guard compact.count <= 1024, let data = Data(base64Encoded:compact),
              let material = try? JSONDecoder().decode(Self.self,from:data) else {
            throw CloudObjectCipher.Failure.invalidKey
        }
        try material.validate()
        return material
    }
}

/// Encryption primitives for the versioned cloud object format. Key distribution and
/// migration must be completed before encrypted objects can replace the v1 journal.
struct CloudObjectCipher {
    enum Kind:String { case content, operation, checkpoint, credential }
    enum Failure:Error { case invalidKey, invalidIdentity, invalidObject, authentication }
    private let encryptionKey:SymmetricKey
    private let identityKey:SymmetricKey
    private let libraryID:String

    init(key:Data,libraryID:String) throws {
        guard key.count == 32 else { throw Failure.invalidKey }
        guard let id = UUID(uuidString:libraryID) else { throw Failure.invalidIdentity }
        self.libraryID = id.uuidString.lowercased()
        let root = SymmetricKey(data:key)
        let salt = Data("AniShelf cloud object v2".utf8)
        encryptionKey = HKDF<SHA256>.deriveKey(inputKeyMaterial:root,salt:salt,info:Data("encryption".utf8),outputByteCount:32)
        identityKey = HKDF<SHA256>.deriveKey(inputKeyMaterial:root,salt:salt,info:Data("identity".utf8),outputByteCount:32)
    }
    private func context(_ kind:Kind) -> Data {
        Data("anishelf\u{0}2\u{0}\(libraryID)\u{0}\(kind.rawValue)\u{0}".utf8)
    }
    func identifier(_ plaintext:Data,kind:Kind) -> String {
        let mac = HMAC<SHA256>.authenticationCode(for:context(kind) + plaintext,using:identityKey)
        return mac.map { String(format:"%02x",$0) }.joined()
    }
    func seal(_ plaintext:Data,kind:Kind) throws -> Data {
        let id = identifier(plaintext,kind:kind)
        return try AES.GCM.seal(plaintext,using:encryptionKey,authenticating:context(kind) + Data(id.utf8)).combined!
    }
    static func validIdentifier(_ identifier:String) -> Bool {
        identifier.utf8.count == 64 && identifier.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    func open(_ ciphertext:Data,kind:Kind,identifier:String) throws -> Data {
        guard Self.validIdentifier(identifier) else { throw Failure.invalidObject }
        do {
            let box = try AES.GCM.SealedBox(combined:ciphertext)
            let plain = try AES.GCM.open(box,using:encryptionKey,authenticating:context(kind) + Data(identifier.utf8))
            guard self.identifier(plain,kind:kind) == identifier else { throw Failure.authentication }
            return plain
        } catch { throw Failure.authentication }
    }
}

/// The encrypted manifest is published only after every referenced chunk is durable.
/// Readers assemble the entire payload before handing it to the journal.
struct CloudEncryptedPackage {
    struct Manifest:Codable {
        let version:Int
        let chunks:[String]
        let byteCount:Int
        let payloadID:String
        var covered:[String]? = nil
    }
    let manifestID:String
    let manifest:Data
    let chunks:[String:Data]

    private static func transform(_ input:Data,inflate:Bool,limit:Int) throws -> Data {
        guard input.count <= Int(UInt32.max), limit >= 0 else { throw CloudObjectCipher.Failure.invalidObject }
        var stream = z_stream()
        let status = inflate ? inflateInit2_(&stream,-MAX_WBITS,ZLIB_VERSION,Int32(MemoryLayout<z_stream>.size)) : deflateInit2_(&stream,Z_DEFAULT_COMPRESSION,Z_DEFLATED,-MAX_WBITS,8,Z_DEFAULT_STRATEGY,ZLIB_VERSION,Int32(MemoryLayout<z_stream>.size))
        guard status == Z_OK else { throw CloudObjectCipher.Failure.invalidObject }
        defer { if inflate { inflateEnd(&stream) } else { deflateEnd(&stream) } }
        return try input.withUnsafeBytes { source in
            stream.next_in = UnsafeMutablePointer(mutating:source.bindMemory(to:Bytef.self).baseAddress)
            stream.avail_in = uInt(input.count)
            var output = Data(), buffer = [UInt8](repeating:0,count:65536)
            while true {
                let (code,count) = buffer.withUnsafeMutableBytes { target -> (Int32,Int) in
                    stream.next_out = target.bindMemory(to:Bytef.self).baseAddress
                    stream.avail_out = uInt(target.count)
                    let code = inflate ? zlib.inflate(&stream,Z_NO_FLUSH) : deflate(&stream,Z_FINISH)
                    return (code,target.count - Int(stream.avail_out))
                }
                guard count <= limit - output.count else { throw CloudObjectCipher.Failure.invalidObject }
                output.append(contentsOf:buffer.prefix(count))
                if code == Z_STREAM_END {
                    guard stream.avail_in == 0 else { throw CloudObjectCipher.Failure.invalidObject }
                    return output
                }
                guard code == Z_OK else { throw CloudObjectCipher.Failure.invalidObject }
            }
        }
    }

    static func make(_ payload:Data,cipher:CloudObjectCipher,chunkSize:Int = 1024 * 1024,covered:[String]? = nil) throws -> Self {
        guard chunkSize > 0, chunkSize <= Int(UInt32.max) else { throw CloudObjectCipher.Failure.invalidObject }
        var chunks:[String:Data] = [:], ids:[String] = []
        var ranges:[Range<Int>] = []
        if chunkSize < 16 * 1024 {
            for start in stride(from:0,to:payload.count,by:chunkSize) { ranges.append(start..<(start + min(chunkSize,payload.count-start))) }
        } else {
            let window = 64, base:UInt64 = 257
            var factor:UInt64 = 1
            for _ in 0..<window { factor = factor &* base }
            let bytes = [UInt8](payload), minimum = min(16 * 1024,chunkSize)
            var start = 0, hash:UInt64 = 0
            for offset in bytes.indices {
                hash = hash &* base &+ UInt64(bytes[offset])
                if offset >= window { hash = hash &- UInt64(bytes[offset-window]) &* factor }
                let count = offset - start + 1
                if count >= chunkSize || (count >= minimum && hash & 0xffff == 0) {
                    ranges.append(start..<(offset+1)); start = offset+1
                }
            }
            if start < bytes.count { ranges.append(start..<bytes.count) }
        }
        for range in ranges {
            let chunk = payload.subdata(in:range)
            let compressed = try transform(chunk,inflate:false,limit:chunk.count + max(64,chunk.count / 100))
            let body = compressed.count < chunk.count ? Data([1]) + compressed : Data([0]) + chunk
            let id = cipher.identifier(body,kind:.content)
            ids.append(id)
            if chunks[id] == nil { chunks[id] = try cipher.seal(body,kind:.content) }
        }
        let index = Manifest(version:1,chunks:ids,byteCount:payload.count,payloadID:cipher.identifier(payload,kind:.operation),covered:covered)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let encoded = try encoder.encode(index)
        return Self(manifestID:cipher.identifier(encoded,kind:.operation),manifest:try cipher.seal(encoded,kind:.operation),chunks:chunks)
    }

    static func assemble(manifest:Data,identifier:String,cipher:CloudObjectCipher,load:(String) throws -> Data) throws -> Data {
        let index = try readManifest(manifest,identifier:identifier,cipher:cipher)
        var payload = Data()
        for id in index.chunks {
            let body = try cipher.open(load(id),kind:.content,identifier:id)
            guard let format = body.first else { throw CloudObjectCipher.Failure.invalidObject }
            let chunk:Data
            switch format {
            case 0: chunk = Data(body.dropFirst())
            case 1: chunk = try transform(Data(body.dropFirst()),inflate:true,limit:index.byteCount - payload.count)
            default: throw CloudObjectCipher.Failure.invalidObject
            }
            guard !chunk.isEmpty, chunk.count <= index.byteCount - payload.count else { throw CloudObjectCipher.Failure.invalidObject }
            payload.append(chunk)
        }
        guard payload.count == index.byteCount, cipher.identifier(payload,kind:.operation) == index.payloadID else {
            throw CloudObjectCipher.Failure.invalidObject
        }
        return payload
    }
    static func readManifest(_ manifest:Data,identifier:String,cipher:CloudObjectCipher) throws -> Manifest {
        let encoded = try cipher.open(manifest,kind:.operation,identifier:identifier)
        let index = try JSONDecoder().decode(Manifest.self,from:encoded)
        guard index.version == 1, index.byteCount >= 0, CloudObjectCipher.validIdentifier(index.payloadID),
              index.chunks.allSatisfy(CloudObjectCipher.validIdentifier),
              index.chunks.count <= index.byteCount, (index.byteCount == 0) == index.chunks.isEmpty else {
            throw CloudObjectCipher.Failure.invalidObject
        }
        return index
    }
}

struct CloudEncryptedTransport {
    let transport:S3Transport
    let cipher:CloudObjectCipher
    let prefix:String
    let cachedVersion:(String) throws -> String?
    let saveVersion:(String,String) throws -> Void
    let cachedChunk:(String) throws -> Data?
    let saveChunk:(String,Data) throws -> Void

    init(transport:S3Transport,material:CloudKeyMaterial,cachedVersion:@escaping (String) throws -> String? = { _ in nil },saveVersion:@escaping (String,String) throws -> Void = { _,_ in },
         cachedChunk:@escaping (String) throws -> Data? = { _ in nil },saveChunk:@escaping (String,Data) throws -> Void = { _,_ in }) throws {
        try material.validate()
        self.transport = transport
        cipher = try CloudObjectCipher(key:material.key,libraryID:material.libraryID)
        prefix = "anishelf/v2/" + UUID(uuidString:material.libraryID)!.uuidString.lowercased() + "/"
        self.cachedVersion = cachedVersion; self.saveVersion = saveVersion
        self.cachedChunk = cachedChunk; self.saveChunk = saveChunk
    }
    func publish(_ payload:Data,chunkSize:Int = 1024 * 1024,staged:Bool = false,checkpointCovered:[String]? = nil) async throws -> String {
        guard !(staged && checkpointCovered != nil) else { throw CloudObjectCipher.Failure.invalidObject }
        let package = try CloudEncryptedPackage.make(payload,cipher:cipher,chunkSize:chunkSize,covered:checkpointCovered)
        for id in package.chunks.keys.sorted() {
            let key = prefix + "objects/" + id
            var valid = false
            do {
                if let version = try cachedVersion(key), !version.isEmpty, !version.hasPrefix("W/") {
                    do {
                        let (_,response) = try await transport.requestResponse("HEAD",key:key,verification:true)
                        valid = response.value(forHTTPHeaderField:"ETag") == version
                    } catch S3Failure.http(_,405) { valid = false }
                    catch S3Failure.http(_,501) { valid = false }
                }
                if !valid {
                    let (existing,response) = try await transport.requestResponse("GET",key:key,verification:true)
                    do {
                        _ = try cipher.open(existing,kind:.content,identifier:id); valid = true
                        if let version = response.value(forHTTPHeaderField:"ETag"), !version.isEmpty, !version.hasPrefix("W/") { try saveVersion(key,version) }
                    }
                    catch CloudObjectCipher.Failure.authentication { valid = false }
                    catch CloudObjectCipher.Failure.invalidObject { valid = false }
                }
            } catch S3Failure.http(_,404) { /* Object is not published yet. */ }
            if valid { continue }
            _ = try await transport.request("PUT",key:key,body:package.chunks[id]!)
            let (stored,response) = try await transport.requestResponse("GET",key:key,verification:true)
            _ = try cipher.open(stored,kind:.content,identifier:id)
            try saveChunk(key,stored)
            if let version = response.value(forHTTPHeaderField:"ETag"), !version.isEmpty, !version.hasPrefix("W/") { try saveVersion(key,version) }
        }
        let location = staged ? "staging/" : checkpointCovered.map { "checkpoints/" + String(format:"%020d",$0.count) + "/" } ?? "commits/"
        let key = prefix + location + package.manifestID
        _ = try await transport.request("PUT",key:key,body:package.manifest)
        let stored = try await transport.request("GET",key:key,verification:true)
        _ = try CloudEncryptedPackage.readManifest(stored,identifier:package.manifestID,cipher:cipher)
        return key
    }
    func checkpointCoverage(_ key:String) async throws -> [String]? {
        guard key.hasPrefix(prefix + "checkpoints/") else { throw CloudObjectCipher.Failure.invalidObject }
        let id = String(key.split(separator:"/").last ?? "")
        let manifest = try await transport.request("GET",key:key)
        let index = try CloudEncryptedPackage.readManifest(manifest,identifier:id,cipher:cipher)
        if let covered = index.covered {
            let commitPrefix = prefix + "commits/"
            guard Set(covered).count == covered.count, covered.allSatisfy({
                $0.hasPrefix(commitPrefix) && CloudObjectCipher.validIdentifier(String($0.dropFirst(commitPrefix.count)))
            }) else { throw CloudObjectCipher.Failure.invalidObject }
        }
        return index.covered
    }
    func read(_ key:String) async throws -> Data {
        let commitPrefix = prefix + "commits/"
        let stagePrefix = prefix + "staging/"
        let checkpointPrefix = prefix + "checkpoints/"
        guard let selected = [commitPrefix,stagePrefix,checkpointPrefix].first(where:{ key.hasPrefix($0) }) else { throw CloudObjectCipher.Failure.invalidObject }
        let suffix = String(key.dropFirst(selected.count))
        let id = key.hasPrefix(checkpointPrefix) ? String(suffix.split(separator:"/").last ?? "") : suffix
        let manifest = try await transport.request("GET",key:key)
        let index = try CloudEncryptedPackage.readManifest(manifest,identifier:id,cipher:cipher)
        var chunks:[String:Data] = [:]
        let ids = Set(index.chunks).sorted()
        for offset in stride(from:0,to:ids.count,by:transport.config.concurrentReqs) {
            let groupIDs = ids[offset..<min(ids.count,offset + transport.config.concurrentReqs)]
            try await withThrowingTaskGroup(of:(String,Data).self) { group in
                for chunkID in groupIDs {
                    group.addTask {
                        let objectKey = prefix + "objects/" + chunkID
                        if let cached = try cachedChunk(objectKey), (try? cipher.open(cached,kind:.content,identifier:chunkID)) != nil {
                            return (chunkID,cached)
                        }
                        let (data,response) = try await transport.requestResponse("GET",key:objectKey)
                        _ = try cipher.open(data,kind:.content,identifier:chunkID)
                        try saveChunk(objectKey,data)
                        if let version = response.value(forHTTPHeaderField:"ETag"), !version.isEmpty, !version.hasPrefix("W/") { try saveVersion(objectKey,version) }
                        return (chunkID,data)
                    }
                }
                for try await (chunkID,data) in group { chunks[chunkID] = data }
            }
        }
        return try CloudEncryptedPackage.assemble(manifest:manifest,identifier:id,cipher:cipher) { chunkID in
            guard let chunk = chunks[chunkID] else { throw CloudObjectCipher.Failure.invalidObject }
            return chunk
        }
    }
}

struct S3Configuration: Codable, Equatable {
    var endpoint = "https://s3.cn-east-1.qiniucs.com"
    var bucket = ""
    var regionID = "cn-east-1"
    var timeout:Double = 30
    var addressingStyle = "auto"
    var tlsVerify = true
    var concurrentReqs = 4
    var enabled = false
    var connectionEndpoint: URLComponents? {
        guard var url = URLComponents(string:endpoint.trimmingCharacters(in:.whitespacesAndNewlines)) else { return nil }
        let qiniuHost = "s3.\(regionID.lowercased()).qiniucs.com"
        if url.scheme?.lowercased() == "http", url.port == nil,
           let host = url.host?.lowercased(), host == qiniuHost || host == bucket.lowercased() + "." + qiniuHost {
            url.scheme = "https"
        }
        return url
    }
    func destination(namespace:String = "") throws -> String {
        var endpoint = try validate()
        endpoint.scheme = "https"; endpoint.host = endpoint.host?.lowercased()
        if endpoint.port == 443 { endpoint.port = nil }
        endpoint.path = ""
        return endpoint.string! + "/" + bucket + namespace
    }
    func matchesDestination(_ previous:String,namespace:String) -> Bool {
        guard let current = connectionEndpoint, let currentHost = current.host?.lowercased(),
              let old = URLComponents(string:previous), let oldHost = old.host?.lowercased() else { return false }
        func scheme(_ components:URLComponents,_ value:String) -> String {
            let original = components.scheme?.lowercased() ?? ""
            let qiniuHost = "s3.\(regionID.lowercased()).qiniucs.com"
            if original == "http", components.port == nil, value == qiniuHost || value == bucket.lowercased() + "." + qiniuHost { return "https" }
            return original
        }
        let expectedPath = bucket + namespace
        let oldPath = old.path.drop(while:{ $0 == "/" })
        return old.user == nil && old.password == nil && old.query == nil && old.fragment == nil &&
            String(oldPath) == expectedPath && currentHost == oldHost &&
            scheme(current,currentHost) == scheme(old,oldHost) && (current.port ?? 443) == (old.port ?? 443)
    }
    @discardableResult
    func validate() throws -> URLComponents {
        guard let url = connectionEndpoint, let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/", url.url != nil else {
            throw S3Failure.message("S3 Endpoint 应为服务地址，不含账号、对象路径或查询参数")
        }
        guard url.scheme?.lowercased() == "https" else {
            throw S3Failure.message("S3 Endpoint 需要使用 HTTPS；七牛区域 HTTP 地址可自动转为 HTTPS")
        }
        guard !bucket.isEmpty, !bucket.contains("/"),
              !regionID.isEmpty, timeout >= 1, timeout <= 300, (1...16).contains(concurrentReqs),
              ["auto","path","virtual"].contains(addressingStyle) else { throw S3Failure.message("请检查 S3 空间、区域、寻址方式、超时和并发数") }
        return url
    }
}
enum S3Failure: LocalizedError {
    case message(String)
    case http(String,Int)
    var errorDescription:String? {
        switch self {
        case .message(let text): return text
        case .http(let method,let status): return "S3 \(method) 失败（HTTP \(status)），请检查区域、权限与连接设置"
        }
    }
}
struct S3Signer {
    static func hex(_ data:Data) -> String { SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined() }
    static func encode(_ text:String) -> String {
        text.utf8.map { byte in
            ((65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte) || [45,46,95,126].contains(byte)) ? String(UnicodeScalar(byte)) : String(format:"%%%02X",byte)
        }.joined()
    }
    static func sign(config:S3Configuration,access:String,secret:String,method:String,key:String,query:[String:String] = [:],body:Data = Data(),date:Date = Date()) throws -> URLRequest {
        var components = try config.validate()
        guard !access.isEmpty, !secret.isEmpty else { throw S3Failure.message("请填写 Access Key 和 Secret Key") }
        let bucketHost = components.host!.hasPrefix(config.bucket + ".")
        let virtual = config.addressingStyle == "virtual" || (config.addressingStyle == "auto" && bucketHost)
        if virtual && !bucketHost { components.host = config.bucket + "." + components.host! }
        let path = (!virtual ? [config.bucket] : []) + key.split(separator:"/",omittingEmptySubsequences:false).map(String.init)
        components.percentEncodedPath = "/" + path.map(encode).joined(separator:"/")
        let pairs: [(String,String)] = query.map { (encode($0.key),encode($0.value)) }
        let sorted = pairs.sorted { a,b in a.0 == b.0 ? a.1 < b.1 : a.0 < b.0 }
        let canonicalQuery = sorted.map { pair in pair.0 + "=" + pair.1 }.joined(separator:"&")
        components.percentEncodedQuery = canonicalQuery.isEmpty ? nil : canonicalQuery
        guard let url = components.url else { throw S3Failure.message("S3 地址无效") }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier:"en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT:0); formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let timestamp = formatter.string(from:date), day = String(timestamp.prefix(8))
        let host = components.host! + (components.port.map { ":\($0)" } ?? "")
        let digest = hex(body)
        let headers = "host:\(host)\nx-amz-content-sha256:\(digest)\nx-amz-date:\(timestamp)\n"
        let signed = "host;x-amz-content-sha256;x-amz-date"
        let canonical = [method,components.percentEncodedPath,canonicalQuery,headers,signed,digest].joined(separator:"\n")
        let scope = "\(day)/\(config.regionID)/s3/aws4_request"
        let toSign = "AWS4-HMAC-SHA256\n\(timestamp)\n\(scope)\n\(hex(Data(canonical.utf8)))"
        func hmac(_ key:Data,_ value:String) -> Data { Data(HMAC<SHA256>.authenticationCode(for:Data(value.utf8),using:SymmetricKey(data:key))) }
        let signingKey = hmac(hmac(hmac(hmac(Data(("AWS4"+secret).utf8),day),config.regionID),"s3"),"aws4_request")
        let signature = hmac(signingKey,toSign).map { String(format:"%02x",$0) }.joined()
        var request = URLRequest(url:url,timeoutInterval:config.timeout)
        request.httpMethod = method
        if method == "PUT" { request.httpBody = body }
        request.setValue(host,forHTTPHeaderField:"Host")
        request.setValue(timestamp,forHTTPHeaderField:"x-amz-date")
        request.setValue(digest,forHTTPHeaderField:"x-amz-content-sha256")
        request.setValue("AWS4-HMAC-SHA256 Credential=\(access)/\(scope), SignedHeaders=\(signed), Signature=\(signature)",forHTTPHeaderField:"Authorization")
        return request
    }
}

private final class S3SessionDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    let verify:Bool
    init(verify:Bool) { self.verify = verify }
    func urlSession(_ session:URLSession, didReceive challenge:URLAuthenticationChallenge, completionHandler:@escaping (URLSession.AuthChallengeDisposition,URLCredential?) -> Void) {
        if !verify, challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust, let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential,URLCredential(trust:trust))
        } else { completionHandler(.performDefaultHandling,nil) }
    }
    func urlSession(_ session:URLSession, task:URLSessionTask, willPerformHTTPRedirection response:HTTPURLResponse, newRequest request:URLRequest, completionHandler:@escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
struct S3Traffic: Equatable {
    var upload = 0
    var download = 0
    var verification = 0
    var listing = 0
    var other = 0
    var retryUpload = 0
    var retryDownload = 0
    var total:Int { upload + download + verification + listing + other + retryUpload + retryDownload }
}

final class S3Transport: @unchecked Sendable {
    let config:S3Configuration
    private let access:String
    private let secret:String
    private let session:URLSession
    private let trafficLock = NSLock()
    private var recordedTraffic = S3Traffic()
    var traffic:S3Traffic {
        trafficLock.lock(); defer { trafficLock.unlock() }
        return recordedTraffic
    }
    private func record(method:String,query:[String:String],verification:Bool,attempt:Int,upload:Int,download:Int) {
        trafficLock.lock(); defer { trafficLock.unlock() }
        if attempt > 0 {
            recordedTraffic.retryUpload += upload
            recordedTraffic.retryDownload += download
        } else {
            recordedTraffic.upload += upload
            if verification { recordedTraffic.verification += download }
            else if query["list-type"] != nil { recordedTraffic.listing += download }
            else if method == "GET" { recordedTraffic.download += download }
            else { recordedTraffic.other += download }
        }
    }
    init(config:S3Configuration,access:String,secret:String,session:URLSession? = nil) {
        self.config = config; self.access = access; self.secret = secret
        let settings = URLSessionConfiguration.ephemeral
        settings.httpMaximumConnectionsPerHost = config.concurrentReqs
        settings.timeoutIntervalForRequest = config.timeout
        self.session = session ?? URLSession(configuration:settings,delegate:S3SessionDelegate(verify:config.tlsVerify),delegateQueue:nil)
    }
    deinit { session.invalidateAndCancel() }
    func request(_ method:String,key:String,query:[String:String] = [:],body:Data = Data(),verification:Bool = false) async throws -> Data {
        try await requestResponse(method,key:key,query:query,body:body,verification:verification).0
    }
    func requestResponse(_ method:String,key:String,query:[String:String] = [:],body:Data = Data(),verification:Bool = false) async throws -> (Data,HTTPURLResponse) {
        for attempt in 0..<4 {
            try Task.checkCancellation()
            let request = try S3Signer.sign(config:config,access:access,secret:secret,method:method,key:key,query:query,body:body)
            do {
                let (data,response) = try await session.data(for:request)
                record(method:method,query:query,verification:verification,attempt:attempt,upload:method == "PUT" ? body.count : 0,download:data.count)
                guard let response = response as? HTTPURLResponse else { throw S3Failure.message("S3 响应无效") }
                if (200..<300).contains(response.statusCode) { return (data,response) }
                if [408,429,500,502,503,504].contains(response.statusCode), attempt < 3 {
                    try await Task.sleep(for:.seconds(Double(1 << attempt) + Double.random(in:0...0.4))); continue
                }
                // Do not surface response bodies: some providers echo request credentials.
                throw S3Failure.http(method,response.statusCode)
            } catch let error as URLError where attempt < 3 && [.timedOut,.networkConnectionLost,.cannotConnectToHost,.notConnectedToInternet].contains(error.code) {
                try await Task.sleep(for:.seconds(Double(1 << attempt)))
            }
        }
        throw S3Failure.message("S3 请求重试未完成")
    }
    func list(prefix:String,token:String? = nil) async throws -> S3ObjectPage {
        var query = ["list-type":"2","prefix":prefix,"max-keys":"1000"]
        if let token { query["continuation-token"] = token }
        let data = try await request("GET",key:"",query:query)
        let delegate = S3ListParser(); let parser = XMLParser(data:data); parser.delegate = delegate
        guard parser.parse(), delegate.rootSeen, !delegate.truncated || !delegate.token.isEmpty else { throw S3Failure.message("S3 列举响应不完整") }
        return S3ObjectPage(keys:delegate.keys,next:delegate.truncated ? delegate.token : nil)
    }
}
struct S3ObjectPage { var keys:[String]; var next:String? }
private final class S3ListParser:NSObject,XMLParserDelegate {
    var keys:[String] = [], token = "", truncated = false, rootSeen = false
    private var element = "", text = ""
    func parser(_ parser:XMLParser,didStartElement elementName:String,namespaceURI:String?,qualifiedName:String?,attributes:[String:String]) {
        element = elementName; text = ""; if elementName == "ListBucketResult" { rootSeen = true }
    }
    func parser(_ parser:XMLParser,foundCharacters string:String) { text += string }
    func parser(_ parser:XMLParser,didEndElement elementName:String,namespaceURI:String?,qualifiedName:String?) {
        switch elementName { case "Key": keys.append(text); case "NextContinuationToken": token = text; case "IsTruncated": truncated = text.trimmingCharacters(in:.whitespacesAndNewlines) == "true"; default: break }
    }
}
