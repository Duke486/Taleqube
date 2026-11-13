import Foundation

final class S3Probe:URLProtocol, @unchecked Sendable {
    static var requests:[URLRequest] = []
    static var response:(URLRequest)->(Int,Data) = { _ in (200,Data()) }
    override class func canInit(with request:URLRequest) -> Bool { true }
    override class func canonicalRequest(for request:URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.append(request)
        let (status,data) = Self.response(request)
        client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:status,httpVersion:nil,headerFields:[:])!,cacheStoragePolicy:.notAllowed)
        client?.urlProtocol(self,didLoad:data); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
@main struct S3TransportChecks {
    static func main() async throws {
        var config = S3Configuration(); config.bucket = "bucket"
        let options = URLSessionConfiguration.ephemeral; options.protocolClasses = [S3Probe.self]
        let transport = S3Transport(config:config,access:"test",secret:"secret",session:URLSession(configuration:options))
        S3Probe.response = { _ in (200,Data("<ListBucketResult><Contents><Key>anishelf/a&amp;b.json</Key></Contents><IsTruncated>true</IsTruncated><NextContinuationToken>x+/=</NextContinuationToken></ListBucketResult>".utf8)) }
        let first = try await transport.list(prefix:"anishelf/")
        precondition(first.keys == ["anishelf/a&b.json"] && first.next == "x+/=")
        S3Probe.response = { request in
            precondition(request.url!.absoluteString.contains("continuation-token=x%2B%2F%3D"))
            return (200,Data("<ListBucketResult><IsTruncated>false</IsTruncated></ListBucketResult>".utf8))
        }
        let second = try await transport.list(prefix:"anishelf/",token:first.next)
        precondition(second.next == nil && second.keys.isEmpty)
        S3Probe.response = { _ in (200,Data("<ListBucketResult><IsTruncated>true</IsTruncated></ListBucketResult>".utf8)) }
        do { _ = try await transport.list(prefix:"x"); fatalError("Accepted missing continuation token") } catch {}
        S3Probe.response = { _ in (403,Data("sensitive response".utf8)) }
        do { _ = try await transport.request("GET",key:"x"); fatalError("Accepted unauthorized") }
        catch { precondition(!error.localizedDescription.contains("sensitive response")) }
        let before = transport.traffic
        S3Probe.response = { _ in (200,Data("abc".utf8)) }
        _ = try await transport.request("PUT",key:"x",body:Data("12345".utf8))
        _ = try await transport.request("GET",key:"x",verification:true)
        _ = try await transport.request("GET",key:"x")
        let after = transport.traffic
        precondition(after.upload - before.upload == 5 && after.verification - before.verification == 3 && after.download - before.download == 3 && after.other - before.other == 3)
        precondition(before.listing > 0)
        precondition(S3Probe.requests.allSatisfy { $0.value(forHTTPHeaderField:"Authorization")?.hasPrefix("AWS4-HMAC-SHA256") == true })
        print("5 S3 transport checks passed")
    }
}
