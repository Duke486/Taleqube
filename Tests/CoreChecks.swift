import Foundation

final class StubProtocol: URLProtocol {
    static var response: (Int, String) = (200, "{}")
    static var queue: [(Int, String)] = []
    static var lastRequest: URLRequest?
    static var lastBody = Data()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lastRequest = request
        Self.lastBody = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                Self.lastBody.append(contentsOf: buffer.prefix(count))
            }
        }
        let (code, body) = Self.queue.isEmpty ? Self.response : Self.queue.removeFirst()
        let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: ["Content-Type": "application/json", "Retry-After": "17"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main struct CoreChecks {
    static var checks = 0
    static func check(_ condition: @autoclosure () -> Bool, _ name: String) {
        guard condition() else { fatalError("FAIL: \(name)") }
        checks += 1; print("PASS: \(name)")
    }
    static func expectFailure(_ name: String, action: () throws -> Void) {
        do { try action(); fatalError("FAIL: \(name)") } catch { checks += 1; print("PASS: \(name)") }
    }
    static func main() async throws {
        let callback = URL(string: "anishelf://oauth#access_token=sample-token&state=expected")!
        let parsedToken = try OAuthCallback.token(from: callback, expectedState: "expected")
        check(parsedToken == "sample-token", "OAuth fragment extraction")
        expectFailure("OAuth rejects incorrect state") { _ = try OAuthCallback.token(from: callback, expectedState: "other") }
        expectFailure("OAuth rejects wrong callback") { _ = try OAuthCallback.token(from: URL(string: "other://oauth#access_token=x&state=expected")!, expectedState: "expected") }
        expectFailure("OAuth rejects absent token") { _ = try OAuthCallback.token(from: URL(string: "anishelf://oauth#state=expected")!, expectedState: "expected") }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        let api = AniListAPI(session: URLSession(configuration: config))
        let media = #"{"id":1,"type":"ANIME","title":{"native":"测试","romaji":"Test","english":null},"episodes":12}"#
        StubProtocol.response = (200, "{\"data\":{\"Page\":{\"pageInfo\":{\"hasNextPage\":true},\"media\":[\(media)]}}}")
        let page = try await api.browse(kind: .anime, search: "Test", sort: .score, page: 2)
        check(page.hasNextPage && page.media.first?.total == 12, "Browse decoding and pagination")
        check(page.media.first?.title.display == "测试", "Native title preference")
        let request = StubProtocol.lastRequest!
        let body = try JSONSerialization.jsonObject(with: StubProtocol.lastBody) as! [String: Any]
        let vars = body["variables"] as! [String: Any]
        check(vars["search"] as? String == "Test" && vars["page"] as? Int == 2, "Search and page variables")
        check(request.value(forHTTPHeaderField: "Authorization") == nil, "Public browse requires no login")
        StubProtocol.response = (200, #"{"data":{"Viewer":{"id":7,"name":"tester","avatar":null}}}"#)
        let viewer = try await api.viewer(token: "private-token")
        check(viewer.id == 7, "Viewer decoding")
        check(StubProtocol.lastRequest?.value(forHTTPHeaderField: "Authorization") == "Bearer private-token", "Bearer header")
        StubProtocol.response = (200, "{\"data\":{\"MediaListCollection\":{\"lists\":[{\"entries\":[{\"id\":9,\"status\":\"CURRENT\",\"progress\":3,\"score\":75,\"media\":\(media)}]},{\"entries\":[{\"id\":9,\"status\":\"CURRENT\",\"progress\":3,\"score\":75,\"media\":\(media)}]}]}}}")
        let library = try await api.library(userID: 7, kind: .anime, token: "private-token")
        check(library.count == 1 && library[0].progress == 3, "Custom-list duplicate removal")
        StubProtocol.queue = [
            (200, "{\"data\":{\"MediaListCollection\":{\"hasNextChunk\":true,\"lists\":[{\"entries\":[{\"id\":9,\"status\":\"CURRENT\",\"progress\":3,\"media\":\(media)}]}]}}}"),
            (200, #"{"data":{"MediaListCollection":{"hasNextChunk":false,"lists":[]}}}"#)
        ]
        let chunked = try await api.library(userID: 7, kind: .anime, token: "private-token")
        check(chunked.count == 1 && StubProtocol.queue.isEmpty, "Library follows hasNextChunk")
        let chunkBody = try JSONSerialization.jsonObject(with: StubProtocol.lastBody) as! [String: Any]
        check((chunkBody["variables"] as! [String: Any])["chunk"] as? Int == 2, "Library requests next chunk number")
        StubProtocol.response = (200, #"{"data":{"Media":{"mediaListEntry":null}}}"#)
        let emptyEntry = try await api.entry(mediaID: 1, token: "private-token")
        check(emptyEntry == nil, "Missing personal entry")
        StubProtocol.response = (200, #"{"data":{"SaveMediaListEntry":{"id":9,"status":"CURRENT","progress":4,"score":82}}}"#)
        let saved = try await api.save(mediaID: 1, status: .current, progress: 4, score: 82, token: "private-token")
        check(saved.progress == 4 && saved.score == 82, "Save response")
        let saveBody = try JSONSerialization.jsonObject(with: StubProtocol.lastBody) as! [String: Any]
        let saveVars = saveBody["variables"] as! [String: Any]
        check(saveVars["score"] as? Int == 82 && (saveBody["query"] as! String).contains("scoreRaw: $score"), "100-point score mutation")
        StubProtocol.response = (401, "{}")
        do { _ = try await api.viewer(token: "expired"); fatalError("401 accepted") }
        catch APIError.unauthorized { checks += 1; print("PASS: HTTP 401") }
        StubProtocol.response = (429, "{}")
        do { _ = try await api.viewer(token: "x"); fatalError("429 accepted") }
        catch APIError.rateLimited(let seconds) { check(seconds == 17, "Retry-After handling") }
        StubProtocol.response = (200, #"{"data":null,"errors":[{"message":"Invalid token","status":401}]}"#)
        do { _ = try await api.viewer(token: "expired"); fatalError("GraphQL 401 accepted") }
        catch APIError.unauthorized { checks += 1; print("PASS: GraphQL 401") }
        StubProtocol.response = (200, #"{"data":null,"errors":[{"message":"Invalid input","status":400}]}"#)
        do { _ = try await api.viewer(token: "x"); fatalError("GraphQL error accepted") }
        catch APIError.message(let message) { check(message == "Invalid input", "GraphQL error message") }
        StubProtocol.response = (200, #"{"data":{"Media":{"id":12,"title":{"native":"书籍"},"characters":{"edges":[{"role":"MAIN","node":{"id":8,"name":{"native":"角色"},"image":null}}],"pageInfo":{"hasNextPage":true}},"staff":{"edges":[],"pageInfo":{"hasNextPage":false}},"relations":{"edges":[]}}}}"#)
        let book = try await api.bookDetails(id:12)
        check(book.characters?.edges.first?.roleTitle == "主角" && book.volumes == nil, "Sparse book metadata preserves characters and unknown totals")
        check(StubProtocol.lastRequest?.value(forHTTPHeaderField:"Authorization") == nil, "Public book detail needs no login")
        let bookBody = try JSONSerialization.jsonObject(with:StubProtocol.lastBody) as! [String:Any]
        check(!(bookBody["query"] as! String).contains("reviews"), "Book detail excludes community reviews")
        StubProtocol.response = (200, #"{"data":{"Media":{"characters":{"edges":[],"pageInfo":{"hasNextPage":false}}}}}"#)
        let people = try await api.bookPeople(id:12,staff:false,page:2)
        let peopleBody = try JSONSerialization.jsonObject(with:StubProtocol.lastBody) as! [String:Any]
        check(people.pageInfo?.hasNextPage == false && (peopleBody["variables"] as! [String:Any])["page"] as? Int == 2, "Character pagination uses server continuation")
        StubProtocol.response = (200, #"{"data":{"Media":null}}"#)
        do { _ = try await api.bookDetails(id:12); fatalError("Missing book accepted") }
        catch { check(true,"Missing book is a retryable detail error") }
        StubProtocol.queue = [(200,#"{"data":{"Viewer":{"id":7,"name":"User"}}}"#), (200,#"{"data":{"MediaList":null}}"#)]
        try await api.deleteListEntry(mediaID:12,token:"test")
        check(StubProtocol.queue.isEmpty, "Removing an absent AniList entry succeeds without a mutation")
        print("\(checks) checks passed.")
        if CommandLine.arguments.contains("--live") {
            let live = AniListAPI()
            let anime = try await live.browse(kind: .anime, search: "Cowboy Bebop", sort: .popular, page: 1)
            check(anime.media.contains { $0.id == 1 }, "LIVE: anime search")
            let manga = try await live.browse(kind: .manga, search: "Berserk", sort: .score, page: 1)
            check(!manga.media.isEmpty && manga.media.allSatisfy { $0.type == .manga }, "LIVE: manga search")
            let trends = try await live.browse(kind: .anime, search: "", sort: .trending, page: 2)
            check(!trends.media.isEmpty, "LIVE: trending pagination")
        }
    }
}
