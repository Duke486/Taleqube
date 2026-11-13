import Foundation

@main struct BookMatchingChecks {
    @MainActor static func main() async throws {
        var count = 0
        func check(_ value:Bool,_ label:String) { precondition(value,label); count += 1; print("PASS: \(label)") }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BookFixture.self]
        let directory = FileManager.default.temporaryDirectory.appending(path:UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:directory) }
        let api = CatalogAPI(session:URLSession(configuration:configuration),credential:{ _ in "fixture" },diagnostics:DiagnosticLog(directory:directory))
        let ai = Intelligence(api:api,credential:{ _ in "fixture" })
        let search = MediaSearch(api:api,intelligence:ai)
        let bgm = try await api.search(.bangumi,kind:.manga,query:"同名作品")
        check(bgm[0].isNovel && bgm[1].isComic,"Bangumi search separates same-title novel and manga")
        check(bgm[2].format == "ARTBOOK" && !bgm[2].isComic && !bgm[3].isComic && !bgm[3].isNovel,"Artbooks and missing formats never receive manga or novel badges")
        check(bgm[0].bookSeries == true && bgm[0].volumeCount == 10 && bgm[0].chapterCount == 50,"Bangumi preserves book series and chapter/volume metadata")
        let bgmDetails = try await api.details(bgm[0])
        check(bgmDetails.isNovel && bgmDetails.bookSeries == true,"Bangumi details retain novel and series identity")
        let mal = try await api.search(.mal,kind:.manga,query:"Same Title")
        check(mal[0].format == "NOVEL" && mal[0].isNovel && mal[1].isComic && mal[2].isNovel,"MAL light_novel, manga and novel map to shared book formats")
        check(mal[0].volumeCount == 10 && mal[0].chapterCount == 50,"MAL preserves volumes and chapters")
        check(try await api.details(mal[0]).isNovel,"MAL detail refresh retains light novel format")
        check(BookFilter.novel.includes(mal[0]) && BookFilter.manga.includes(mal[1]) && !BookFilter.manga.includes(bgm[2]),"Library filters use shared book classification")
        let legacyMAL = Work(source:.mal,remoteID:"201",kind:.manga,title:"同名作品",format:"light_novel")
        check(legacyMAL.isNovel && !legacyMAL.matchesBookType(of:mal[1]),"Legacy lowercase MAL formats participate in mismatch protection")
        var volume = bgm[0]; volume.remoteID = "105"; volume.bookSeries = false
        check(!volume.matchesBookType(of:bgm[0]),"Known series and individual volumes cannot auto-match")
        let roundtrip = try JSONDecoder().decode(Work.self,from:JSONEncoder().encode(bgm[0]))
        check(roundtrip == bgm[0],"Book metadata survives backup round trip")
        let legacy = try JSONDecoder().decode(Work.self,from:Data(#"{"source":"bangumi","remoteID":"101","kind":"manga","title":"同名作品","original":"","overview":"","image":"","year":"","url":""}"#.utf8))
        check(legacy.format == nil && legacy.bookSeries == nil,"Legacy records decode without new metadata")
        let noAI = Intelligence(api:api,credential:{ _ in "" })
        let store = TrackingStore(directory:directory.appending(path:"library"),api:api,intelligence:noAI)
        let oldMAL = Work(source:.mal,remoteID:"201",kind:.manga,title:"同名作品")
        try store.admit(TrackingRecord(work:legacy),using:legacy,exception:true)
        try store.admit(TrackingRecord(work:oldMAL),using:oldMAL,exception:true)
        check(store.isInLibrary(legacy) && store.isInLibrary(oldMAL),"Legacy book fixtures persist")
        let modified = store.record(legacy).modifiedAt
        await store.resolveLibraryBookFormats()
        check(store.display(legacy).isNovel && store.display(oldMAL).isNovel,"Library backfill repairs Bangumi and MAL records")
        check(store.record(legacy).modifiedAt == modified && store.backup.deliveries.isEmpty,"Type backfill preserves dates and does not queue sync")
        let reopened = TrackingStore(directory:directory.appending(path:"library"),api:api,intelligence:noAI)
        check(reopened.display(legacy).isNovel && reopened.display(oldMAL).isNovel,"Resolved external book types survive reopening")
        BookFixture.reset()
        let match = try await search.matchSinglePlatform(legacy,platform:.anilist,origin:legacy)
        check(match?.remoteID == "12" && match?.isNovel == true,"Book auto-match enriches legacy source and chooses the novel adaptation")
        let identityPayload = BookFixture.identityPayloads.first!
        check(identityPayload.first?["format"] == "NOVEL" && identityPayload.first?["bookSeries"] == "true" && identityPayload.first?["chapters"] == "50","AI receives book medium, series, volumes and chapters")
        check(!identityPayload.dropFirst().contains { $0["format"] == "MANGA" },"Comic adaptations are removed before novel identity judgment")
        let importStore = TrackingStore(directory:directory.appending(path:"import"),api:api,intelligence:noAI)
        try importStore.admit(TrackingRecord(work:legacy),using:match!)
        check(importStore.isInLibrary(match!) && importStore.record(match!).links["bangumi"]?.id == legacy.id,"Book import saves AniList primary and preserves Bangumi association")
        BookFixture.reset()
        check(try await ai.match(bgm[0],candidates:[bgm[1],volume]) == nil && BookFixture.identityPayloads.isEmpty,"Fully conflicting medium or volume candidates require no AI request")
        BookFixture.reset(); BookFixture.selectedID = "anilist:manga:11"
        check(try await MediaSearch(api:api,intelligence:ai).matchSinglePlatform(mal[0],platform:.anilist,origin:mal[0]) == nil,"AI cannot force a comic ID excluded from a novel shortlist")
        check(BookFixture.webCalls == 2,"Rejected book candidates use the shared web alias fallback")
        BookFixture.reset(); BookFixture.emptyFirstSearch = true
        let recovered = try await MediaSearch(api:api,intelligence:ai).matchSinglePlatform(mal[0],platform:.anilist,origin:mal[0])
        check(recovered?.isNovel == true && BookFixture.webCalls == 1,"Empty book search recovers through researched aliases and confirms identity")
        BookFixture.reset()
        check(try await search.matchSinglePlatform(legacy,platform:.bangumi,origin:legacy)?.isNovel == true && BookFixture.identityPayloads.isEmpty,"Own-platform book identity refreshes without AI")
        BookFixture.reset(); BookFixture.needsEvidence = true
        var stages: [String] = []
        let reviewed = try await MediaSearch(api:api,intelligence:ai).matchSinglePlatform(mal[0],platform:.anilist,origin:mal[0]) { stages.append($0) }
        check(reviewed?.remoteID == "12" && BookFixture.identityPayloads.count == 2,"Same candidates are judged again after web research even without new aliases")
        check(BookFixture.identityPayloads.last?.first?["researchEvidence"]?.contains("novel") == true,"Actual web snippets reach the final association judgment")
        check(stages.contains { $0.hasPrefix("AI 搜索") } && stages.contains { $0.hasPrefix("读取书籍详情") } && stages.contains { $0.contains("结合补充证据") },"Book matching reports search, detail and AI judgment stages")
        check(stages.contains { $0.contains("第 2/6 轮") && $0.contains("deepseek-flash") },"Stalled book search escalates to Flash with visible rounds")
        BookFixture.reset(); BookFixture.keepSearching = true; BookFixture.selectedID = "invalid"
        var rounds: [String] = []
        let unresolved = try await MediaSearch(api:api,intelligence:ai).matchSinglePlatform(mal[0],platform:.anilist,origin:mal[0]) { rounds.append($0) }
        check(unresolved == nil && BookFixture.identityPayloads.count == 6,"Book matching exhausts six rounds without accepting invented IDs")
        check(BookFixture.identityPayloads.last?.first?["finalReview"] == "true" && rounds.contains { $0.contains("第 6/6 轮") },"Last book round is an explicit final review")
        BookFixture.reset(); BookFixture.failWebSearch = true; BookFixture.emptyFirstSearch = true
        let afterTimeout = try await MediaSearch(api:api,intelligence:ai).matchSinglePlatform(mal[0],platform:.anilist,origin:mal[0])
        check(afterTimeout?.remoteID == "12" && BookFixture.webCalls == 1,"Web timeout continues with alias search and candidate judgment")
        check(BookFixture.identityPrompts.last?.contains("Apply this standard in every round") == true && BookFixture.identityPrompts.last?.contains("no explanation, analysis, citations or extra fields") == true,"Book requests use immediate decision and concise output instructions")
        BookFixture.reset(); BookFixture.needsEvidence = true; BookFixture.movie = true; BookFixture.selectedID = "anilist:movie:12"
        let movie = Work(source:.tmdb,remoteID:"900",kind:.movie,title:"同名作品")
        var movieStages: [String] = []
        let movieMatch = try await MediaSearch(api:api,intelligence:ai).matchSinglePlatform(movie,platform:.anilist,origin:movie) { movieStages.append($0) }
        check(movieMatch?.id == "anilist:movie:12" && BookFixture.identityPayloads.count == 2, "Movie candidates are rejudged after evidence even when no new aliases exist")
        check(BookFixture.webCalls == 1 && movieStages.contains { $0.contains("最终复核") && $0.contains("deepseek-flash") }, "Movie fallback preserves web research and Flash final adjudication")
        BookFixture.reset(); BookFixture.noEntry = true
        do {
            _ = try await search.matchSinglePlatform(mal[0],platform:.anilist,origin:mal[0],allowNoEntry:true)
            preconditionFailure("Explicit no-entry was not returned")
        } catch let error as NoMatchingEntry {
            check(!error.reason.isEmpty && BookFixture.identityPayloads.count == 1,"Explicit AI no-entry ends immediately with a reason")
        }
        BookFixture.reset(); BookFixture.keepSearching = true; BookFixture.selectedID = "invalid"
        do {
            _ = try await search.matchSinglePlatform(mal[0],platform:.anilist,origin:mal[0],allowNoEntry:true)
            preconditionFailure("Exhausted match silently succeeded")
        } catch is NoMatchingEntry { preconditionFailure("Round exhaustion became no-entry") }
        catch { check(BookFixture.identityPayloads.count == 6,"Unresolved matches retain all six rounds and fail without no-entry") }
        BookFixture.reset(); BookFixture.emptyFirstSearch = true
        let recoveredNoEntryAware = try await search.matchSinglePlatform(mal[0],platform:.anilist,origin:mal[0],allowNoEntry:true)
        check(recoveredNoEntryAware?.remoteID == "12","Empty search alone continues research rather than marking no-entry")
        for decidingRound in [1,2] {
            BookFixture.reset(); BookFixture.emptyPlatformSearch = true; BookFixture.noEntryAfterRound = decidingRound
            let koe = Work(source:.tmdb,remoteID:"koe",kind:.movie,title:"声之形",original:"聲の形")
            do {
                _ = try await search.matchSinglePlatform(koe,platform:.mal,origin:koe,allowNoEntry:true)
                preconditionFailure("Empty MAL search did not terminate")
            } catch is NoMatchingEntry {
                check(BookFixture.identityPayloads.count == decidingRound,"MAL empty searches can end in round \(decidingRound)")
            }
            let source = BookFixture.identityPayloads.last!.first!
            let history = try JSONSerialization.jsonObject(with:Data(source["searchHistory"]!.utf8)) as! [[String:String]]
            check(source["targetPlatform"] == "mal" && history.allSatisfy { $0["rawCount"] == "0" && $0["status"] == "success" },"AI sees successful empty searches, not missing evidence")
            check(history.contains { $0["query"] == "聲の形" } && history.contains { $0["round"] == String(decidingRound) },"AI receives actual original-title queries and accumulated rounds")
            check(BookFixture.identityPrompts.last!.contains("By round 2") && BookFixture.identityPrompts.last!.contains("NOT proof"),"Prompt permits early practical no-entry without site-wide proof")
        }
        BookFixture.reset(); BookFixture.noEntryAfterRound = 2; BookFixture.selectedID = "invalid"
        do {
            _ = try await search.matchSinglePlatform(mal[0],platform:.anilist,origin:mal[0],allowNoEntry:true)
            preconditionFailure("Unrelated hits did not terminate")
        } catch is NoMatchingEntry {
            check(BookFixture.identityPayloads.count == 2 && BookFixture.identityPayloads.last!.count > 1,"Nonempty unrelated candidates may end in round two without exhausting budget")
        }
        for failures in [["Bad"], ["Bad", "Native"]] {
            BookFixture.reset(); BookFixture.failedMALQueries = Set(failures); BookFixture.selectedID = "mal:manga:201"
            var source = bgm[0]; source.title = "Bad"; source.original = "Native"
            let recovered = try await search.matchSinglePlatform(source,platform:.mal,origin:source,allowNoEntry:true)
            check(recovered?.id == "mal:manga:201", "Whole-work MAL matching survives \(failures.count) failed initial queries")
            let encoded = BookFixture.identityPayloads.last!.first!["searchHistory"]!
            let history = try JSONSerialization.jsonObject(with:Data(encoded.utf8)) as! [[String:String]]
            check(history.contains { $0["status"] == "failed" && $0["rawCount"] == nil && $0["error"]?.contains("400") == true }, "Whole-work matching passes failed query evidence to AI")
            if failures.count == 2 { check(history.contains { $0["query"] == "Alias" && $0["status"] == "success" }, "Whole-work matching recovers through AI alias search after every initial query fails") }
        }
        BookFixture.reset(); BookFixture.failedMALQueries = ["Bad", "Native", "Alias"]; BookFixture.noEntry = true
        var failedSource = bgm[0]; failedSource.title = "Bad"; failedSource.original = "Native"
        do {
            _ = try await search.matchSinglePlatform(failedSource,platform:.mal,origin:failedSource,allowNoEntry:true)
            preconditionFailure("Failed MAL requests unexpectedly matched")
        } catch is NoMatchingEntry { preconditionFailure("Whole-work failures became no-entry") }
        catch { check(BookFixture.identityPayloads.count > 1 && error.localizedDescription.contains("400"), "Whole-work failed requests retain multiple research rounds and the actual error despite erroneous AI no-entry") }
        BookFixture.reset(); BookFixture.expandedMAL = true; BookFixture.needsEvidence = true
        var detailStages: [String] = []
        let lateCandidate = try await search.matchSinglePlatform(bgm[0],platform:.mal,origin:bgm[0]) { detailStages.append($0) }
        check(lateCandidate?.remoteID == "208", "Book research reaches candidates beyond the first four even when aliases are exhausted")
        check(BookFixture.detailIDs.count == 8 && Set(BookFixture.detailIDs).count == 8, "Missing book metadata does not repeatedly consume the detail budget for the same candidates")
        check(BookFixture.identityPayloads.count == 3, "Book detail evidence gets another judgment within the existing six-round budget")
        print("\(count) book matching checks passed.")
    }
}

final class BookFixture: URLProtocol, @unchecked Sendable {
    static var expandedMAL = false
    static var detailIDs: [String] = []
    static let detailLock = NSLock()
    static var identityPayloads: [[[String:String]]] = []
    static var selectedID = "anilist:manga:12"
    static var webCalls = 0
    static var failWebSearch = false
    static var identityPrompts: [String] = []
    static var emptyFirstSearch = false
    static var movie = false
    static var needsEvidence = false
    static var emptyPlatformSearch = false
    static var noEntryAfterRound = 0
    static var failedMALQueries = Set<String>()
    static var noEntry = false
    static var keepSearching = false
    static func reset() { expandedMAL = false; detailIDs = []; failedMALQueries = []; emptyPlatformSearch = false; noEntryAfterRound = 0; noEntry = false; movie = false; failWebSearch = false; identityPrompts = []; identityPayloads = []; selectedID = "anilist:manga:12"; webCalls = 0; emptyFirstSearch = false; needsEvidence = false; keepSearching = false }
    override class func canInit(with request:URLRequest) -> Bool { true }
    override class func canonicalRequest(for request:URLRequest) -> URLRequest { request }
    override func startLoading() {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating:0,count:4096)
            while stream.hasBytesAvailable { let size = stream.read(&buffer,maxLength:buffer.count); if size <= 0 { break }; data.append(buffer,count:size) }
        }
        let body = (try? JSONSerialization.jsonObject(with:data)) as? [String:Any] ?? [:]
        let url = request.url!
        var object: [String:Any] = [:]
        let term = URLComponents(url:url,resolvingAgainstBaseURL:false)?.queryItems?.first { $0.name == "q" }?.value ?? ""
        if url.host == "api.myanimelist.net", Self.failedMALQueries.contains(term) {
            client?.urlProtocol(self,didReceive:HTTPURLResponse(url:url,statusCode:400,httpVersion:nil,headerFields:nil)!,cacheStoragePolicy:.notAllowed)
            client?.urlProtocol(self,didLoad:Data("{\"error\":\"invalid q\"}".utf8)); client?.urlProtocolDidFinishLoading(self); return
        }
        func bgm(_ id:Int,_ platform:String?) -> [String:Any] {
            var row: [String:Any] = ["id":id,"name":"同名作品","type":1,"series":true,"volumes":10,"eps":50]
            row["platform"] = platform
            return row
        }
        func mal(_ id:Int,_ type:String) -> [String:Any] { ["id":id,"title":"同名作品","media_type":type,"num_volumes":10,"num_chapters":50] }
        if url.path == "/v0/search/subjects" {
            object = ["data":[bgm(101,"小说"),bgm(102,"漫画"),bgm(103,"画集"),bgm(104,nil)]]
        } else if url.path.hasPrefix("/v0/subjects/") {
            object = bgm(Int(url.lastPathComponent)!,"小说")
        } else if url.path == "/v2/anime", Self.emptyPlatformSearch {
            object = ["data":[]]
        } else if url.path == "/v2/manga" {
            object = ["data":(Self.expandedMAL ? (201...208).map { mal($0,"light_novel") } : [mal(201,"light_novel"),mal(202,"manga"),mal(203,"novel")]).map { ["node":$0] }]
        } else if url.path.hasPrefix("/v2/manga/") {
            Self.detailLock.lock(); Self.detailIDs.append(url.lastPathComponent); Self.detailLock.unlock()
            object = mal(Int(url.lastPathComponent)!,"light_novel")
        } else if url.host == "graphql.anilist.co" {
            let variables = body["variables"] as? [String:Any] ?? [:]
            let term = variables["search"] as? String ?? ""
            let rows: [[String:Any]] = [(11,"MANGA"),(12,"NOVEL")].map { ["id":$0.0,"title":["native":"同名作品"],"format":Self.movie ? "MOVIE" : $0.1,"volumes":10,"chapters":50] }
            object = ["data":["Page":["pageInfo":["hasNextPage":false],"media":Self.emptyFirstSearch && term != "Alias" ? [] : rows]]]
        } else if url.path == "/v1/tools/search" {
            Self.webCalls += 1
            if Self.failWebSearch { client?.urlProtocol(self,didFailWithError:URLError(.timedOut)); return }
            object = ["results":[["title":"Alias 同名作品","summary":"Alias 同名作品 novel","url":"https://example.com/book"]]]
        } else {
            let messages = body["messages"] as? [[String:Any]] ?? []
            let prompt = messages.first?["content"] as? String ?? ""
            var reply: [String:Any] = [:]
            if prompt.contains("Match first item") {
                Self.identityPrompts.append(prompt)
                let payload = messages.last?["content"] as? String ?? ""
                Self.identityPayloads.append((try? JSONSerialization.jsonObject(with:Data(payload.utf8))) as? [[String:String]] ?? [])
                if Self.expandedMAL {
                    Self.detailLock.lock(); let reached = Self.detailIDs.contains("208"); Self.detailLock.unlock()
                    reply = reached ? ["candidate_id":"mal:manga:208","certain":true] : ["candidate_id":NSNull(),"certain":false]
                }
                else if Self.noEntryAfterRound > 0 && Self.identityPayloads.count >= Self.noEntryAfterRound { reply = ["candidate_id":NSNull(),"certain":false,"noEntry":true,"noEntryReason":"合理标题搜索成功，当前搜索无可用对应项"] }
                else if Self.noEntryAfterRound > 0 { reply = ["candidate_id":NSNull(),"certain":false] }
                else if Self.noEntry { reply = ["candidate_id":NSNull(),"certain":false,"noEntry":true,"noEntryReason":"搜索结果均为不同原作，没有可能对应的作品"] }
                else if Self.needsEvidence && (Self.identityPayloads.last?.first?["researchEvidence"] ?? "").isEmpty {
                    reply = ["candidate_id":NSNull(),"certain":false]
                } else { reply = ["candidate_id":Self.selectedID,"certain":true] }
            } else if prompt.contains("NAME_SEARCH_PLAN") { reply = ["query":"Alias novel"] }
            else if prompt.contains("NAME_SEARCH_ANSWER") { reply = ["chinese_title":"同名作品","basis":"web","title_evidence":[0],"names":[["name":"Alias","evidence":0]]] }
            else { reply = ["queries":Self.needsEvidence ? [] : [Self.keepSearching ? "Alias \(Self.identityPayloads.count)" : "Alias"]] }
            object = ["choices":[["message":["content":String(decoding:try! JSONSerialization.data(withJSONObject:reply),as:UTF8.self)]]]]
        }
        client?.urlProtocol(self,didReceive:HTTPURLResponse(url:url,statusCode:200,httpVersion:nil,headerFields:nil)!,cacheStoragePolicy:.notAllowed)
        client?.urlProtocol(self,didLoad:try! JSONSerialization.data(withJSONObject:object))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
