import Foundation

@main struct MatchingChecks {
    @MainActor static func main() async throws {
        var count = 0
        func check(_ value:Bool,_ name:String) { precondition(value,name); count += 1; print("PASS: \(name)") }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MatchingFixture.self]
        let directory = FileManager.default.temporaryDirectory.appending(path:UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:directory) }
        let api = CatalogAPI(session:URLSession(configuration:configuration),credential:{ _ in "fixture" },diagnostics:DiagnosticLog(directory:directory))
        let ai = Intelligence(api:api,credential:{ _ in "fixture" })
        let search = MediaSearch(api:api,intelligence:ai)
        let entry = Work(source:.anilist,remoteID:"9",kind:.tv,title:"原始标题",original:"Original")
        MatchingFixture.mode = "first"
        let first = try await search.matchTMDB(entry)
        check(first?.remoteID == "20" && first?.overview == "最新简介","Direct search confirms candidate identity before fetching full metadata")
        check(MatchingFixture.requests.count == 3 && MatchingFixture.aiCalls == 1,"Successful title search requires one identity judgment")
        MatchingFixture.reset("empty")
        let fallback = try await search.matchTMDB(entry)
        check(fallback?.remoteID == "20" && MatchingFixture.aiCalls == 4,"Empty title search generates multiple queries then selects from their aggregate")
        check(MatchingFixture.requests.filter { $0.url?.path == "/3/search/tv" }.count == 3,"Fallback searches original title and both AI queries")
        MatchingFixture.reset("first")
        let forced = try await search.matchTMDB(entry,forceAI:true)
        check(forced?.remoteID == "20" && MatchingFixture.aiCalls == 2,"Forced AI can replace a wrong first result")
        MatchingFixture.reset("error")
        do { _ = try await search.matchTMDB(entry); preconditionFailure("Network error treated as empty") }
        catch { check(MatchingFixture.aiCalls == 0,"Failed direct search never silently invokes AI") }
        MatchingFixture.reset("first")
        let known = Work(source:.tmdb,remoteID:"20",kind:.tv,title:"Known")
        check(try await search.matchTMDB(entry,linked:known)?.remoteID == "20" && MatchingFixture.requests.isEmpty,"Known TMDB identity opens without any network request")
        MatchingFixture.reset("invalid")
        check(try await search.matchTMDB(entry,forceAI:true) == nil,"AI cannot select IDs outside supplied candidates")
        MatchingFixture.reset("first")
        let refreshed = try await api.details(entry)
        check(refreshed.source == .anilist && refreshed.title == "新来源标题" && MatchingFixture.requests.first?.url?.host == "graphql.anilist.co","Source refresh fetches the entry platform directly")
        MatchingFixture.reset("delayed")
        let noAI = Intelligence(api:api,credential:{ _ in "" })
        let store = TrackingStore(directory:directory.appending(path:"stale"),api:api,intelligence:noAI)
        let trakt = Work(source:.trakt,remoteID:"77",kind:.tv,title:"Original English",overview:"Old synopsis")
        let localization = Task { await store.localize(trakt) }
        for _ in 0..<100 {
            if MatchingFixture.requests.contains(where:{ $0.url?.path.hasSuffix("/translations/zh") == true }) { break }
            try await Task.sleep(for:.milliseconds(5))
        }
        _ = try store.clearWorkCache(from:trakt)
        await localization.value
        check(store.titleTranslation(trakt) == nil && store.overviewTranslation(trakt) == nil,"Metadata response started before cache reset cannot repopulate cleared translations")
        MatchingFixture.reset("first")
        let publicScore = try await api.platformRatingDetails(entry)
        check(publicScore.publicRating == 8.8 && publicScore.catalogURL?.absoluteString == "https://anilist.co/anime/9","Rating refresh normalizes AniList averages and supplies a platform URL")
        let mismatchedEntry = Work(source:.anilist,remoteID:"99",kind:.tv,title:"Other")
        do { _ = try await api.platformRatingDetails(mismatchedEntry); preconditionFailure("Wrong entry score accepted") }
        catch { check(true,"Rating refresh rejects scores returned for another platform entry") }
        let shelfDirectory = directory.appending(path:"shelf")
        let shelfStore = TrackingStore(directory:shelfDirectory,api:api,intelligence:noAI)
        let sourceWork = Work(source:.anilist,remoteID:"301",kind:.tv,title:"来源标题",image:"source.jpg",year:"2024",rating:7)
        let tmdbWork = Work(source:.tmdb,remoteID:"302",kind:.tv,title:"TMDB 标题",image:"tmdb.jpg",year:"2020",rating:8)
        check(shelfStore.platformDisplay(sourceWork).image == "source.jpg","Unmatched platform entries retain source artwork")
        shelfStore.setTitle("旧来源译名",for:sourceWork,origin:"AI 翻译")
        var association = TrackingRecord(work:sourceWork)
        association.links["tmdb"] = tmdbWork
        shelfStore.saveAssociations(association)
        let matchedDisplay = shelfStore.platformDisplay(sourceWork)
        check(matchedDisplay.title == "TMDB 标题" && matchedDisplay.image == "tmdb.jpg","Matched platform entries display TMDB title and artwork instead of old source translations")
        check(matchedDisplay.id == sourceWork.id && matchedDisplay.year == sourceWork.year && matchedDisplay.rating == sourceWork.rating && !shelfStore.isInLibrary(sourceWork),"Presentation preserves platform identity and metadata without admitting entries")
        shelfStore.setTitle("人工改名",for:tmdbWork)
        check(shelfStore.platformDisplay(sourceWork).title == "人工改名","Manual canonical title edits appear on platform shelves")
        shelfStore.setTitle("AI 改名",for:tmdbWork,origin:"AI 翻译")
        check(shelfStore.platformDisplay(sourceWork).title == "AI 改名","AI canonical title edits appear on platform shelves")
        let reopened = TrackingStore(directory:shelfDirectory,api:api,intelligence:noAI)
        check(reopened.platformDisplay(sourceWork).title == "AI 改名" && reopened.platformDisplay(sourceWork).image == "tmdb.jpg","Matched presentation and edited title survive reopening")
        try shelfStore.admit(association,using:tmdbWork)
        check(shelfStore.platformDisplay(sourceWork).title == "AI 改名","Imported platform entries use the same canonical title override")
        let replacement = Work(source:.tmdb,remoteID:"303",kind:.tv,title:"修正匹配",image:"replacement.jpg")
        var corrected = shelfStore.record(sourceWork)
        corrected.links["tmdb"] = replacement
        shelfStore.saveAssociations(corrected)
        check(shelfStore.platformDisplay(sourceWork).title == "修正匹配" && shelfStore.platformDisplay(sourceWork).image == "replacement.jpg","Rematching replaces the displayed title and cover without leaking old overrides")
        let book = Work(source:.anilist,remoteID:"304",kind:.manga,title:"漫画",image:"book.jpg")
        check(shelfStore.platformDisplay(book).title == "漫画" && shelfStore.platformDisplay(book).image == "book.jpg","Book presentation remains unchanged")
        MatchingFixture.reset("first")
        _ = try await ai.matchingTurn(prompt:"Return the supplied candidate identifier.",payload:"{}")
        check(MatchingFixture.requests.last?.url?.host == "api.deepseek.com" && MatchingFixture.validJSONRequests == 1,"Flash short prompts carry the shared JSON output contract")
        _ = try await ai.matchingTurn(prompt:"Return the supplied candidate identifier.",payload:"{}")
        check(MatchingFixture.requests.last?.url?.host == "api.deepseek.com" && MatchingFixture.validJSONRequests == 2,"Flash short prompts carry the same JSON output contract")
        _ = try await ai.run(task:"Return the supplied candidate identifier.",payload:"{}")
        check(MatchingFixture.validJSONRequests == 3,"Legacy intelligence requests also share the JSON contract")
        MatchingFixture.reset("nofit")
        let recovered = try await search.matchTMDB(entry)
        check(recovered?.remoteID == "20" && MatchingFixture.aiCalls == 3,"Rejected direct candidates trigger alternative title search")
        MatchingFixture.reset("badQueries")
        let recoveredQuery = try await search.matchTMDB(entry,forceAI:true)
        check(recoveredQuery?.remoteID == "20","Malformed query schema falls back to source titles after one repair")
        check(MediaLanguage.searchTerms(["  Native\n Title  ","https://bad.example","site:example title","Native Title"]) == ["Native Title"],"Search words normalize whitespace and reject URLs and operators")
        do {
            _ = try ai.parsedResponse(["choices":[["finish_reason":"length","message":["content":"{}"]]]])
            preconditionFailure("Truncated completion accepted")
        } catch MatchingFormatError.truncated { check(true,"Finish reason rejects even syntactically valid truncated output") }
        let shared = SharedAIRequest<Int> { try await Task.sleep(nanoseconds:80_000_000); return 7 }
        let subscriberA = Task { try await shared.value() }
        let subscriberB = Task { try await shared.value() }
        try await Task.sleep(nanoseconds:10_000_000)
        subscriberA.cancel()
        do { _ = try await subscriberA.value; preconditionFailure("Canceled subscriber completed") }
        catch is CancellationError { check(true,"A canceled subscriber leaves a shared AI request immediately") }
        check(try await subscriberB.value == 7,"Remaining subscriber retains the shared AI response")
        var stopped = false
        let abandoned = SharedAIRequest<Int> {
            do { try await Task.sleep(nanoseconds:5_000_000_000); return 0 }
            catch { stopped = true; throw error }
        }
        let last = Task { try await abandoned.value() }
        try await Task.sleep(nanoseconds:10_000_000); last.cancel()
        _ = try? await last.value
        for _ in 0..<10 { await Task.yield() }
        check(stopped,"Canceling the last subscriber stops the underlying request")
        do {
            let _:Int = try await AIRequestDeadline.run(seconds:0.01) { try await Task.sleep(nanoseconds:5_000_000_000); return 0 }
            preconditionFailure("Deadline ignored")
        } catch { check(!(error is CancellationError),"Task deadline returns a visible timeout and cancels work") }
        MatchingFixture.reset("first")
        let originTrakt = Work(source:.trakt,remoteID:"77",kind:.tv,title:"Localized title",original:"",tmdbID:20)
        let canonicalTrakt = Work(source:.tmdb,remoteID:"20",kind:.tv,title:"主作品",original:"Series")
        check(try await search.matchSinglePlatform(originTrakt,platform:.trakt,origin:originTrakt,canonical:canonicalTrakt)?.id == originTrakt.id,"Trakt source resolves without searching its localized title")
        check(try await search.matchSinglePlatform(canonicalTrakt,platform:.trakt,origin:originTrakt,linked:originTrakt,canonical:canonicalTrakt)?.id == originTrakt.id,"Rematching a canonicalized Trakt record preserves the source identity")
        check(MatchingFixture.requests.isEmpty,"Known Trakt source makes zero search or AI requests")
        check(try await search.matchSinglePlatform(canonicalTrakt,platform:.trakt,origin:canonicalTrakt,linked:originTrakt,canonical:canonicalTrakt)?.id == originTrakt.id,"Shared TMDB ID resolves a saved Trakt association without AI")
        check(try await ai.match(originTrakt,candidates:[originTrakt])?.id == originTrakt.id && MatchingFixture.requests.isEmpty,"Matching an entry to itself never calls the model")
        MatchingFixture.reset("traktIDs")
        let matchedTrakt = try await search.matchSinglePlatform(canonicalTrakt,platform:.trakt,origin:canonicalTrakt,canonical:canonicalTrakt)
        check(matchedTrakt?.remoteID == "77" && MatchingFixture.aiCalls == 0,"Trakt search candidates resolve by shared TMDB ID")
        MatchingFixture.reset("traktIDs")
        var wrongSource = originTrakt; wrongSource.tmdbID = 99; wrongSource.remoteID = "99"
        let correctedTrakt = try await search.matchSinglePlatform(canonicalTrakt,platform:.trakt,origin:wrongSource,linked:wrongSource,canonical:canonicalTrakt)
        check(correctedTrakt?.remoteID == "77" && !MatchingFixture.requests.isEmpty,"Conflicting TMDB identity is not reused during rematch")
        for mode in ["platformEmpty","platformRejected"] {
            MatchingFixture.reset(mode)
            let expansionSearch = MediaSearch(api:api,intelligence:ai)
            let expanded = try await expansionSearch.matchSinglePlatform(canonicalTrakt,platform:.trakt,origin:canonicalTrakt,canonical:canonicalTrakt)
            check(expanded?.remoteID == "77","\(mode): Trakt recovers by AI plus web alias expansion")
            check(MatchingFixture.requests.contains { $0.url?.path == "/v1/tools/search" },"\(mode): fallback actually searches the web")
        }
        MatchingFixture.reset("platformNoResults")
        let noResults = try await MediaSearch(api:api,intelligence:ai).matchSinglePlatform(canonicalTrakt,platform:.trakt,origin:canonicalTrakt,canonical:canonicalTrakt)
        check(noResults == nil && MatchingFixture.requests.filter { $0.url?.path == "/v1/tools/search" }.count == 2,"Empty platform searches exhaust distinct evidence queries without inventing a match")
        MatchingFixture.reset("empty")
        let importFallback = try await MediaSearch(api:api,intelligence:ai).matchTMDB(entry)
        check(importFallback != nil && MatchingFixture.requests.contains { $0.url?.path == "/v1/tools/search" },"TMDB lookup used by batch import includes actual web research on empty search")
        print("\(count) matching checks passed.")
    }
}
final class MatchingFixture: URLProtocol, @unchecked Sendable {
    static var mode = "first"
    static var requests: [URLRequest] = []
    static var aiCalls = 0
    static var validJSONRequests = 0
    static func reset(_ value:String) { mode = value; requests = []; aiCalls = 0; validJSONRequests = 0 }
    override class func canInit(with request:URLRequest) -> Bool { true }
    override class func canonicalRequest(for request:URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.append(request)
        let url = request.url!
        if Self.mode == "delayed", url.path.hasSuffix("/translations/zh") {
            DispatchQueue.global().asyncAfter(deadline:.now() + 0.15) { [self] in
                client?.urlProtocol(self,didReceive:HTTPURLResponse(url:url,statusCode:200,httpVersion:nil,headerFields:nil)!,cacheStoragePolicy:.notAllowed)
                client?.urlProtocol(self,didLoad:try! JSONSerialization.data(withJSONObject:[["language":"zh","country":"cn","title":"旧中文标题","overview":"旧中文简介"]]))
                client?.urlProtocolDidFinishLoading(self)
            }
            return
        }
        var code = 200
        var object: [String:Any] = [:]
        func work(_ id:Int) -> [String:Any] { ["id":id,"name":"标题 \(id)","overview":"最新简介","first_air_date":"2020-01-01"] }
        if url.path == "/v1/tools/search" {
            object = ["results":[["title":"Alternative / Native / 别名","url":"https://example.com/aliases","summary":"Alternative Native 别名"]]]
        } else if url.host == "graphql.anilist.co" {
            object = ["data":["Media":["id":9,"title":["native":"新来源标题"],"description":"新来源简介","averageScore":88]]]
        } else if url.path == "/search/show" {
            var rows: [[String:Any]] = [["show":["title":"Series","ids":["trakt":77,"tmdb":20]]],["show":["title":"Series","ids":["trakt":99,"tmdb":99]]]]
            let term = URLComponents(url:url,resolvingAgainstBaseURL:false)?.queryItems?.first { $0.name == "query" }?.value ?? ""
            if Self.mode == "platformEmpty" && !["Alternative","Native"].contains(term) { rows = [] }
            if Self.mode == "platformRejected" && !["Alternative","Native"].contains(term) { rows = [["show":["title":"Unrelated","ids":["trakt":88]]]] }
            if Self.mode == "platformNoResults" { rows = [] }
            client?.urlProtocol(self,didReceive:HTTPURLResponse(url:url,statusCode:200,httpVersion:nil,headerFields:nil)!,cacheStoragePolicy:.notAllowed)
            client?.urlProtocol(self,didLoad:try! JSONSerialization.data(withJSONObject:rows)); client?.urlProtocolDidFinishLoading(self); return
        } else if url.path == "/3/search/tv" {
            let query = URLComponents(url:url,resolvingAgainstBaseURL:false)?.queryItems?.first { $0.name == "query" }?.value
            if Self.mode == "error" { code = 503 }
            object = ["results":Self.mode == "empty" && query == "原始标题" ? [] : [work(10),work(20)]]
        } else if url.path.hasPrefix("/3/tv/") {
            object = work(Int(url.lastPathComponent) ?? 10)
        } else {
            Self.aiCalls += 1
            var bodyData = request.httpBody ?? Data()
            if bodyData.isEmpty, let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var buffer = [UInt8](repeating:0,count:4096)
                while stream.hasBytesAvailable { let n = stream.read(&buffer,maxLength:buffer.count); if n <= 0 { break }; bodyData.append(buffer,count:n) }
            }
            let body = (try? JSONSerialization.jsonObject(with:bodyData)) as? [String:Any]
            let messages = body?["messages"] as? [[String:Any]]
            let instruction = messages?.first?["content"] as? String ?? ""
            let format = body?["response_format"] as? [String:String]
            // Mirror the real provider gate so missing JSON instructions fail existing identity flows too.
            if format?["type"] == "json_object" && !instruction.localizedCaseInsensitiveContains("json") {
                client?.urlProtocol(self,didReceive:HTTPURLResponse(url:url,statusCode:400,httpVersion:nil,headerFields:nil)!,cacheStoragePolicy:.notAllowed)
                client?.urlProtocol(self,didLoad:try! JSONSerialization.data(withJSONObject:["error":["message":"Prompt must contain the word 'json' to use json_object"]]))
                client?.urlProtocolDidFinishLoading(self)
                return
            }
            if format?["type"] == "json_object" { Self.validJSONRequests += 1 }
            let planning = instruction.contains("TMDB_SEARCH_TERMS") || instruction.contains("PLATFORM_SEARCH_TERMS")
            var reply = planning ? "{\"queries\":[\"Alternative\",\"Native\"]}" : "{\"candidate_id\":\"tmdb:tv:\(Self.mode == "invalid" ? "999" : "20")\"}"
            if Self.mode == "nofit" && Self.aiCalls == 1 { reply = "{\"candidate_id\":null}" }
            if Self.mode == "badQueries" && planning { reply = "{\"queries\":\"bad\"}" }
            if instruction.contains("NAME_SEARCH_PLAN") { reply = "{\"query\":\"Series aliases\"}" }
            if instruction.contains("NAME_SEARCH_ANSWER") { reply = "{\"chinese_title\":\"别名\",\"basis\":\"web\",\"title_evidence\":[0],\"names\":[{\"name\":\"Alternative\",\"evidence\":0},{\"name\":\"Native\",\"evidence\":0}]}" }
            if Self.mode == "platformRejected" && instruction.contains("Match first item") { reply = "{\"candidate_id\":null,\"certain\":false}" }
            object = ["choices":[["message":["content":reply]]]]
        }
        client?.urlProtocol(self,didReceive:HTTPURLResponse(url:url,statusCode:code,httpVersion:nil,headerFields:nil)!,cacheStoragePolicy:.notAllowed)
        client?.urlProtocol(self,didLoad:try! JSONSerialization.data(withJSONObject:object))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
