import Foundation

@main struct CloudProtocolChecks {
    static func main() throws {
        var config = S3Configuration(); config.bucket = "test-bucket"
        let request = try S3Signer.sign(config:config,access:"example-access",secret:"example-secret",method:"GET",key:"中文/a b+%",query:["prefix":"a/b","list-type":"2"],date:Date(timeIntervalSince1970:0))
        precondition(request.url!.absoluteString.contains("%E4%B8%AD%E6%96%87/a%20b%2B%25"))
        precondition(request.url!.absoluteString.contains("list-type=2&prefix=a%2Fb"))
        precondition(request.value(forHTTPHeaderField:"Authorization")!.contains("19700101/cn-east-1/s3/aws4_request"))
        config.addressingStyle = "virtual"
        let virtual = try S3Signer.sign(config:config,access:"a",secret:"b",method:"PUT",key:"operations/id",body:Data("hello".utf8))
        precondition(virtual.url!.host == "test-bucket.s3.cn-east-1.qiniucs.com")
        precondition(virtual.httpBody == Data("hello".utf8))
        config.endpoint = "http://s3.cn-south-1.qiniucs.com/"
        config.regionID = "cn-south-1"
        config.addressingStyle = "path"
        let qiniu = try S3Signer.sign(config:config,access:"a",secret:"b",method:"GET",key:"probe")
        precondition(qiniu.url?.absoluteString == "https://s3.cn-south-1.qiniucs.com/test-bucket/probe")
        config.endpoint = "http://s3.example.com"
        do { try config.validate(); fatalError("Accepted unencrypted S3 endpoint") } catch is S3Failure {}
        let a = CloudOperation(id:"a:1",device:"a",sequence:1,field:"rating",parents:[],timestamp:Date(timeIntervalSince1970:100),value:Data("7".utf8))
        let b = CloudOperation(id:"b:1",device:"b",sequence:1,field:"rating",parents:["a:1"],timestamp:Date(timeIntervalSince1970:50),value:nil)
        var forward = CloudRegister(), reverse = CloudRegister()
        try forward.insert(a); try forward.insert(b)
        try reverse.insert(b); try reverse.insert(a); try reverse.insert(a)
        precondition(forward.winner == b && reverse.winner == b)
        precondition(forward.frontier == reverse.frontier)
        let c = CloudOperation(id:"c:1",device:"c",sequence:1,field:"rating",parents:[],timestamp:Date(timeIntervalSince1970:60),value:Data("9".utf8))
        try forward.insert(c); try reverse.insert(c)
        precondition(forward.frontier.count == 2 && forward.frontier == reverse.frontier)
        var changed = a; changed.value = Data("8".utf8)
        do { try forward.insert(changed); fatalError("ID collision accepted") } catch CloudJournalError.invalidOperation {}
        let stub = try a.compacted()
        var compacted = CloudRegister()
        try compacted.insert(stub); try compacted.insert(b)
        precondition(compacted.winner == b)
        try compacted.insert(a)
        precondition(compacted.operations[a.id] == a)
        do { try compacted.insert(try changed.compacted()); fatalError("Mismatched compacted operation accepted") } catch CloudJournalError.invalidOperation {}
        let key = Data(repeating:7,count:32), library = UUID().uuidString
        let cipher = try CloudObjectCipher(key:key,libraryID:library)
        let plaintext = Data("private credential and library metadata".utf8)
        let identity = cipher.identifier(plaintext,kind:.content)
        let encrypted = try cipher.seal(plaintext,kind:.content)
        let decrypted = try cipher.open(encrypted,kind:.content,identifier:identity)
        let secondCiphertext = try cipher.seal(plaintext,kind:.content)
        precondition(decrypted == plaintext)
        precondition(encrypted != secondCiphertext)
        precondition(identity != cipher.identifier(plaintext,kind:.credential))
        let otherLibrary = try CloudObjectCipher(key:key,libraryID:UUID().uuidString)
        precondition(identity != otherLibrary.identifier(plaintext,kind:.content))
        do { _ = try otherLibrary.open(encrypted,kind:.content,identifier:identity); fatalError("Cross-library object accepted") } catch CloudObjectCipher.Failure.authentication {}
        let wrongKey = try CloudObjectCipher(key:Data(repeating:8,count:32),libraryID:library)
        do { _ = try wrongKey.open(encrypted,kind:.content,identifier:identity); fatalError("Wrong key accepted") } catch CloudObjectCipher.Failure.authentication {}
        do { _ = try cipher.open(encrypted,kind:.content,identifier:String(repeating:"0",count:64)); fatalError("Wrong object identity accepted") } catch CloudObjectCipher.Failure.authentication {}
        do { _ = try cipher.open(encrypted,kind:.credential,identifier:identity); fatalError("Wrong object type accepted") } catch CloudObjectCipher.Failure.authentication {}
        var corrupt = encrypted; corrupt[corrupt.count - 1] ^= 1
        do { _ = try cipher.open(corrupt,kind:.content,identifier:identity); fatalError("Corrupt object accepted") } catch CloudObjectCipher.Failure.authentication {}
        do { _ = try CloudObjectCipher(key:Data(repeating:1,count:16),libraryID:library); fatalError("Short key accepted") } catch CloudObjectCipher.Failure.invalidKey {}
        let material = CloudKeyMaterial.generate(), another = CloudKeyMaterial.generate()
        let restoredMaterial = try CloudKeyMaterial.decode("  " + material.encoded() + "\n")
        precondition(restoredMaterial == material && material != another && material.key.count == 32)
        do { _ = try CloudKeyMaterial.decode("invalid"); fatalError("Invalid recovery code accepted") } catch CloudObjectCipher.Failure.invalidKey {}
        let invalidMaterial = CloudKeyMaterial(version:2,libraryID:library,key:key)
        do { _ = try invalidMaterial.encoded(); fatalError("Unknown key format accepted") } catch CloudObjectCipher.Failure.invalidKey {}
        let payload = Data("abcdabcdxyz".utf8)
        let package = try CloudEncryptedPackage.make(payload,cipher:cipher,chunkSize:4)
        precondition(package.chunks.count == 2)
        let assembled = try CloudEncryptedPackage.assemble(manifest:package.manifest,identifier:package.manifestID,cipher:cipher) { id in
            guard let value = package.chunks[id] else { throw CloudObjectCipher.Failure.invalidObject }
            return value
        }
        precondition(assembled == payload)
        do {
            _ = try CloudEncryptedPackage.assemble(manifest:package.manifest,identifier:package.manifestID,cipher:cipher) { _ in throw CloudObjectCipher.Failure.invalidObject }
            fatalError("Incomplete package accepted")
        } catch CloudObjectCipher.Failure.invalidObject {}
        let empty = try CloudEncryptedPackage.make(Data(),cipher:cipher)
        let emptyResult = try CloudEncryptedPackage.assemble(manifest:empty.manifest,identifier:empty.manifestID,cipher:cipher) { _ in fatalError("Unexpected chunk") }
        precondition(emptyResult.isEmpty)
        let repetitive = Data(repeating:65,count:100_000)
        let compressedPackage = try CloudEncryptedPackage.make(repetitive,cipher:cipher)
        precondition(compressedPackage.chunks.values.reduce(0) { $0 + $1.count } < 1000)
        let expanded = try CloudEncryptedPackage.assemble(manifest:compressedPackage.manifest,identifier:compressedPackage.manifestID,cipher:cipher) { compressedPackage.chunks[$0]! }
        precondition(expanded == repetitive)
        var random:UInt64 = 918273
        var fixture = Data()
        for _ in 0..<2_000_000 {
            random ^= random << 13; random ^= random >> 7; random ^= random << 17
            fixture.append(UInt8(truncatingIfNeeded:random))
        }
        var editedFixture = fixture
        editedFixture.insert(contentsOf:Data("small edit".utf8),at:1000)
        let beforeChunks = try CloudEncryptedPackage.make(fixture,cipher:cipher)
        let afterChunks = try CloudEncryptedPackage.make(editedFixture,cipher:cipher)
        let sharedChunks = Set(beforeChunks.chunks.keys).intersection(afterChunks.chunks.keys)
        let reused = sharedChunks.reduce(0) { $0 + beforeChunks.chunks[$1]!.count }
        precondition(reused > 1_000_000)
        let recoveredEdit = try CloudEncryptedPackage.assemble(manifest:afterChunks.manifest,identifier:afterChunks.manifestID,cipher:cipher) { afterChunks.chunks[$0]! }
        precondition(recoveredEdit == editedFixture)
        var damagedChunk = compressedPackage.chunks.values.first!
        damagedChunk.removeLast()
        do {
            _ = try CloudEncryptedPackage.assemble(manifest:compressedPackage.manifest,identifier:compressedPackage.manifestID,cipher:cipher) { _ in damagedChunk }
            fatalError("Truncated compressed chunk accepted")
        } catch CloudObjectCipher.Failure.authentication {}
        print("10 cloud protocol checks passed")
    }
}
