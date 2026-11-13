import Foundation

@main struct SeasonMatchingChecks {
    @MainActor static func main() async throws {
        var count = 0
        func check(_ condition:Bool,_ title:String) { precondition(condition,title); count += 1; print("PASS: " + title) }
        func rejects(_ title:String,_ block:() throws -> Void) { do { try block(); preconditionFailure(title) } catch { check(true,title) } }
        let tmdb = Work(source:.tmdb,remoteID:"10",kind:.tv,title:"Series")
        let a = Work(source:.anilist,remoteID:"20",kind:.tv,title:"Series Part 1",episodeCount:2)
        let b = Work(source:.anilist,remoteID:"21",kind:.tv,title:"Series Part 2",episodeCount:2)
        var record = TrackingRecord(work:tmdb,score:7)
        record.links["tmdb"] = tmdb
        record.ensureSeason(0,title:""); record.ensureSeason(1,title:""); record.ensureSeason(2,title:"")
        for i in record.viewingUnits!.indices { record.viewingUnits![i].lastEpisode = 4 }
        let s1 = record.viewingUnits!.firstIndex { $0.season == 1 }!
        let s2 = record.viewingUnits!.firstIndex { $0.season == 2 }!
        record.viewingUnits![s1].score = 9
        var first = ContentMapping(tmdbID:"10",confirmed:true,seasons:[1],coverage:"partial",episodes:[
            EpisodeCorrespondence(platformEpisodes:[1],tmdbEpisodes:[EpisodeAddress(season:1,number:1)]),
            EpisodeCorrespondence(platformEpisodes:[2],tmdbEpisodes:[EpisodeAddress(season:1,number:2)])],platformEpisodeCount:2,complete:true)
        var second = first
        second.revision = UUID(); second.episodes = [EpisodeCorrespondence(platformEpisodes:[1],tmdbEpisodes:[EpisodeAddress(season:1,number:3)]),EpisodeCorrespondence(platformEpisodes:[2],tmdbEpisodes:[EpisodeAddress(season:1,number:4)])]
        var linkA = PlatformAssociation(target:a,scope:.season,season:1,mapping:first)
        let linkB = PlatformAssociation(target:b,scope:.season,season:1,mapping:second)
        check(try record.checkedRatingPayload(for:linkA).score == 9 && record.checkedRatingPayload(for:linkB).score == 9,"Split entries inherit the same canonical season rating")
        record.viewingUnits![s1].watched = [1,2,4]
        check(try record.mappedPayload(linkA).progress == 2 && record.mappedPayload(linkA).status == "已完成","A finished platform part completes before the canonical season")
        check(try record.mappedPayload(linkB).progress == 0,"Platform progress is a contiguous prefix, not a watched count")
        record.viewingUnits![s1].watched = [1,2,3,4]
        check(try record.mappedPayload(linkB).progress == 2,"Offset episodes project into the platform cursor")
        var merged = first; merged.episodes = [EpisodeCorrespondence(platformEpisodes:[1],tmdbEpisodes:[EpisodeAddress(season:1,number:1),EpisodeAddress(season:1,number:2)])]; merged.platformEpisodeCount = 1
        linkA.mapping = merged
        record.viewingUnits![s1].watched = [1]
        check(try record.mappedPayload(linkA).progress == 0,"Merged episode requires all canonical episodes")
        merged.episodes = [EpisodeCorrespondence(platformEpisodes:[1,2],tmdbEpisodes:[EpisodeAddress(season:1,number:1)])]; merged.platformEpisodeCount = 2
        linkA.mapping = merged
        check(try record.mappedPayload(linkA).progress == 2,"A canonical episode can project to complete platform subdivisions")
        var cross = first; cross.seasons = [1,2]; cross.episodes = []; cross.complete = false
        linkA.mapping = cross
        rejects("Different season ratings never get averaged") { _ = try record.checkedRatingPayload(for:linkA) }
        record.viewingUnits![s2].score = 9
        check(try record.checkedRatingPayload(for:linkA).score == 9,"Equal cross-season ratings can sync")
        cross.useOverallRating = true; linkA.mapping = cross
        check(try record.checkedRatingPayload(for:linkA).score == 7,"Explicit overall policy uses canonical overall rating")
        first.episodes = []; first.complete = false; linkA.mapping = first
        check(try record.checkedRatingPayload(for:linkA).score == 9,"Membership alone supports rating")
        rejects("Membership alone cannot sync a whole season cursor") { _ = try record.mappedPayload(linkA) }
        do { _ = try record.mappedPayload(linkA) }
        catch { check(error is ProgressSyncSkipped,"Zero correspondence produces a skip result rather than a sync error") }
        var sourceGapRecord = TrackingRecord(work:tmdb)
        sourceGapRecord.ensureSeason(1,title:"")
        sourceGapRecord.viewingUnits?[0].lastEpisode = 13
        for missing in [1,7,13] {
            let canonicalEpisodes = (1...13).filter { $0 != missing }
            let partialMap = ContentMapping(tmdbID:tmdb.remoteID,confirmed:true,seasons:[1],coverage:"partial",episodes:canonicalEpisodes.enumerated().map {
                EpisodeCorrespondence(platformEpisodes:[$0.offset+1],tmdbEpisodes:[EpisodeAddress(season:1,number:$0.element)])
            },platformEpisodeCount:12,complete:false)
            let partialLink = PlatformAssociation(target:a,scope:.season,season:1,mapping:partialMap)
            sourceGapRecord.viewingUnits?[0].markThrough(13)
            check(try sourceGapRecord.mappedPayload(partialLink).progress == 12,"13-to-12 partial mapping ignores unmatched canonical episode \(missing)")
            sourceGapRecord.viewingUnits?[0].markThrough(7)
            check(try sourceGapRecord.mappedPayload(partialLink).progress == canonicalEpisodes.filter({ $0 <= 7 }).count,"Partial progress projects only matched episodes before or at the local cursor")
        }
        var wrong = first; wrong.tmdbID = "999"; linkA.mapping = wrong
        rejects("Changed canonical identity blocks old ratings") { _ = try record.checkedRatingPayload(for:linkA) }
        var invalid = second; invalid.episodes.append(invalid.episodes[0])
        rejects("Duplicate episode correspondences are rejected") { try invalid.validate(seasonCounts:record.mappingSeasonCounts) }
        invalid = second; invalid.seasons = [99]
        rejects("Nonexistent seasons are rejected") { try invalid.validate(seasonCounts:record.mappingSeasonCounts) }
        invalid = second; invalid.platformEpisodeCount = 3
        rejects("Incomplete content cannot declare a complete mapping") { try invalid.validate(seasonCounts:record.mappingSeasonCounts) }
        record.addPlatformSelections([a,b,a])
        check(record.platformLinks?.count == 2,"Batch addition deduplicates platform IDs")
        record.prepareUnits()
        check(record.platformLinks!.allSatisfy { $0.scope == .unresolved && $0.mapping?.confirmed == false },"New unresolved links survive legacy migration")
        var noEntryRecord = record
        noEntryRecord.setNoEntry(.anilist); noEntryRecord.prepareUnits()
        check(noEntryRecord.platformLinks?.isEmpty == true && noEntryRecord.links["anilist"] == nil && !noEntryRecord.isPlatformEnabled(.anilist),"No-entry removes season associations and remains disabled after migration")
        check(noEntryRecord.score == record.score && noEntryRecord.viewingUnits?.first?.progress == record.viewingUnits?.first?.progress,"No-entry preserves ratings and season tracking")
        let restored = try JSONDecoder().decode(TrackingRecord.self,from:JSONEncoder().encode(record))
        check(restored.platformLinks?.first?.mapping?.version == 1,"Mapping version and unresolved state survive backup roundtrip")
        record.sourceRecords = [a.id:SourceProgress(work:a,score:8,progress:2,season:1,status:"已完成")]
        record.applyMatching([linkB],platform:.anilist,replace:true)
        check(!record.relatedWorkIDs.contains(a.id) && record.sourceRecords?[a.id]?.progress == 2,"Rematch removes historical source identity without deleting its archived progress")
        check(record.platformLinks?.map(\.id) == [b.id] && record.links["anilist"]?.id == b.id,"Replacement deletes absent old links and refreshes compatibility proxy")
        check(record.viewingUnits![s1].score == 9 && record.score == 7,"Replacement preserves personal scores")
        check(!Intelligence.publicEvidenceURL("http://127.0.0.1/x") && !Intelligence.publicEvidenceURL("http://foo.local/x") && !Intelligence.publicEvidenceURL("https://user:pw@example.com"),"Evidence reader rejects private addresses and credentials")

        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [SeasonFixture.self]
        let directory = FileManager.default.temporaryDirectory.appending(path:UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:directory) }
        let api = CatalogAPI(session:URLSession(configuration:config),credential:{ _ in "fixture" },diagnostics:DiagnosticLog(directory:directory))
        let ai = Intelligence(api:api,credential:{ _ in "fixture" })
        let catalog = MatchCatalog(work:tmdb,seasons:[MatchSeason(number:0,name:"Specials",date:"",count:1),MatchSeason(number:1,name:"Season 1",date:"2020",count:4)],evidence:MappingEvidence(id:"tmdb_seasons",title:"seasons",text:"S00=1,S01=4"))
        SeasonFixture.mode = "simple"; SeasonFixture.calls = 0; SeasonFixture.requests = []
        var simpleWork = a; simpleWork.title = "Series"; simpleWork.episodeCount = 4
        let simple = try await SeasonMatcher(api:api,ai:ai).match(catalog:catalog,platform:.anilist,existing:[],replace:false,selected:[simpleWork]) { _ in }
        check(simple.rounds == 1 && simple.associations.first?.scope == .whole && simple.associations.first?.mapping?.seasons == [1],"S00 plus S01 uses frozen whole association without specials")
        check(simple.complete && simple.associations.first?.mapping?.episodes.count == 4,"One-to-one season automatically enables episode progress")
        check(SeasonFixture.requests.count == 1 && SeasonFixture.requests[0].url?.host == "api.deepseek.com","Simple match needs only one default Flash request")
        check(simple.associations[0].mappingLabel(regularSeasons:[0,1]) == "整部作品", "Whole series label never appends a season")
        var imported = try LibraryIdentity.canonical(TrackingRecord(work:simpleWork,score:8,progress:2),using:tmdb)
        imported.prepareUnits()
        check(imported.platformLinks?.first?.mapping == nil && imported.platformLinks?.first?.legacy?.scopeConfirmed == false,"Imported source identity starts without confirmed episode membership")
        SeasonFixture.mode = "simple"; SeasonFixture.calls = 0; SeasonFixture.inputs = []
        let importedMatch = try await SeasonMatcher(api:api,ai:ai).match(catalog:catalog,platform:.anilist,existing:imported.platformLinks ?? [],replace:false) { _ in }
        check(importedMatch.complete && importedMatch.associations.first?.mapping?.matchedEpisodeCount == 4,"Automatic platform matching fills the existing imported entry without an explicit episode retry")
        check((SeasonFixture.inputs.first?["candidates"] as? [String])?.contains(simpleWork.id) == true,"Imported entry is supplied to the AI instead of excluded as locked")
        try imported.applyMatching(importedMatch,platform:.anilist,replace:false)
        check(imported.platformLinks?.first?.mapping?.complete == true && imported.sourceRecords?[simpleWork.id]?.progress == 2,"Imported episode mapping saves while preserving archived source progress")

        let importedFirst = try LibraryIdentity.canonical(TrackingRecord(work:a),using:tmdb)
        let importedSecond = try LibraryIdentity.canonical(TrackingRecord(work:b),using:tmdb)
        let importedParts = LibraryIdentity.mergeImport(importedSecond,existing:importedFirst)
        SeasonFixture.mode = "autoSplit"; SeasonFixture.calls = 0; SeasonFixture.inputs = []
        let importedSplit = try await SeasonMatcher(api:api,ai:ai).match(catalog:catalog,platform:.anilist,existing:importedParts.platformLinks ?? [],replace:false) { _ in }
        check(importedSplit.complete && importedSplit.associations.count == 2 && importedSplit.associations.allSatisfy { $0.mapping?.matchedEpisodeCount == 2 },"Automatic matching completes both imported parts of a merged TMDB season")
        check(importedSplit.associations.first(where:{ $0.id == b.id })?.mapping?.episodes.first?.tmdbEpisodes == [EpisodeAddress(season:1,number:3)],"Imported second part retains its episode offset")

        var confirmedLegacy = importedFirst.platformLinks!.first!
        confirmedLegacy.scope = .season; confirmedLegacy.legacy?.scopeConfirmed = true
        SeasonFixture.mode = "simple"; SeasonFixture.calls = 0
        let retainedLegacy = try await SeasonMatcher(api:api,ai:ai).match(catalog:catalog,platform:.anilist,existing:[confirmedLegacy],replace:false) { _ in }
        check(retainedLegacy.associations.isEmpty && SeasonFixture.calls == 0,"Automatic import repair preserves explicitly confirmed legacy scope")
        SeasonFixture.mode = "bangumiSearch"; SeasonFixture.calls = 0; SeasonFixture.requests = []; SeasonFixture.inputs = []
        let bangumiMatch = try await SeasonMatcher(api:api,ai:ai).match(catalog:catalog,platform:.bangumi,existing:[],replace:false) { _ in }
        check(bangumiMatch.rounds == 1 && bangumiMatch.complete && bangumiMatch.associations.first?.id == "bangumi:tv:20", "Bangumi search candidate with Chinese/Japanese aliases and numeric model ID matches in one round")
        check(!SeasonFixture.requests.contains { $0.url?.path == "/v1/tools/search" }, "Clear Bangumi match does not spend rounds searching for external citations")
        var retryLink = simple.associations[0]
        retryLink.mapping?.manual = true
        retryLink.mapping?.seasons = [2]; retryLink.season = 2
        let retryCatalog = MatchCatalog(work:tmdb,seasons:catalog.seasons + [MatchSeason(number:2,name:"Season 2",date:"2021",count:4)],evidence:catalog.evidence)
        SeasonFixture.mode = "simple"; SeasonFixture.calls = 0; SeasonFixture.inputs = []
        var retryProgress: [String] = []
        let retried = try await SeasonMatcher(api:api,ai:ai).match(catalog:retryCatalog,platform:.anilist,existing:[retryLink],replace:false,selected:[simpleWork],requireEpisodes:true,reconsiderSelected:true) { retryProgress.append($0) }
        check(retried.associations.first?.mapping?.seasons == [1] && retried.complete, "Explicit episode retry re-evaluates even a complete manually locked season")
        check(retryProgress.contains { $0.contains("1/6") }, "Per-item retry publishes the shared six-round progress")
        var retryRecord = record
        var protectedPeer = linkB; protectedPeer.mapping?.manual = true
        retryRecord.platformLinks = [retryLink,protectedPeer]
        try retryRecord.applyMatching(retried,platform:.anilist,replace:false,reconsideredIDs:[retryLink.id])
        check(retryRecord.platformLinks?.first(where: { $0.id == retryLink.id })?.mapping?.seasons == [1] && retryRecord.platformLinks?.first(where: { $0.id == protectedPeer.id })?.mapping == protectedPeer.mapping, "Retry saves corrected season and preserves the other manually locked association")
        let flashAI = Intelligence(api:api,credential:{ $0 == "deepseek.key" ? "fixture" : "" })
        SeasonFixture.requests = []
        _ = try await flashAI.matchingTurn(prompt:"JSON fixture",payload:"{}")
        let flashBody = try JSONSerialization.jsonObject(with:SeasonFixture.requests.last!.httpBody!) as! [String:Any]
        check(flashBody["model"] as? String == "deepseek-flash" && flashBody["service_tier"] == nil, "Flash matching requests use only DeepSeek fields")
        _ = try await ai.run(task:"Return JSON",payload:"{}")
        let genericBody = try JSONSerialization.jsonObject(with:SeasonFixture.requests.last!.httpBody!) as! [String:Any]
        check(genericBody["model"] as? String == Intelligence.model && SeasonFixture.requests.last?.url?.host == "api.deepseek.com", "General AI uses Flash even with both credentials configured")
        check(!Intelligence(api:api,credential:{ $0 == "openai.key" ? "fixture" : "" }).available, "An OpenAI-only credential no longer enables AI")
        var legacyLabel = simple.associations[0]
        check(legacyLabel.mappingLabel(regularSeasons:[1,2]) == "第 1 季", "Legacy whole scope covering one of multiple seasons displays only that season")
        legacyLabel.mapping?.seasons = [0]
        check(legacyLabel.mappingLabel(regularSeasons:[1,2]) == "特别篇", "S00 displays only specials")
        var standaloneOVA = a; standaloneOVA.format = "OVA"
        check(!SeasonMatcher.specialCandidate(standaloneOVA), "Standalone OVA format alone does not force a normal series into S00")
        standaloneOVA.overview = "第二季特别篇"
        check(SeasonMatcher.specialCandidate(standaloneOVA), "Season-related OVA synopsis activates the S00 rule")
        var normal = simpleWork
        normal.format = "TV"; normal.overview = "He believes he has special powers. Includes a bonus OVA and 特典."
        check(!SeasonMatcher.specialCandidate(normal), "Plot and release-note mentions do not turn a TV series into a special")
        let noisyDetail = MappingEvidence(id:"detail_" + normal.id,title:normal.title,text:#"{"synopsis":"A boy with special powers; Blu-ray includes 特典.","media_type":"tv"}"#)
        check(!SeasonMatcher.specialCandidate(normal,detail:noisyDetail), "Fetched synopsis cannot reclassify ordinary TV membership from incidental special words")
        for retry in [false,true] {
            SeasonFixture.mode = "simple"; SeasonFixture.calls = 0; SeasonFixture.inputs = []
            var manual = PlatformAssociation(target:normal,scope:.season,season:1,mapping:ContentMapping(tmdbID:"10",confirmed:true,seasons:[1],coverage:"full",manual:true))
            manual.mapping?.platformEpisodeCount = 4
            let result = try await SeasonMatcher(api:api,ai:ai).match(catalog:catalog,platform:.anilist,existing:retry ? [manual] : [],replace:false,selected:[normal],requireEpisodes:retry,reconsiderSelected:retry) { _ in }
            check(result.associations.first?.mapping?.matchedEpisodeCount == 4 && result.complete, "Ordinary TV with special in synopsis completes \(retry ? "manual retry" : "automatic match")")
        }
        let extraCatalog = MatchCatalog(work:tmdb,seasons:[MatchSeason(number:0,name:"Specials",date:"",count:14),MatchSeason(number:1,name:"Season 1",date:"",count:12)],evidence:catalog.evidence)
        let extraWork = Work(source:.bangumi,remoteID:"29648",kind:.tv,title:"中二病也要谈恋爱！",episodeCount:13)
        for mode in ["extraRepair","extraInvalid"] {
            SeasonFixture.mode = mode; SeasonFixture.calls = 0; SeasonFixture.inputs = []; SeasonFixture.requests = []
            let result = try await SeasonMatcher(api:api,ai:ai).match(catalog:extraCatalog,platform:.bangumi,existing:[],replace:false,selected:[extraWork]) { _ in }
            let map = result.associations.first?.mapping
            check(map?.matchedEpisodeCount == (mode == "extraRepair" ? 13 : 12), "Twelve valid regular episodes survive an invalid thirteenth: \(mode)")
            check(map?.complete == (mode == "extraRepair"), "Completion reflects the actual accepted episode count: \(mode)")
            let feedback = SeasonFixture.inputs.compactMap { ($0["validationFeedback"] as? [String:String])?[extraWork.id] }
            check(feedback.contains { $0.contains("S1E13") && $0.contains("12") }, "Next round receives the exact invalid coordinate and season bound")
            let membership = SeasonFixture.inputs.dropFirst(2).first?["confirmedMembership"] as? [[String:Any]]
            check((membership?.first?["mappedPlatformEpisodes"] as? [Int])?.count == 12, "Next round sees all twelve accepted episodes")
            if mode == "extraRepair" {
                check(map?.seasons == [0,1] && map?.episodes.last?.tmdbEpisodes == [EpisodeAddress(season:0,number:14)], "Extra maps to actual S00 after scope correction and table loading")
            }
            let failures = api.diagnostics.prepareExport().events.filter { $0.component == "season-episode-validation" }
            check(failures.contains { $0.message.contains("candidate=bangumi:tv:29648") && $0.message.contains("platformEpisodes=[13]") && $0.message.contains("S1E13") }, "Diagnostic export records candidate and rejected episode coordinates")
        }
        var special = a; special.title = "Series Season 2 OAD"; special.overview = "第二季特别篇"
        for mode in ["specialValid","specialWrong","specialBangumi"] {
            SeasonFixture.mode = mode; SeasonFixture.calls = 0; SeasonFixture.inputs = []
            let candidate = mode == "specialBangumi" ? Work(source:.bangumi,remoteID:"20",kind:.tv,title:special.title,overview:special.overview,episodeCount:2) : special
            let result = try await SeasonMatcher(api:api,ai:ai).match(catalog:catalog,platform:candidate.source,existing:[],replace:false,selected:[candidate]) { _ in }
            if mode != "specialWrong" {
                check(result.associations.first?.mapping?.seasons == [0] && result.associations.first?.mapping?.episodes.first?.tmdbEpisodes == [EpisodeAddress(season:0,number:1)], "Season-related OAD maps to actual S00 episode from the supplied first-turn evidence")
                check(result.rounds == 1 && result.associations.first?.scope == .season, "Special maps in one turn when episode evidence is sufficient")
            } else {
                check(result.rounds == 1 && result.associations.isEmpty && result.excludedIDs == [a.id], "Unidentifiable special is excluded rather than appended to regular episodes")
            }
            let evidence = SeasonFixture.inputs.first?["evidence"] as? [[String:Any]] ?? []
            check(evidence.contains { $0["id"] as? String == "tmdb_season_0" && ($0["text"] as? String ?? "").contains("Special episode synopsis") }, "Special's first turn receives actual S00 titles and synopsis")
        }
        var removedRecord = record; removedRecord.platformLinks = [linkB]; removedRecord.links["anilist"] = b
        let excludedResult = SeasonMatchResult(associations:[],notes:[],rounds:6,complete:false,excludedIDs:[b.id])
        try removedRecord.applyMatching(excludedResult,platform:.anilist,replace:false)
        removedRecord.prepareUnits()
        check(!removedRecord.relatedWorkIDs.contains(b.id) && removedRecord.links["anilist"] == nil, "Explicit exclusion removes stale auto associations without legacy resurrection")
        var protectedRecord = record; var manualLink = linkB; manualLink.mapping?.manual = true; protectedRecord.platformLinks = [manualLink]
        try protectedRecord.applyMatching(excludedResult,platform:.anilist,replace:false)
        check(protectedRecord.platformLinks?.contains { $0.id == b.id } == true, "Exclusions preserve manual locks during ordinary matching")
        SeasonFixture.mode = "research"; SeasonFixture.calls = 0; SeasonFixture.requests = []
        let researched = try await SeasonMatcher(api:api,ai:ai).match(catalog:catalog,platform:.anilist,existing:[],replace:false,selected:[a]) { _ in }
        check(researched.rounds == 2 && researched.associations.first?.mapping?.episodes.count == 2,"Agent obtains targeted details then validates episode mappings")
        check(SeasonFixture.requests.filter { $0.url?.path == "/v1/tools/search" }.count == 1,"Research uses a concrete web query only after first-round ambiguity")
        for mode in ["earlyExcluded", "silentUnresolved"] {
            SeasonFixture.mode = mode; SeasonFixture.calls = 0; SeasonFixture.requests = []; SeasonFixture.inputs = []
            let recovered = try await SeasonMatcher(api:api,ai:ai).match(catalog:catalog,platform:.anilist,existing:[],replace:false,selected:[simpleWork]) { _ in }
            check(recovered.rounds > 1 && recovered.rounds <= 6 && recovered.associations.count == 1, "Ordinary first-turn rejection or silence continues to a successful final adjudication")
            check(SeasonFixture.requests.contains { $0.url?.path == "/v1/tools/search" }, "Missing model research still receives a bounded evidence search")
            check(SeasonFixture.inputs.last?["final"] as? Bool == true && SeasonFixture.requests.last?.url?.host == "api.deepseek.com", "Stalled evidence reaches explicit Flash final review")
        }
        let husband1 = Work(source:.bangumi,remoteID:"105426",kind:.tv,title:"关于完全听不懂老公在说什么的事",original:"旦那が何を言っているかわからない件",year:"2014",episodeCount:13)
        let husband2 = Work(source:.bangumi,remoteID:"121108",kind:.tv,title:"关于完全听不懂老公在说什么的事 第二季",original:"旦那が何を言っているかわからない件 2スレ目",year:"2015",episodeCount:13)
        let husbandCatalog = MatchCatalog(work:tmdb,seasons:[MatchSeason(number:1,name:"Season 1",date:"2014-10-02",count:13),MatchSeason(number:2,name:"Season 2",date:"2015-04-02",count:13)],evidence:catalog.evidence)
        let noisyCandidates = [husband1,husband2] + (0..<53).map { Work(source:.bangumi,remoteID:String(172450+$0),kind:.tv,title:"无关搜索结果 \($0)",episodeCount:12) }
        SeasonFixture.mode = "noisyBangumi"; SeasonFixture.calls = 0; SeasonFixture.inputs = []; SeasonFixture.requests = []
        let noisy = try await SeasonMatcher(api:api,ai:ai).match(catalog:husbandCatalog,platform:.bangumi,existing:[],replace:false,selected:noisyCandidates) { _ in }
        check(Set(noisy.associations.map(\.id)) == Set([husband1.id,husband2.id]) && noisy.associations.allSatisfy { $0.mapping?.complete == true }, "Two real Bangumi seasons survive 53 unrelated search candidates and a malformed rejection")
        check(SeasonFixture.inputs.dropFirst().first?["phase"] as? String == "mixed", "Known seasons receive episode processing while unrelated memberships remain unresolved")
        check(noisy.rounds <= 6 && noisy.notes.contains { $0.contains("evidenceIDs") }, "Malformed candidate is reported without discarding valid neighboring decisions or exceeding six turns")
        SeasonFixture.mode = "decisiveBangumi"; SeasonFixture.calls = 0; SeasonFixture.inputs = []; SeasonFixture.requests = []
        let screeningCandidates = noisyCandidates + (0..<59).map { Work(source:.bangumi,remoteID:String(900000+$0),kind:.tv,title:"无关作品 \($0)",episodeCount:12) }
        let decisive = try await SeasonMatcher(api:api,ai:ai).match(catalog:husbandCatalog,platform:.bangumi,existing:[],replace:false,selected:screeningCandidates) { _ in }
        check(decisive.rounds == 1 && decisive.complete && decisive.associations.count == 2 && decisive.associations.allSatisfy { $0.mapping?.complete == true }, "Bangumi confirms two clear seasons among 114 candidates in one turn")
        check(decisive.excludedIDs.count == 112, "Explicit unrelated metadata decisions cover candidates outside the current batch")
        check(!SeasonFixture.requests.contains { $0.url?.host == "api.bgm.tv" || $0.url?.path == "/v1/tools/search" }, "Unrelated Bangumi hits cause no detail reads or web searches")
        var noisyRecord = record
        try noisyRecord.applyMatching(noisy,platform:.bangumi,replace:false)
        check(noisyRecord.platformLinks?.filter { $0.target.source == .bangumi }.count == 2, "Valid Bangumi associations persist even when unrelated candidates remain undecided")
        SeasonFixture.mode = "limit"; SeasonFixture.calls = 0; SeasonFixture.requests = []; SeasonFixture.inputs = []
        let limited = try await SeasonMatcher(api:api,ai:ai).match(catalog:catalog,platform:.anilist,existing:[],replace:true,selected:[a],requireEpisodes:true) { _ in }
        check(limited.rounds > 4 && limited.rounds <= SeasonMatcher.maximumRounds && limited.complete && limited.associations.isEmpty && limited.excludedIDs == [a.id],"Six-round research ends with an explicit exclusion")
        check(SeasonFixture.requests.contains { $0.url?.host == "api.deepseek.com" },"Difficult evidence upgrades to Flash")
        check(SeasonFixture.inputs.last?["final"] as? Bool == true && SeasonFixture.requests.last?.url?.host == "api.deepseek.com", "Final round is explicitly marked and sent to Flash")
        let flashBodies = SeasonFixture.requests.filter { $0.url?.path == "/chat/completions" }.compactMap { request -> [String:Any]? in
            guard let data = request.httpBody else { return nil }
            return (try? JSONSerialization.jsonObject(with:data)) as? [String:Any]
        }
        check(!flashBodies.isEmpty && flashBodies.allSatisfy { $0["model"] as? String == "deepseek-flash" && $0["reasoning_effort"] == nil },"All model requests use Flash without OpenAI parameters")
        let excludedOnly: [String:Any] = ["results":[["candidateID":a.id,"decision":"excluded","evidenceIDs":["basic_"+a.id],"reason":"不同作品"]]]
        check(try SeasonMatcher.decodeTurn(excludedOnly,confirmed:[:]).results.first?.seasons.isEmpty == true,"Excluded candidates do not need fabricated season coordinates")
        let beforeFailure = record.platformLinks?.map(\.id)
        try record.applyMatching(SeasonMatchResult(associations:[],notes:[],rounds:1,complete:false),platform:.anilist,replace:true)
        check(record.platformLinks?.map(\.id) == beforeFailure,"Failed rematch keeps its original relation set")
        SeasonFixture.mode = "invalid"; SeasonFixture.calls = 0
        let rejected = try await SeasonMatcher(api:api,ai:ai).match(catalog:catalog,platform:.anilist,existing:[],replace:true,selected:[a]) { _ in }
        check(rejected.associations.isEmpty,"Invented season ID cannot be persisted")
        SeasonFixture.mode = "simple"; SeasonFixture.calls = 0
        var manual = linkB; manual.mapping?.manual = true
        let protected = try await SeasonMatcher(api:api,ai:ai).match(catalog:catalog,platform:.anilist,existing:[manual],replace:false,selected:[b]) { _ in }
        check(protected.rounds == 0 && SeasonFixture.calls == 0,"Normal matching preserves manual mappings")
        SeasonFixture.calls = 0
        let canceled = Task { try await SeasonMatcher(api:api,ai:ai).match(catalog:catalog,platform:.anilist,existing:[],replace:true,selected:[a]) { _ in } }
        canceled.cancel()
        do { _ = try await canceled.value; preconditionFailure("Cancellation ignored") }
        catch is CancellationError { check(SeasonFixture.calls == 0,"Canceled matching never calls a model or saves relationships") }
        SeasonFixture.mode = "malformed"; SeasonFixture.calls = 0
        let malformed = try await SeasonMatcher(api:api,ai:ai).match(catalog:catalog,platform:.anilist,existing:[],replace:true,selected:[a]) { _ in }
        check(malformed.rounds == 3 && !malformed.complete,"Invalid JSON receives two bounded repair attempts")
        SeasonFixture.mode = "autoSplit"; SeasonFixture.calls = 0
        let membershipOnly = try await SeasonMatcher(api:api,ai:ai).match(catalog:catalog,platform:.anilist,existing:[],replace:false,selected:[a,b]) { _ in }
        check(membershipOnly.rounds == 2 && membershipOnly.associations.count == 2 && membershipOnly.complete,"Ordinary matching automatically completes split-season episodes")
        SeasonFixture.mode = "autoSplit"; SeasonFixture.calls = 0; SeasonFixture.requests = []
        let splitResult = try await SeasonMatcher(api:api,ai:ai).match(catalog:catalog,platform:.anilist,existing:[],replace:false,selected:[a,b],requireEpisodes:true) { _ in }
        check(splitResult.complete && splitResult.associations.count == 2 && splitResult.rounds == 2,"Many-to-one automatically loads episode evidence without model research")
        check(splitResult.associations.last?.mapping?.episodes.last?.tmdbEpisodes.first?.number == 4,"Second split part receives its canonical offset")
        SeasonFixture.mode = "correctMembership"; SeasonFixture.calls = 0; SeasonFixture.inputs = []; SeasonFixture.requests = []
        let correctionCatalog = MatchCatalog(work:tmdb,seasons:catalog.seasons + [MatchSeason(number:2,name:"S2",date:"",count:4)],evidence:catalog.evidence)
        let corrected = try await SeasonMatcher(api:api,ai:ai).match(catalog:correctionCatalog,platform:.anilist,existing:[],replace:false,selected:[a,b]) { _ in }
        check(corrected.complete && corrected.associations.count == 2 && corrected.associations.allSatisfy { $0.mapping?.seasons == [1] && $0.mapping?.coverage == "partial" }, "New episode evidence corrects automatic season and coverage for both split parts")
        check(corrected.associations.last?.mapping?.episodes.last?.tmdbEpisodes.first?.number == 4, "Corrected second part preserves canonical offset")
        let memberships = SeasonFixture.inputs.dropFirst().first?["confirmedMembership"] as? [[String:Any]] ?? []
        check(memberships.count == 2 && memberships.allSatisfy { $0["manualLocked"] as? Bool == false }, "Automatic membership is explicitly distinct from manual locks")
        let crossCatalog = MatchCatalog(work:tmdb,seasons:[MatchSeason(number:1,name:"S1",date:"",count:2),MatchSeason(number:2,name:"S2",date:"",count:2)],evidence:catalog.evidence)
        SeasonFixture.mode = "autoMerge"; SeasonFixture.calls = 0
        let mergeResult = try await SeasonMatcher(api:api,ai:ai).match(catalog:crossCatalog,platform:.anilist,existing:[],replace:false,selected:[simpleWork]) { _ in }
        check(mergeResult.complete && mergeResult.associations.first?.mapping?.episodes.last?.tmdbEpisodes.first?.season == 2,"One-to-many automatically resolves the cross-season boundary")
        SeasonFixture.mode = "partial"; SeasonFixture.calls = 0
        let partialResult = try await SeasonMatcher(api:api,ai:ai).match(catalog:catalog,platform:.anilist,existing:[],replace:false,selected:[a],requireEpisodes:true) { _ in }
        check(partialResult.complete && partialResult.rounds == 3 && partialResult.associations.first?.mapping?.episodes.count == 2,"Partial episode results accumulate and continue without research requests")
        SeasonFixture.mode = "badEpisodes"; SeasonFixture.calls = 0
        let badEpisodes = try await SeasonMatcher(api:api,ai:ai).match(catalog:catalog,platform:.anilist,existing:[],replace:false,selected:[a],requireEpisodes:true) { _ in }
        check(badEpisodes.associations.count == 1 && badEpisodes.excludedIDs.isEmpty && !badEpisodes.complete && badEpisodes.notes.contains { $0.contains("集") },"Final invalid numbering preserves confirmed membership and reports the episode failure")
        SeasonFixture.mode = "longTable"; SeasonFixture.calls = 0
        let longTable = try await SeasonMatcher(api:api,ai:ai).match(catalog:catalog,platform:.anilist,existing:[],replace:false,selected:[a],requireEpisodes:true) { _ in }
        check(longTable.complete && (longTable.associations.first?.mapping?.evidence.first { $0.id == "tmdb_season_1" }?.text.count ?? 0) > 30000,"Long structured episode tables remain valid JSON during validation")
        var manualScope = PlatformAssociation(target:a,scope:.season,season:1,mapping:ContentMapping(tmdbID:"10",confirmed:true,seasons:[1],coverage:"partial",platformEpisodeCount:2,manual:true))
        SeasonFixture.mode = "manualScope"; SeasonFixture.calls = 0
        let filledManual = try await SeasonMatcher(api:api,ai:ai).match(catalog:catalog,platform:.anilist,existing:[manualScope],replace:false,selected:[a],requireEpisodes:true) { _ in }
        check(filledManual.complete && filledManual.associations.first?.mapping?.manual == true,"AI can fill episodes under a locked manual season")
        var manualRecord = record; manualRecord.platformLinks = [manualScope]
        manualRecord.applyMatching(filledManual.associations,platform:.anilist,replace:false)
        check(manualRecord.platformLinks?.first?.mapping?.complete == true,"Saving AI episode completion preserves the manual season lock")
        manualScope.mapping?.coverage = "full"; manualScope.mapping?.platformEpisodeCount = 4
        check(SeasonMatcher.defaultEpisodes(manualScope.mapping!,peers:[manualScope,linkB],counts:catalog.counts) == nil,"Existing same-platform association prevents a false one-to-one default")
        SeasonFixture.mode = "simple"; SeasonFixture.calls = 0
        var oldManual = manualScope; oldManual.mapping?.seasons = [2]
        let rematchedManual = try await SeasonMatcher(api:api,ai:ai).match(catalog:catalog,platform:.anilist,existing:[oldManual],replace:true,selected:[simpleWork]) { _ in }
        check(rematchedManual.complete && rematchedManual.associations.first?.mapping?.seasons == [1] && rematchedManual.associations.first?.mapping?.manual == false,"Explicit rematch releases old manual season constraints")
        SeasonFixture.mode = "badSchema"; SeasonFixture.calls = 0
        let badSchema = try await SeasonMatcher(api:api,ai:ai).match(catalog:catalog,platform:.anilist,existing:[],replace:false,selected:[a]) { _ in }
        check(!badSchema.complete && badSchema.notes.contains { $0.contains("reason") },"Schema repair identifies the exact missing field")
        for mode in ["searchEmpty","searchExcluded"] {
            SeasonFixture.mode = mode; SeasonFixture.calls = 0; SeasonFixture.requests = []
            let expanded = try await SeasonMatcher(api:api,ai:ai).match(catalog:catalog,platform:.anilist,existing:[],replace:false) { _ in }
            check(expanded.complete && expanded.associations.count == 1,"\(mode): automatic season matching recovers with researched aliases")
            check(SeasonFixture.requests.contains { $0.url?.path == "/v1/tools/search" },"\(mode): season fallback performs real web-tool research")
        }
        SeasonFixture.mode = "longPartial"; SeasonFixture.calls = 0
        var longWork = a; longWork.episodeCount = 6
        let longCatalog = MatchCatalog(work:tmdb,seasons:[MatchSeason(number:1,name:"S1",date:"",count:12)],evidence:catalog.evidence)
        let longResult = try await SeasonMatcher(api:api,ai:ai).match(catalog:longCatalog,platform:.anilist,existing:[],replace:false,selected:[longWork],requireEpisodes:true) { _ in }
        check(longResult.complete && longResult.rounds == 6 && longResult.associations.first?.mapping?.episodes.count == 6,"Complex mapping keeps validated progress and completes beyond round four")
        var stateMessages: [String] = []
        let status = MatchingStatus { stateMessages.append($0) }
        status.report("AniList · deepseek-flash · 第 4/6 轮")
        status.finish("已确认关联 2 项；集对应待补全")
        status.tick(); status.report("late running callback")
        check(stateMessages.last == "已确认关联 2 项；集对应待补全" && stateMessages.count == 2,"Finished status cannot be overwritten by a late heartbeat or callback")
        check(limited.models == ["deepseek-flash"] && !limited.stopReason.isEmpty,"Final result records Flash use and a stop reason")
        let minimalEpisode: [String:Any] = ["results":[["candidateID":a.id,"decision":"matched","episodes":[],"evidenceIDs":["basic_"+a.id],"reason":"补集"]]]
        let filled = try SeasonMatcher.decodeTurn(minimalEpisode,confirmed:[a.id:manualScope])
        check(filled.results.first?.scope == manualScope.scope.rawValue && filled.results.first?.seasons == [1],"Episode responses inherit omitted locked scope fields without losing the whole round")
        var redundantScope = minimalEpisode
        var redundantRows = redundantScope["results"] as! [[String:Any]]
        redundantRows[0]["scope"] = NSNull(); redundantRows[0]["seasons"] = [999]
        redundantScope["results"] = redundantRows
        let lockedScope = try SeasonMatcher.decodeTurn(redundantScope,confirmed:[a.id:manualScope])
        check(lockedScope.results.first?.scope == manualScope.scope.rawValue && lockedScope.results.first?.seasons == [1],"Redundant malformed episode membership fields cannot change the confirmed season or discard the result")
        var partialAssociation = manualScope; partialAssociation.mapping?.manual = false; partialAssociation.mapping?.episodes = []; partialAssociation.mapping?.complete = false
        let partialMembership = SeasonMatchResult(associations:[partialAssociation],notes:[],rounds:5,complete:false,membershipComplete:true,models:["deepseek-flash"],stopReason:"暂无可用新证据")
        var partialRecord = record; partialRecord.platformLinks = [linkB]
        try partialRecord.applyMatching(partialMembership,platform:.anilist,replace:true)
        check(partialRecord.platformLinks?.map(\.id) == [a.id] && partialRecord.platformLinks?.first?.mapping?.confirmed == true,"Confirmed season associations save during rematch even while episode mapping remains pending")
        var incompleteMembership = partialMembership; incompleteMembership.membershipComplete = false
        var mergeRecord = record; mergeRecord.platformLinks = [linkB]
        try mergeRecord.applyMatching(incompleteMembership,platform:.anilist,replace:true)
        check(Set(mergeRecord.platformLinks?.map(\.id) ?? []) == Set([a.id,b.id]),"Partially resolved rematch merges confirmed results without removing unresolved old links")
        let stagedDirectory = directory.appending(path:"platform-commits")
        let stagedStore = TrackingStore(directory:stagedDirectory,api:api,intelligence:ai)
        stagedStore.saveAssociations(partialRecord)
        check(stagedStore.message == nil,"First platform association saves immediately")
        var later = partialRecord
        try later.applyMatching(limited,platform:.mal,replace:true)
        stagedStore.saveAssociations(later)
        let reopened = TrackingStore(directory:stagedDirectory,api:api,intelligence:ai)
        check(reopened.record(tmdb).platformLinks?.contains(where: { $0.id == a.id }) == true,"Later unresolved platform leaves the earlier platform association on disk")
        // Persistence is transactional and drops old pending jobs after mapping revision changes.
        let store = TrackingStore(directory:directory.appending(path:"store"),api:api,intelligence:ai)
        record.platformLinks = [linkB]; try store.admit(record,using:tmdb)
        check(store.libraryRecord(for:a) == nil,"Removed imported source no longer resolves to the canonical library record")
        let oldJob = Delivery(record:store.record(tmdb),target:b,associationID:b.id,fields:[.progress,.status])
        store.backup.deliveries.append(oldJob)
        store.backup.associations = [a.id:AssociationState(links:["tmdb":tmdb],confirmedProgress:[])]
        var changed = store.record(tmdb); changed.platformLinks![0].mapping?.revision = UUID()
        store.saveAssociations(changed)
        check(store.record(a).links["tmdb"] == nil,"Rematch also clears pre-import identity cache for removed entries")
        check(!store.backup.deliveries.contains(where:{ $0.id == oldJob.id }),"New mapping revision invalidates stale pending progress deliveries")
        check(store.message == nil && store.record(tmdb).viewingUnits?.first(where:{ $0.season == 1 })?.score == 9,"Association save preserves canonical rating")
        let badDirectory = directory.appending(path:"not-directory")
        try Data("x".utf8).write(to:badDirectory)
        let badStore = TrackingStore(directory:badDirectory,api:api,intelligence:ai)
        badStore.saveAssociations(record)
        check(badStore.message != nil && badStore.record(tmdb).platformLinks?.contains(where:{ $0.mapping != nil }) != true,"Failed disk save rolls back in-memory association transaction")
        for mode in ["malPartial", "malAlias", "malPageFailure"] {
            SeasonFixture.mode = mode; SeasonFixture.calls = 0; SeasonFixture.requests = []; SeasonFixture.inputs = []
            var work = tmdb; work.title = "竞女"; work.original = "Keijo!!!!!!!!"
            var malCatalog = catalog; malCatalog.work = work
            let recovered = try await SeasonMatcher(api:api,ai:ai).match(catalog:malCatalog,platform:.mal,existing:[],replace:false) { _ in }
            check(recovered.complete && recovered.associations.first?.id == "mal:tv:20", "MAL \(mode) continues after HTTP 400 and saves a valid season match")
            let history = SeasonFixture.inputs.last?["searchHistory"] as? [[String:String]] ?? []
            check(history.contains { $0["status"] == "failed" && $0["error"]?.contains("400") == true && $0["rawCount"] == nil }, "Failed MAL queries are reported as failures, never zero hits")
            check(history.contains { $0["status"] == "success" && $0["rawCount"] == "1" }, "Successful MAL titles survive another title or page failure")
            if mode == "malAlias" {
                check(SeasonFixture.requests.contains { $0.url?.query?.contains("q=Alternative") == true }, "All initial MAL requests failing still reaches AI alias search")
            }
        }
        SeasonFixture.mode = "malFailed"; SeasonFixture.calls = 0; SeasonFixture.requests = []; SeasonFixture.inputs = []
        do {
            _ = try await SeasonMatcher(api:api,ai:ai).match(catalog:catalog,platform:.mal,existing:[],replace:false) { _ in }
            preconditionFailure("Failed requests unexpectedly matched")
        } catch is NoMatchingEntry { preconditionFailure("Failed requests became no-entry") }
        catch { check(SeasonFixture.requests.contains { $0.url?.query?.contains("q=Alternative") == true } && error.localizedDescription.contains("400"), "All failed MAL searches attempt aliases and retain the actual failure without marking no-entry") }
        SeasonFixture.mode = "noEntry"; SeasonFixture.calls = 0
        do {
            _ = try await SeasonMatcher(api:api,ai:ai).match(catalog:catalog,platform:.anilist,existing:[],replace:false) { _ in }
            preconditionFailure("Explicit seasonal no-entry was ignored")
        } catch let error as NoMatchingEntry {
            check(!error.reason.isEmpty && SeasonFixture.calls == 1,"Explicit platform-wide season no-entry terminates in the deciding round")
        }
        print("\(count) season matching checks passed.")
    }
}
final class SeasonFixture: URLProtocol, @unchecked Sendable {
    static var mode = "simple", calls = 0
    static var requests: [URLRequest] = []
    static var inputs: [[String:Any]] = []
    override class func canInit(with request:URLRequest) -> Bool { true }
    override class func canonicalRequest(for request:URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.append(request)
        let url = request.url!
        var root: [String:Any] = [:]
        var status = 200
        var bodyData = request.httpBody ?? Data()
        if bodyData.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }; var buffer = [UInt8](repeating:0,count:4096)
            while stream.hasBytesAvailable { let n = stream.read(&buffer,maxLength:buffer.count); if n <= 0 { break }; bodyData.append(buffer,count:n) }
        }
        var captured = request; captured.httpBody = bodyData
        Self.requests[Self.requests.count-1] = captured
        let body = (try? JSONSerialization.jsonObject(with:bodyData)) as? [String:Any] ?? [:]
        if url.host == "api.myanimelist.net" {
            let query = URLComponents(url:url,resolvingAgainstBaseURL:false)?.queryItems?.first { $0.name == "q" }?.value ?? ""
            let offset = URLComponents(url:url,resolvingAgainstBaseURL:false)?.queryItems?.first { $0.name == "offset" }?.value ?? "0"
            let failed = Self.mode == "malFailed" || (Self.mode == "malAlias" && query != "Alternative") || (Self.mode == "malPartial" && query == "竞女") || (Self.mode == "malPageFailure" && offset != "0")
            if failed { status = 400; root = ["error":"invalid q"] }
            else { root = ["data":[["node":["id":20,"title":"Keijo!!!!!!!!","num_episodes":4,"media_type":"tv"]]]] }
        } else if url.host == "api.bgm.tv" {
            if ["noisyBangumi", "decisiveBangumi", "extraRepair", "extraInvalid"].contains(Self.mode) {
                if url.path.contains("subjects") { root = ["id":Int(url.lastPathComponent) ?? 0,"name":"TV series","eps":13] }
                else { root = ["total":13,"data":(1...13).map { ["sort":$0,"name":"Episode \($0)"] as [String:Any] }] }
            } else if Self.mode == "bangumiSearch" {
                root = ["data":[["id":20,"name":"シリーズ","name_cn":"Series","summary":"Same adaptation","eps":4,"date":"2020-01-01"]]]
            } else if url.path.contains("subjects") { root = ["id":20,"name":"Series OAD","summary":"第二季特别篇","eps":2] }
            else { root = ["total":2,"data":[["sort":1,"name":"Bonus first half","desc":"First half"],["sort":2,"name":"Bonus second half","desc":"Second half"]]] }
        } else if url.host == "graphql.anilist.co" {
            let id = (body["variables"] as? [String:Any])?["id"] as? Int ?? 20
            root = ["data":["Media":["id":id,"episodes":["autoMerge", "earlyExcluded", "silentUnresolved", "searchEmpty", "searchExcluded"].contains(Self.mode) ? 4 : Self.mode == "longPartial" ? 6 : 2,"title":["native":"Series"],"description":"First two episodes"]]]
            if ["searchEmpty","searchExcluded","noEntry"].contains(Self.mode), let query = (body["variables"] as? [String:Any])?["search"] as? String {
                let isAlias = query == "Alternative"
                let media: [[String:Any]] = Self.mode == "searchEmpty" && !isAlias ? [] : [["id":Self.mode == "searchExcluded" && isAlias ? 21 : 20,"title":["native":"Series"],"type":"ANIME","format":"TV","episodes":4]]
                root = ["data":["Page":["pageInfo":["hasNextPage":false],"media":media]]]
            }
        } else if url.path.contains("/season/") {
            root = ["season_number":Int(url.lastPathComponent) ?? 1,"episodes":(1...(Self.mode.hasPrefix("extra") ? (url.lastPathComponent == "0" ? 14 : 12) : Self.mode == "noisyBangumi" ? 13 : Self.mode == "longPartial" ? 12 : 4)).map { ["episode_number":$0,"name":Self.mode == "longTable" ? String(repeating:"e",count:10000) : "Episode \($0)","overview":"Special episode synopsis"] as [String:Any] }]
        } else if url.path == "/v1/tools/search" {
            root = ["results":[["url":"https://example.com/\(Self.calls)","title":"Episode table","content":"Platform Part 1 episodes 1 and 2 equal TMDB S01E01 and E02. Evidence version \(Self.calls)"]]]
        } else {
            Self.calls += 1
            let unresolved = Self.mode == "limit" || (Self.mode == "research" && Self.calls == 1)
            let episodeRows: [[String:Any]] = Self.mode == "research" && Self.calls > 1 ? (1...2).map { ["platformEpisodes":[$0],"tmdbEpisodes":[["season":1,"number":$0]],"evidenceIDs":["detail_anilist:tv:20","tmdb_season_1"]] } : []
            let decision: [String:Any] = ["candidateID":"anilist:tv:20","decision":unresolved ? "unresolved" : "matched","scope":"whole","seasons":[Self.mode == "invalid" ? 99 : 1],"coverage":"full","complete":!episodeRows.isEmpty,"episodes":episodeRows,"evidenceIDs":["basic_anilist:tv:20","tmdb_seasons"],"reason":"Test evidence"]
            let research: [[String:Any]] = unresolved ? [["candidateIDs":["anilist:tv:20"],"question":"Which episodes?","queries":["Series episode mapping \(Self.calls)"],"platformQueries":[],"detailIDs":["anilist:tv:20"],"seasons":[1],"readEvidenceIDs":[],"visualEvidenceIDs":[]]] : []
            let answer: [String:Any] = ["results":[decision],"research":research,"difficult":Self.mode == "limit"]
            var output = answer
            let payloadText = (body["messages"] as? [[String:Any]])?.last?["content"] as? String ?? "{}"
            let payload = (try? JSONSerialization.jsonObject(with:Data(payloadText.utf8))) as? [String:Any] ?? [:]
            if payload["phase"] as? String != "identity-screening" { Self.inputs.append(payload) }
            if Self.mode.hasPrefix("extra") {
                let id = "bangumi:tv:29648"
                let repaired = Self.mode == "extraRepair" && Self.calls >= 3
                var item: [String:Any] = ["candidateID":id,"decision":"matched","scope":repaired ? "whole" : "season","seasons":repaired ? [0,1] : [1],"coverage":"partial","evidenceIDs":["basic_"+id],"reason":"Regular season plus Extra"]
                if Self.calls > 1 {
                    // Deliberately repeat prior valid coordinates with changed citations.
                    item["episodes"] = (1...13).map { n -> [String:Any] in
                        let season = repaired && n == 13 ? 0 : 1
                        let number = repaired && n == 13 ? 14 : n
                        return ["platformEpisodes":[n],"tmdbEpisodes":[["season":season,"number":number]],"evidenceIDs":["detail_"+id,"tmdb_season_\(season)"] + (Self.calls >= 3 ? ["basic_"+id] : [])]
                    }
                    item["complete"] = true
                }
                output = ["results":[item]]
            }
            if Self.mode == "bangumiSearch" {
                output = ["results":[["candidateID":20,"decision":"matched","scope":"whole","seasons":[1],"coverage":"full","evidenceIDs":["basic_20","tmdb_seasons"],"reason":"中日文标题与季信息一致"]]]
            }
            if ["noisyBangumi", "decisiveBangumi"].contains(Self.mode) {
                let confirmed = payload["confirmedMembership"] as? [[String:Any]] ?? []
                output = ["results":(payload["candidates"] as? [String] ?? []).map { id -> [String:Any] in
                    let valid = id.hasSuffix(":105426") || id.hasSuffix(":121108")
                    let season = id.hasSuffix(":121108") ? 2 : 1
                    var value: [String:Any] = ["candidateID":id,"decision":valid ? "matched" : "excluded","scope":"season","seasons":[season],"coverage":"full","evidenceIDs":["basic_"+id],"reason":valid ? "标题、日期与季一致" : "不同作品"]
                    if Self.mode == "noisyBangumi" && !valid && id.hasSuffix(":172450") { value["evidenceIDs"] = NSNull() }
                    if valid && confirmed.contains(where: { $0["candidateID"] as? String == id }) {
                        value["episodes"] = (1...13).map { ["platformEpisodes":[$0],"tmdbEpisodes":[["season":season,"number":$0]],"evidenceIDs":["detail_"+id,"tmdb_season_\(season)"]] as [String:Any] }
                    }
                    return value
                }]
            }
            if Self.mode == "decisiveBangumi" {
                let rows = payload["allSearchResults"] as? [[String:Any]] ?? []
                var unrelated = Dictionary(uniqueKeysWithValues:rows.compactMap { row -> (String,String)? in
                    guard let id = row["id"] as? String, !id.hasSuffix(":105426"), !id.hasSuffix(":121108") else { return nil }
                    return (id,"标题和简介属于不同作品")
                })
                if payload["phase"] as? String != "identity-screening" { unrelated["bangumi:tv:105426"] = "Contradictory rejection must not override matched" }
                unrelated["bangumi:tv:unknown"] = "Unregistered ID must be ignored"
                output["unrelatedCandidates"] = unrelated
                output["results"] = (output["results"] as? [[String:Any]] ?? []).filter { $0["decision"] as? String == "matched" }
                output["research"] = [["candidateIDs":["bangumi:tv:172450"],"question":"Stale request for unrelated subject","detailIDs":["bangumi:tv:172450"],"queries":["unrelated subject"],"platformQueries":["irrelevant alias"]]]
            }
            if ["earlyExcluded", "silentUnresolved"].contains(Self.mode) {
                if payload["final"] as? Bool == true {
                    output = ["results":[decision]]
                } else {
                    output = ["results":[["candidateID":"anilist:tv:20", "decision":Self.mode == "earlyExcluded" ? "excluded" : "unresolved", "evidenceIDs":["basic_anilist:tv:20"], "reason":"Missing perfect crosswalk"]]]
                }
            }
            if ["specialValid","specialWrong","specialBangumi"].contains(Self.mode) {
                let id = (payload["candidates"] as? [String])?.first ?? ""
                let season = Self.mode != "specialWrong" ? 0 : 1
                output = ["results":[["candidateID":id,"decision":"matched","scope":"season","seasons":[season],"coverage":"partial","episodes":[["platformEpisodes":[1,2],"tmdbEpisodes":[["season":season,"number":1]],"evidenceIDs":["detail_"+id,"tmdb_season_0"]]],"evidenceIDs":["basic_"+id],"reason":"Special title and synopsis agree"]]]
            }

            if ["autoSplit","correctMembership","autoMerge","partial","longPartial","badEpisodes","longTable","manualScope","badSchema"].contains(Self.mode) {
                let user = (body["messages"] as? [[String:Any]])?.last?["content"] as? String ?? "{}"
                let input = (try? JSONSerialization.jsonObject(with:Data(user.utf8))) as? [String:Any] ?? [:]
                let ids = input["candidates"] as? [String] ?? []
                let decisions = ids.map { id -> [String:Any] in
                    let cross = Self.mode == "autoMerge"
                    var rows: [[String:Any]] = []
                    if Self.calls > 1 {
                        let numbers = Self.mode == "longPartial" && input["final"] as? Bool == true ? [5,6] : ["partial","longPartial"].contains(Self.mode) ? [Self.calls-1] : Array(1...(cross ? 4 : 2))
                        rows = numbers.map { n in
                            let number = Self.mode == "badEpisodes" ? 99 : cross ? (n-1)%2+1 : n + (id.hasSuffix(":21") ? 2 : 0)
                            let season = cross ? (n-1)/2+1 : 1
                            return ["platformEpisodes":[n],"tmdbEpisodes":[["season":season,"number":number]],"evidenceIDs":["detail_"+id,"tmdb_season_\(season)"]]
                        }
                    }
                    var item: [String:Any] = ["candidateID":id,"decision":"matched","scope":cross ? "whole" : "season","seasons":cross ? [1,2] : [1],"coverage":cross ? "full" : "partial","evidenceIDs":["basic_"+id,"tmdb_seasons"],"reason":"Fixture"]
                    if Self.mode == "correctMembership" && Self.calls == 1 { item["coverage"] = "full"; item["seasons"] = [2] }
                    if !rows.isEmpty { item["episodes"] = rows }
                    if Self.mode == "badSchema" { item["reason"] = nil }
                    return item
                }
                output = ["results":decisions]
            }
            if ["searchEmpty","searchExcluded","noEntry"].contains(Self.mode) {
                let instruction = (body["messages"] as? [[String:Any]])?.first?["content"] as? String ?? ""
                if instruction.contains("NAME_SEARCH_PLAN") { output = ["query":"Series aliases"] }
                else if instruction.contains("NAME_SEARCH_ANSWER") { output = ["chinese_title":"作品","basis":"knowledge","title_evidence":[],"names":[["name":"Alternative","evidence":NSNull()]]] }
                else if instruction.contains("PLATFORM_SEARCH_TERMS") { output = ["queries":["Alternative"]] }
                else {
                    let user = (body["messages"] as? [[String:Any]])?.last?["content"] as? String ?? "{}"
                    let input = (try? JSONSerialization.jsonObject(with:Data(user.utf8))) as? [String:Any] ?? [:]
                    output = ["results":(input["candidates"] as? [String] ?? []).map { id -> [String:Any] in
                        ["candidateID":id,"decision":Self.mode == "searchExcluded" && id.hasSuffix(":20") ? "excluded" : "matched","scope":"whole","seasons":[1],"coverage":"full","evidenceIDs":["basic_"+id,"tmdb_seasons"],"reason":"Fixture"]
                    }]
                }
            }
            let instruction = (body["messages"] as? [[String:Any]])?.first?["content"] as? String ?? ""
            if Self.mode == "searchEmpty" && instruction.contains("Match first item") { output = ["candidate_id":NSNull(),"certain":false,"noEntry":false] }
            if Self.mode == "noEntry" { output = ["results":[],"noEntry":true,"noEntryReason":"平台候选为另一部同名作品，故事与人物完全不同"] }
            if Self.mode.hasPrefix("mal") {
                if instruction.contains("NAME_SEARCH_PLAN") { output = ["query":"Keijo aliases"] }
                else if instruction.contains("NAME_SEARCH_ANSWER") { output = ["chinese_title":"竞女","basis":"knowledge","title_evidence":[],"names":[["name":"Alternative","evidence":NSNull()]]] }
                else if instruction.contains("PLATFORM_SEARCH_TERMS") { output = ["queries":["Alternative"]] }
                else if instruction.contains("Match first item") { output = ["candidate_id":NSNull(),"certain":false,"noEntry":true,"noEntryReason":"Search is empty"] }
                else { output = ["results":[["candidateID":"mal:tv:20","decision":"matched","scope":"whole","seasons":[1],"coverage":"full","evidenceIDs":["basic_mal:tv:20","tmdb_seasons"],"reason":"Matching title and episode count"]]] }
            }
            let text = String(decoding:try! JSONSerialization.data(withJSONObject:output),as:UTF8.self)
            root = ["choices":[["message":["content":Self.mode == "malformed" ? "not JSON" : text]]]]
        }
        client?.urlProtocol(self,didReceive:HTTPURLResponse(url:url,statusCode:status,httpVersion:nil,headerFields:nil)!,cacheStoragePolicy:.notAllowed)
        client?.urlProtocol(self,didLoad:try! JSONSerialization.data(withJSONObject:root)); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
