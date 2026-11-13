import Foundation
@main struct TrackingChecks {
    @MainActor static func main() async throws {
        var count = 0
        func check(_ value:Bool,_ name:String) { precondition(value,name); count += 1; print("PASS: \(name)") }
        // Saves return after local persistence; delivery now runs in a background worker.
        func awaitDeliveries(_ store:TrackingStore) async throws {
            for _ in 0..<500 {
                if !store.backup.deliveries.contains(where: { $0.state == "等待同步" || $0.state == "同步中" }) { return }
                try await Task.sleep(for:.milliseconds(10))
            }
            preconditionFailure("Fixture delivery worker did not finish")
        }
        let a = Work(source:.tmdb,remoteID:"1",kind:.tv,title:"Test")
        let b = Work(source:.anilist,remoteID:"1",kind:.tv,title:"Test")
        check(a.id != b.id,"Platform IDs cannot collide")
        let c = Work(source:.tmdb,remoteID:"1",kind:.movie,title:"Test")
        check(MediaLanguage.merge([a,a],[a,b,b,c]).map(\.id) == [a,b,c].map(\.id),"Browse merging removes duplicates within and across pages while preserving platform and media identities")
        check(a.id != c.id,"Movie and TV IDs cannot collide")
        let novel = Work(source:.anilist,remoteID:"10",kind:.manga,title:"Novel",format:"NOVEL")
        check(novel.isNovel,"AniList NOVEL is recognized as a light novel")
        let comic = Work(source:.anilist,remoteID:"11",kind:.manga,title:"Comic",format:"MANGA")
        check(!comic.isNovel && WorkKind.manga.title == "书籍","Manga retains its format under Books category")
        let restoredNovel = try JSONDecoder().decode(Work.self,from:JSONEncoder().encode(novel))
        check(restoredNovel.isNovel,"Light novel format survives backup round trip")
        var backup = Backup(); var record = TrackingRecord(work:a); record.score = 8.37; record.links[b.source.rawValue] = b; backup.records[a.id] = record
        let roundtrip = try JSONDecoder().decode(Backup.self,from:JSONEncoder().encode(backup))
        check(roundtrip.records[a.id]?.score == 8.37,"Decimal ratings preserved")
        check(roundtrip.records[a.id]?.links["anilist"] == b,"Platform links persist")
        check(roundtrip.records[a.id]?.isPlatformEnabled(.anilist) == true,"Associated platforms always participate in synchronization")
        let trakt: [String:Any] = ["title":"Original", "year":2026, "ids":["trakt":42,"slug":"original"], "images":["poster":["cdn.trakt.tv/poster.webp"]]]
        let work = CatalogAPI.traktWork(trakt,kind:.tv)!
        check(work.remoteID == "42" && work.source == .trakt,"Trakt identity survives missing TMDB ID")
        check(work.image == "https://cdn.trakt.tv/poster.webp","Trakt schemeless poster uses HTTPS")
        check(CatalogAPI.traktWork(["title":"broken"],kind:.movie) == nil,"Malformed media is not assigned an empty ID")
        let translated = CatalogAPI.applyingChinese([["language":"zh","country":"tw","title":"繁體"],["language":"zh","country":"cn","title":"简体","overview":"中文简介"]],to:work)
        check(translated.title == "简体" && translated.overview == "中文简介","Prefer mainland Chinese metadata")
        check(translated.original == "Original","Localization retains original title")
        check(CatalogAPI.applyingChinese([["title":"","overview":""]],to:work).title == "Original","Empty translations retain original metadata")
        check(CatalogAPI.applyingChinese([],to:work) == work,"Missing translations retain full work")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TraktFixtureProtocol.self]
        let diagnosticsDirectory = FileManager.default.temporaryDirectory.appending(path:UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:diagnosticsDirectory) }
        let api = CatalogAPI(session:URLSession(configuration:configuration),credential:{ _ in "fixture" },diagnostics:DiagnosticLog(directory:diagnosticsDirectory))
        let remote = try await api.remoteLibrary(.trakt)
        check(remote.count == 3,"All watched pages loaded and ratings merged without duplicates")
        let rated = remote.first { $0.work.remoteID == "1" }!
        check(rated.score == 9 && rated.status == "已完成","Personal rating merges into watched status")
        check(remote.contains { $0.work.remoteID == "2" },"Second watched page remains visible")
        check(remote.first { $0.work.remoteID == "3" }?.status == "已评分","Rating-only works remain visible")
        check(remote.allSatisfy { $0.progressDisabled.contains("trakt") },"Imported aggregate history never becomes an episode write")
        let history = try await api.history()
        check(history.first?.0.source == .trakt && history.first?.0.image.isEmpty == false,"Recent history preserves source and image without TMDB")
        check(history.first?.1 == 4 && history.first?.2 == 2,"Recent episode cursor retains season and number")
        let historyDirectory = diagnosticsDirectory.appending(path:"history-store")
        let historyStore = TrackingStore(directory:historyDirectory,api:api)
        await historyStore.refreshHistory()
        check(historyStore.recent.first?.1 == 4 && historyStore.message == nil,"Home refresh still loads recent history")
        let savedHistory = historyStore.backup.history
        let cancelledHistory = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            await historyStore.refreshHistory()
        }
        await cancelledHistory.value
        check(historyStore.message == nil && historyStore.backup.history == savedHistory,"Swift task cancellation does not alert or replace saved history")
        TraktFixtureProtocol.historyFailure = URLError(.cancelled)
        await historyStore.refreshHistory()
        check(historyStore.message == nil && historyStore.backup.history == savedHistory,"Cancelled URL request does not alert or replace saved history")
        TraktFixtureProtocol.historyFailure = URLError(.notConnectedToInternet)
        await historyStore.refreshHistory()
        check(historyStore.message != nil && historyStore.backup.history == savedHistory,"Real history failures remain visible and retain saved history")
        TraktFixtureProtocol.historyFailure = nil
        let historyReloaded = TrackingStore(directory:historyDirectory,api:api)
        check(historyReloaded.backup.history == savedHistory,"History survives reopening after cancelled and failed refreshes")
        do { _ = try await api.request("https://api.trakt.tv/unauthorized"); preconditionFailure("401 accepted") }
        catch { check(error.localizedDescription.contains("登录已过期"),"Expired login is actionable") }

        var lockedCredentials = false
        let checkedAPI = CatalogAPI(session:URLSession(configuration:configuration),credential:{ _ in "fixture" },
            credentialChecked:{ _ in
                if lockedCredentials { throw APIError.message("Keychain temporarily locked") }
                return "fixture"
            },diagnostics:DiagnosticLog(directory:diagnosticsDirectory))
        let checkedStore = TrackingStore(directory:historyDirectory,api:checkedAPI)
        await checkedStore.refreshLibrary(source:.trakt)
        let cachedLibrary = checkedStore.library["trakt"]
        let checkedDB = try checkedStore.cloudStorage().db
        let cachedSnapshots = try checkedDB.loadSnapshots()
        let historyOperations = try checkedDB.pendingCloudOperations().filter { $0.field.hasPrefix("library/history/") }
        lockedCredentials = true
        await checkedStore.refreshHistory()
        await checkedStore.refreshLibrary(source:.trakt)
        check(checkedStore.message?.contains("Keychain temporarily locked") == true && checkedStore.libraryErrors["trakt"] != nil,
              "Credential read failures are reported separately from signed-out accounts")
        check(checkedStore.backup.history == savedHistory && checkedStore.recent.first?.1 == 4 && checkedStore.library["trakt"] == cachedLibrary,
              "Locked credentials preserve recent history and platform library in memory")
        check(await checkedStore.persistAsync(),"Unrelated saves still work while credentials are temporarily unreadable")
        check(try checkedDB.loadSnapshots() == cachedSnapshots && checkedDB.loadBackup()?.history == savedHistory,
              "Credential failure preserves persisted history and platform snapshots")
        check(try checkedDB.pendingCloudOperations().filter { $0.field.hasPrefix("library/history/") } == historyOperations,
              "Credential read failure never queues cloud history deletions")
        let lockedRestart = TrackingStore(directory:historyDirectory,api:checkedAPI)
        check(lockedRestart.startupFailure == nil && lockedRestart.backup.history == savedHistory,
              "Starting with a locked Keychain keeps the library readable")
        lockedCredentials = false
        TraktFixtureProtocol.historyFailure = URLError(.notConnectedToInternet)
        await lockedRestart.refreshHistory()
        check(lockedRestart.recent.first?.1 == 4 && lockedRestart.backup.history == savedHistory,
              "Recovering credential access after startup does not clear history on a network failure")
        TraktFixtureProtocol.historyFailure = nil
        await checkedStore.refreshHistory()
        await checkedStore.refreshLibrary(source:.trakt)
        check(checkedStore.recent.first?.1 == 4 && checkedStore.libraryErrors["trakt"] == nil,
              "History and platform refresh resume after Keychain access recovers")

        let oauthNames = ["trakt.clientID","trakt.token","trakt.refresh"]
        let legacyOAuth = ["trakt.clientID":"client","trakt.token":"old-access","trakt.refresh":"old-refresh"]
        var keychainItems = legacyOAuth
        var failGroupWrite = false, failCleanup = false, failGroupRead = false
        var credentialNotifications:[String] = []
        let vault = CredentialVault(read:{ name in
            if failGroupRead && name.hasPrefix("oauth-group.v1.") { throw APIError.message("Keychain locked") }
            return keychainItems[name] ?? ""
        },write:{ name,value in
            if (failGroupWrite && name.hasPrefix("oauth-group.v1.")) || (failCleanup && legacyOAuth[name] != nil) {
                throw APIError.message("Injected Keychain write failure")
            }
            keychainItems[name] = value
        },changed:{ credentialNotifications.append($0) })
        check(try vault.read(oauthNames) == legacyOAuth,"Existing individual OAuth credentials remain readable before migration")
        failGroupWrite = true
        do {
            try vault.write(["trakt.token":"new-access","trakt.refresh":"new-refresh"])
            preconditionFailure("Accepted failing group write")
        } catch { }
        check(try vault.read(oauthNames) == legacyOAuth && credentialNotifications.isEmpty,
              "A failed atomic OAuth write retains both old tokens and emits no success notifications")
        failGroupWrite = false; failCleanup = true
        try vault.write(["trakt.token":"new-access","trakt.refresh":"new-refresh"])
        let migratedOAuth = ["trakt.clientID":"client","trakt.token":"new-access","trakt.refresh":"new-refresh"]
        let reopenedVault = CredentialVault(read:{ keychainItems[$0] ?? "" },write:{ keychainItems[$0] = $1 })
        check(try reopenedVault.read(oauthNames) == migratedOAuth && keychainItems["trakt.token"] == "old-access",
              "Restart after interrupted legacy cleanup reads the complete committed OAuth group")
        check(Set(credentialNotifications) == ["trakt.token","trakt.refresh"],"Credential changes notify only after both new tokens are committed")
        try vault.write(["trakt.clientID":"updated-client"])
        check(try vault.read(oauthNames)["trakt.refresh"] == "new-refresh" && vault.read(oauthNames)["trakt.token"] == "new-access",
              "Editing one credential preserves the rest of its account group")
        check(try !vault.write(["trakt.token":"stale-access","trakt.refresh":"stale-refresh"],ifUnchanged:legacyOAuth),
              "A late refresh cannot overwrite a newer complete credential group")
        let currentOAuth = try vault.read(oauthNames)
        check(try vault.write(["trakt.token":"rotated-access","trakt.refresh":"rotated-refresh"],ifUnchanged:currentOAuth),
              "A refresh with unchanged credentials commits its complete token pair")
        failGroupRead = true
        do { _ = try vault.read(oauthNames); preconditionFailure("Unreadable OAuth group fell back to legacy values") }
        catch { check(true,"A locked OAuth group propagates its read failure without using stale legacy credentials") }
        failGroupRead = false
        try vault.write(["trakt.token":"","trakt.refresh":""])
        check(try reopenedVault.read(oauthNames)["trakt.token"] == "" && reopenedVault.read(oauthNames)["trakt.refresh"] == "",
              "Disconnect survives restart without resurrecting stale legacy credentials")
        let malLegacy = ["mal.clientID":"mal-client","mal.token":"mal-old","mal.refresh":"mal-refresh"]
        keychainItems.merge(malLegacy) { _,new in new }; failCleanup = false
        try vault.write(["mal.token":"mal-new","mal.refresh":"mal-new-refresh"])
        check(try vault.read(Array(malLegacy.keys)) == ["mal.clientID":"mal-client","mal.token":"mal-new","mal.refresh":"mal-new-refresh"],
              "MyAnimeList uses the same complete OAuth group migration")

        let accountConfig = URLSessionConfiguration.ephemeral
        accountConfig.protocolClasses = [AccountFixtureProtocol.self]
        var accountCredentials = ["trakt.token":"valid","trakt.refresh":"refresh","trakt.clientID":"client","mal.token":"valid","bangumi.token":"valid","tmdb.token":"valid"]
        let accountAPI = CatalogAPI(session:URLSession(configuration:accountConfig),credential:{ accountCredentials[$0] ?? "" },diagnostics:DiagnosticLog(directory:diagnosticsDirectory))
        let health = AccountHealth()
        await health.check(.trakt,api:accountAPI)
        check(health.states[.trakt] == .connected("fixture-user"),"Account health verifies the actual signed-in user")
        let accountRequests = AccountFixtureProtocol.requests
        await health.check(.trakt,api:accountAPI)
        check(AccountFixtureProtocol.requests == accountRequests,"Unchanged healthy credentials reuse recent verification")
        await health.check(.anilist,api:accountAPI)
        check(health.states[.anilist] == .disconnected && AccountFixtureProtocol.requests == accountRequests,"Missing credentials do not send a verification request")
        for source in [Catalog.mal,.bangumi,.tmdb] { await health.check(source,api:accountAPI) }
        check(health.states[.mal] == .connected("fixture-user") && health.states[.bangumi] == .connected("fixture-user"),"MAL and Bangumi validate account identities")
        check(health.states[.tmdb] == .connected("读取令牌有效 · 评分账号未登录"),"TMDB read access stays distinct from a rating account")
        accountCredentials["tmdb.session"] = "session"
        await health.check(.tmdb,api:accountAPI)
        check(health.states[.tmdb] == .connected("fixture-user"),"TMDB session changes trigger verification without waiting for the cache")
        AccountFixtureProtocol.status = 401
        await health.check(.trakt,force:true,api:accountAPI)
        check(health.states[.trakt] == .expired && accountCredentials["trakt.token"] == "valid","Rejected credentials remain available for recovery and show expiration")
        AccountFixtureProtocol.status = 503
        await health.check(.trakt,force:true,api:accountAPI)
        check(health.states[.trakt] == .unavailable,"Server failure is distinct from expired authorization")
        AccountFixtureProtocol.status = 401
        var recovered = 0
        await health.check(.trakt,force:true,api:accountAPI,recover:{ _ in
            recovered += 1; accountCredentials["trakt.token"] = "rotated"; AccountFixtureProtocol.status = 200
        })
        check(recovered == 1 && health.states[.trakt] == .connected("fixture-user"),"Expired OAuth credentials recover once and verify the rotated token")
        health.invalidate(.trakt,token:"valid",read:{ accountCredentials[$0] ?? "" })
        check(health.states[.trakt] == .connected("fixture-user"),"Late rejection of an old token cannot expire a new login")
        health.invalidate(.trakt,token:"rotated",read:{ accountCredentials[$0] ?? "" })
        check(health.expiredPlatforms == [.trakt],"Only rejected current credentials appear in the settings warning")
        AccountFixtureProtocol.status = 401
        await health.check(.trakt,force:true,api:accountAPI,recover:{ _ in recovered += 1 })
        check(recovered == 2 && health.states[.trakt] == .expired,"Recovery cannot loop when refreshed authorization is still rejected")
        AccountFixtureProtocol.status = 200
        await AccountHealth.shared.check(.tmdb,force:true,api:accountAPI)
        accountCredentials["tmdb.session"] = "new-session"
        AccountFixtureProtocol.status = 401
        do { _ = try await accountAPI.request("https://api.themoviedb.org/3/account?session_id=session",headers:["Authorization":"Bearer valid"]) } catch { }
        check(AccountHealth.shared.states[.tmdb] == .connected("fixture-user"),"Late rejection of an old TMDB session cannot expire a new login")
        do { _ = try await accountAPI.request("https://api.themoviedb.org/3/account?session_id=new-session",headers:["Authorization":"Bearer valid"]) } catch { }
        check(AccountHealth.shared.states[.tmdb] == .expired,"Rejection of the current TMDB session updates the global account warning")
        await health.check(.trakt,force:true,api:accountAPI,recover:{ _ in throw HTTPFailure(status:400,reason:"invalid_grant") })
        check(health.states[.trakt] == .expired,"A revoked refresh grant requires reauthorization")
        AccountFixtureProtocol.status = 200

        let unreadableAccountAPI = CatalogAPI(session:URLSession(configuration:accountConfig),credential:{ _ in "" },
            credentialChecked:{ _ in throw APIError.message("Keychain temporarily locked") },diagnostics:DiagnosticLog(directory:diagnosticsDirectory))
        let verificationRequests = AccountFixtureProtocol.requests
        await health.check(.trakt,force:true,api:unreadableAccountAPI)
        check(health.states[.trakt] == .unavailable && AccountFixtureProtocol.requests == verificationRequests,
              "Unreadable account credentials show temporary unavailability without sending an unsigned request")
        await health.check(.trakt,api:accountAPI)
        check(health.states[.trakt] == .connected("fixture-user"),"Account verification recovers after Keychain access returns")

        var seasons = TrackingRecord(work:a)
        seasons.progress = 6; seasons.score = 9; seasons.status = "进行中"
        seasons.prepareUnits(); seasons.ensureSeason(2,title:"第二季")
        check(seasons.viewingUnits?.count == 2,"Each season receives an independent record")
        check(seasons.viewingUnits?[0].progress == 6 && seasons.viewingUnits?[0].score == nil && seasons.score == 9,"Legacy series rating stays separate from season rating")
        seasons.viewingUnits?[0].score = 7
        seasons.viewingUnits?[1].score = 8.5
        seasons.viewingUnits?[1].markThrough(3)
        check(seasons.viewingUnits?[0].progress == 6 && seasons.viewingUnits?[0].score == 7,"Editing season two preserves season one")
        seasons.prepareUnits()
        check(seasons.viewingUnits?.count == 2,"Season migration is idempotent")
        let decodedSeasons = try JSONDecoder().decode(TrackingRecord.self,from:JSONEncoder().encode(seasons))
        check(decodedSeasons.viewingUnits?[1].score == 8.5,"Season ratings survive archive round trip")
        var part = ViewingUnit(title:"下篇",season:2,firstEpisode:13,lastEpisode:24,scopeConfirmed:true,links:["anilist":b])
        part.markThrough(3); part.score = 8.2
        let animePayload = try seasons.unitPayload(part,target:b)
        check(animePayload.progress == 3 && animePayload.score == 8.2,"Part progress and score target its own AniList entry")
        let traktTarget = Work(source:.trakt,remoteID:"42",kind:.tv,title:"Test")
        let traktPayload = try seasons.unitPayload(part,target:traktTarget)
        check(traktPayload.progress == 15 && traktPayload.season == 2,"Part episode three maps to S02E15")
        check(traktPayload.score == nil && traktPayload.scoreCleared == false,"Part rating cannot overwrite or clear Trakt series rating")
        check(traktPayload.episodeHistory?.map(\.number) == [13,14,15],"Trakt receives all watched episodes in the part")
        part.toggle(2)
        check(part.contiguousProgress == 1 && part.hasWatched(3),"Episode gaps preserve watched episodes without advancing AniList through the gap")
        part.toggle(2)
        check(part.contiguousProgress == 3,"Filling a gap restores contiguous progress")
        part.markThrough(12)
        check(part.status == "已完成","Completing a part completes only that unit")
        part.toggle(12)
        check(part.status == "进行中","Unchecking an episode reopens completed part")
        part.scopeConfirmed = false
        do { _ = try seasons.unitPayload(part,target:traktTarget); preconditionFailure("Unconfirmed scope sent") } catch { check(true,"Unconfirmed part cannot write Trakt episodes") }
        var cross = ViewingUnit(title:"跨季条目",season:1,firstEpisode:11,lastEpisode:12,additionalRanges:[EpisodeRange(season:2,first:1,last:3)],scopeConfirmed:true,links:["anilist":b])
        cross.markThrough(4)
        check(cross.total == 5 && cross.episodeIndex(season:2,number:2) == 4,"Cross-season range preserves AniList numbering")
        let crossPayload = try seasons.unitPayload(cross,target:traktTarget)
        check(crossPayload.season == 2 && crossPayload.progress == 2 && crossPayload.episodeHistory?.count == 4,"Cross-season progress produces exact episode addresses")
        cross.additionalRanges = [EpisodeRange(season:1,first:12,last:15)]
        check(!cross.validScope,"Overlapping ranges are rejected")
        cross.additionalRanges = [EpisodeRange(season:2,first:1,last:nil)]
        check(!cross.validScope,"Cross-season ranges require bounded segments")
        var importedOne = TrackingRecord(work:b); importedOne.score = 7; importedOne.progress = 12
        let other = Work(source:.anilist,remoteID:"2",kind:.tv,title:"第二季")
        var importedTwo = TrackingRecord(work:other); importedTwo.score = 9; importedTwo.progress = 3
        let one = try LibraryIdentity.canonical(importedOne,using:a)
        let two = try LibraryIdentity.canonical(importedTwo,using:a)
        let merged = LibraryIdentity.mergeImport(two,existing:one)
        check(merged.platformLinks?.count == 2 && merged.platformLinks?.first(where:{ $0.id == b.id })?.legacy?.score == 7 && merged.platformLinks?.first(where:{ $0.id == other.id })?.legacy?.score == 9,"Import retains distinct platform records and their original scores")
        check(LibraryIdentity.mergeImport(two,existing:merged).platformLinks?.count == 2,"Repeated season import does not duplicate units")
        let legacyJSON = try JSONSerialization.jsonObject(with:JSONEncoder().encode(record)) as! [String:Any]
        var legacyObject = legacyJSON; legacyObject.removeValue(forKey:"viewingUnits"); legacyObject.removeValue(forKey:"episodeHistory")
        let legacy = try JSONDecoder().decode(TrackingRecord.self,from:JSONSerialization.data(withJSONObject:legacyObject))
        check(legacy.viewingUnits == nil && legacy.progress == record.progress,"Legacy backups decode without new season fields")
        // Reproduce mixed-language platform entries being exposed as seasons.
        var mixed = TrackingRecord(work:traktTarget,season:2,links:[
            "anilist":Work(source:.anilist,remoteID:"mixed-a",kind:.tv,title:"サイバーパンク エッジランナーズ"),
            "mal":Work(source:.mal,remoteID:"mixed-m",kind:.tv,title:"Cyberpunk: Edgerunners"),
            "bangumi":Work(source:.bangumi,remoteID:"mixed-b",kind:.tv,title:"赛博朋克：边缘行者")])
        mixed.prepareUnits(); mixed.ensureSeason(1,title:"第一季"); mixed.ensureSeason(2,title:"第二季")
        check(mixed.viewingUnits?.map(\.season) == [1,2] && mixed.platformLinks?.count == 3,"Three translated platform entries remain separate from two sorted actual seasons")

        let editingDirectory = diagnosticsDirectory.appending(path:"progress-edits")
        let editor = TrackingStore(directory:editingDirectory,api:api)
        var baseline = TrackingRecord(work:a,links:["tmdb":a,"trakt":traktTarget])
        baseline.prepareUnits(); baseline.ensureSeason(2,title:"第二季")
        _ = baseline.associate(b,unitID:"season:1")
        _ = baseline.associate(other,unitID:"season:2")
        baseline.viewingUnits?[0].lastEpisode = 12
        baseline.viewingUnits?[1].lastEpisode = 12
        for index in baseline.platformLinks!.indices {
            let season = baseline.platformLinks![index].season
            baseline.platformLinks![index].mapping = ContentMapping(tmdbID:a.remoteID,confirmed:true,seasons:[season],coverage:"full",episodes:(1...12).map {
                EpisodeCorrespondence(platformEpisodes:[$0],tmdbEpisodes:[EpisodeAddress(season:season,number:$0)])
            },platformEpisodeCount:12,complete:true)
        }
        check(!baseline.hasMissingEpisodeMapping,"Complete episode mappings are excluded from missing-mapping inspection")
        var missingEpisodes = baseline
        missingEpisodes.platformLinks?[0].mapping = nil
        check(missingEpisodes.hasMissingEpisodeMapping,"Any association without episode correspondence appears in inspection")
        missingEpisodes.platformLinks?[0].mapping = baseline.platformLinks?[0].mapping
        missingEpisodes.platformLinks?[0].mapping?.episodes = []
        check(missingEpisodes.hasMissingEpisodeMapping,"Zero corresponding episodes appear in inspection")
        missingEpisodes.platformLinks?[0].mapping?.episodes = [baseline.platformLinks![0].mapping!.episodes[0]]
        missingEpisodes.platformLinks?[0].mapping?.complete = false
        check(!missingEpisodes.hasMissingEpisodeMapping,"Yellow partial mappings count as corresponding episodes")
        let partialPlatform = missingEpisodes.platformLinks![0].target.source
        check(missingEpisodes.hasPartialEpisodeMapping(partialPlatform),"Import reports partial episodes when all associations have mapped episodes")
        check(!baseline.hasPartialEpisodeMapping(partialPlatform),"Complete mappings are not partial")
        var mixedEpisodes = missingEpisodes
        var zeroAssociation = mixedEpisodes.platformLinks![0]
        zeroAssociation.target.remoteID = "zero-episode-test"
        zeroAssociation.mapping = nil
        mixedEpisodes.platformLinks?.append(zeroAssociation)
        check(!mixedEpisodes.hasPartialEpisodeMapping(partialPlatform),"A zero-episode association prevents partial-only platform status")
        missingEpisodes.work.kind = .manga
        check(!missingEpisodes.hasPartialEpisodeMapping(partialPlatform),"Books do not report partial episode status")
        check(!missingEpisodes.hasMissingEpisodeMapping,"Books are excluded from episode-mapping inspection")
        let shelfStore = TrackingStore(directory:diagnosticsDirectory.appending(path:"platform-shelf"),api:api)
        shelfStore.backup.records[a.id] = baseline
        let unmatchedPart = TrackingRecord(work:Work(source:.anilist,remoteID:"unmatched-part",kind:.tv,title:b.title))
        let sourceParts = [TrackingRecord(work:b),unmatchedPart,TrackingRecord(work:other),TrackingRecord(work:b)]
        let shelfGroups = shelfStore.platformShelfGroups(sourceParts,source:.anilist)
        check(shelfGroups.map { $0.map(\.id) } == [[b.id,other.id],[unmatchedPart.id]],"AniList shelf groups different seasons by library identity and preserves first appearance")
        check(shelfStore.platformShelfGroups([unmatchedPart,unmatchedPart],source:.anilist).map(\.count) == [1],"Duplicate source rows do not create a collection")
        check(shelfStore.platformShelfGroups(sourceParts,source:.trakt).count == 3,"Other platform shelves retain separate source entries")
        check(shelfStore.backup.records[a.id]?.platformLinks?.count == baseline.platformLinks?.count,"Shelf grouping preserves every saved platform association")
        var changes = baseline
        changes.viewingUnits?[0].markThrough(2)
        changes.viewingUnits?[1].markThrough(4)
        check(changes.hasTrackingChanges(from:baseline),"Editing progress in multiple seasons marks tracking changes")
        var metadataOnly = baseline
        metadataOnly.viewingUnits?[0].title = "新标题"
        metadataOnly.viewingUnits?[0].lastEpisode = 24
        metadataOnly.ensureSeason(3,title:"第三季")
        check(!metadataOnly.hasTrackingChanges(from:baseline),"Downloaded seasons, metadata and associations do not create unsaved tracking edits")
        check(!baseline.hasTrackingChanges(from:baseline),"Reverting edits leaves no unsaved change")
        let beforeAutomatic = TraktFixtureProtocol.requests.count
        check(await editor.saveProgressChanges(changes,from:baseline,unitID:"season:2"),"Saving progress automatically submits all edited seasons")
        try await awaitDeliveries(editor)
        check(editor.backup.deliveries.count == 6 && editor.backup.deliveries.allSatisfy { $0.state == "已同步" },"Two seasons create field-scoped deliveries for linked platforms")
        let automaticRequests = TraktFixtureProtocol.requests.dropFirst(beforeAutomatic)
        check(automaticRequests.filter { $0.url?.host == "graphql.anilist.co" }.count == 4,"Both AniList season entries receive independent progress and status")
        check(automaticRequests.filter { $0.url?.path == "/sync/history" && $0.httpMethod == "POST" }.count == 2,"Both Trakt seasons are updated once")
        let savedChanges = editor.libraryRecord(for:a)!
        let afterAutomatic = TraktFixtureProtocol.requests.count
        check(await editor.saveProgressChanges(savedChanges,from:savedChanges,unitID:"season:2"),"Saving unchanged progress succeeds locally")
        try await awaitDeliveries(editor)
        check(TraktFixtureProtocol.requests.count == afterAutomatic && editor.backup.deliveries.count == 6,"Unchanged saves never duplicate platform writes")
        var ratingsOnly = savedChanges
        ratingsOnly.score = 9; ratingsOnly.viewingUnits?[1].score = 8
        check(await editor.saveProgressChanges(ratingsOnly,from:savedChanges,unitID:"season:2"),"Rating-only changes save locally")
        try await awaitDeliveries(editor)
        let ratingRequests = TraktFixtureProtocol.requests.dropFirst(afterAutomatic)
        check(!ratingRequests.contains { $0.url?.path.contains("/sync/history") == true },"Rating-only save does not resend progress")
        check(ratingRequests.contains { $0.url?.path == "/sync/ratings" } && ratingRequests.contains { $0.url?.path == "/3/tv/1/rating" },"Whole rating writes Trakt and TMDB independently of progress")
        check(editor.backup.deliveries.suffix(4).allSatisfy { $0.fields == [.rating] },"Ratings use isolated field-scoped deliveries")
        let pendingPayload = try ratingsOnly.associationPayload(ratingsOnly.platformLinks!.first { $0.id == b.id }!)
        let pendingJob = Delivery(record:pendingPayload,target:b,associationID:b.id,fields:[.rating],state:"网络暂时不可用")
        editor.backup.deliveries.append(pendingJob)
        var editedAgain = editor.libraryRecord(for:a)!
        let beforeSecondEdit = editedAgain
        editedAgain.viewingUnits?[0].score = 9
        editedAgain.viewingUnits?[1].markThrough(5)
        check(await editor.saveProgressChanges(editedAgain,from:beforeSecondEdit,unitID:"season:2"),"A new progress edit saves alongside a failed job in another season")
        try await awaitDeliveries(editor)
        check(editor.backup.deliveries.first { $0.id == pendingJob.id }?.state == "网络暂时不可用","Automatic synchronization does not retry unrelated failed scopes")
        await editor.retry(recordID:a.id,deliveryIDs:[pendingJob.id])
        for _ in 0..<500 {
            if editor.backup.deliveries.first(where:{ $0.id == pendingJob.id })?.state == "已同步" { break }
            try await Task.sleep(for:.milliseconds(10))
        }
        let retriedJob = editor.backup.deliveries.first { $0.id == pendingJob.id }
        check(retriedJob?.record.score == 9 && retriedJob?.state == "已同步","Manual retry uses the latest saved season rating and progress (state: \(retriedJob?.state ?? "missing"), score: \(retriedJob?.record.score ?? -1), error: \(retriedJob?.errorDetail ?? "none"))")
        let failedAPI = CatalogAPI(session:URLSession(configuration:configuration),credential:{ _ in "" },diagnostics:DiagnosticLog(directory:diagnosticsDirectory))
        let failedStore = TrackingStore(directory:diagnosticsDirectory.appending(path:"failed-progress"),api:failedAPI)
        check(await failedStore.saveProgressChanges(changes,from:baseline,unitID:"season:2"),"Remote failure does not report locally saved changes as unsaved")
        try await awaitDeliveries(failedStore)
        check(failedStore.libraryRecord(for:a)?.viewingUnits?[1].progress == 4 && failedStore.deliveryErrorCount == 6,"Failed automatic writes retain local progress and actionable delivery errors")
        let savedFailure = failedStore.libraryRecord(for:a)!
        var localRating = savedFailure; localRating.score = 7
        check(await failedStore.saveProgressChanges(localRating,from:savedFailure,unitID:"season:2"),"A later rating edit can save while platform jobs are pending")
        try await awaitDeliveries(failedStore)
        check(failedStore.backup.deliveries.filter { $0.fields?.contains(.progress) == true && $0.isError }.count == 4,"A rating-only save preserves pending jobs from every season")
        var invalidMapping = baseline
        invalidMapping.viewingUnits?[0].scopeConfirmed = false
        invalidMapping.viewingUnits?[0].markThrough(2)
        let invalidStore = TrackingStore(directory:diagnosticsDirectory.appending(path:"invalid-mapping"),api:api)
        check(await invalidStore.saveProgressChanges(invalidMapping,from:baseline,unitID:"season:1"),"An unconfirmed mapping does not prevent local progress saving")
        try await awaitDeliveries(invalidStore)
        check(invalidStore.backup.deliveries.contains { $0.target.source == .trakt && ($0.errorDetail ?? $0.state).contains("对应的季和集数") } && invalidStore.backup.deliveries.contains { $0.target.source == .anilist && $0.state == "已同步" },"One invalid mapping does not block another platform")
        let beforeInvalidRetry = TraktFixtureProtocol.requests.count
        await invalidStore.retry()
        check(TraktFixtureProtocol.requests.count == beforeInvalidRetry,"Retry never sends an unconfirmed Trakt mapping")
        var refreshingSeasons = baseline
        refreshingSeasons.viewingUnits?[0].scopeConfirmed = false
        refreshingSeasons.ensureSeason(1,title:"Duplicate")
        check(refreshingSeasons.viewingUnits?.filter { $0.id == "season:1" }.count == 1,"Refreshing an unconfirmed season never duplicates its stable ID")
        var zeroProgress = editor.record(a)
        zeroProgress.viewingUnits?[1].markThrough(0)
        check(await editor.save(zeroProgress,unitID:"season:2"),"Resetting a season to zero saves locally")
        check(editor.record(a).progress == 0 && editor.record(a).season == 2,"Zero season progress clears the series episode cursor")

        var whole = TrackingRecord(work:a,status:"进行中",links:["tmdb":a])
        whole.prepareUnits(); whole.ensureSeason(2,title:"Second")
        whole.viewingUnits?[0].lastEpisode = 12; whole.viewingUnits?[1].lastEpisode = 12
        whole.viewingUnits?[0].markThrough(12); whole.viewingUnits?[1].markThrough(3)
        check(whole.setPlatformAssociation(b),"New TV association attaches at work level without selecting a season")
        check(whole.platformLinks?.first?.scope == .whole && whole.viewingUnits?.allSatisfy { $0.links.isEmpty } == true,"Whole-work matching does not create provider-named seasons")
        check(try whole.associationPayload(whole.platformLinks![0]).progress == 15,"Whole-work progress combines completed earlier seasons once")
        var gap = whole; gap.viewingUnits?[0].markThrough(5)
        check(try gap.associationPayload(gap.platformLinks![0]).progress == 5,"Whole-work progress stops at a gap in an earlier season")
        var unknownLength = whole; unknownLength.viewingUnits?[0].lastEpisode = nil
        do { _ = try unknownLength.associationPayload(unknownLength.platformLinks![0]); preconditionFailure("Unknown earlier season length accepted") }
        catch { check(true,"Whole-work synchronization asks for missing earlier season length") }
        var seasonLink = whole.platformLinks![0]; seasonLink.scope = .season; seasonLink.season = 2
        check(try whole.associationPayload(seasonLink).progress == 3,"A platform entry assigned to season two receives season-relative progress")
        var customLink = seasonLink; customLink.scope = .custom
        customLink.customRanges = [EpisodeRange(season:1,first:11,last:12),EpisodeRange(season:2,first:1,last:3)]
        var oldCustom = whole; oldCustom.platformLinks = [customLink]; oldCustom.prepareUnits()
        check(oldCustom.platformLinks?.first?.scope == .whole && oldCustom.platformLinks?.first?.customRanges.count == 2,"Old custom mappings become whole-work associations and retain migration evidence")
        check(try oldCustom.associationPayload(oldCustom.platformLinks![0]).progress == 15,"Migrated mappings use only whole-work progress")
        customLink.customRanges.append(EpisodeRange(season:2,first:2,last:4))
        do { _ = try whole.associationPayload(customLink); preconditionFailure("Overlapping association accepted") }
        catch { check(true,"Overlapping association ranges never produce a remote write") }
        let wholeStore = TrackingStore(directory:diagnosticsDirectory.appending(path:"whole-work"),api:api)
        var beforeWhole = whole; beforeWhole.viewingUnits?[0].markThrough(0); beforeWhole.viewingUnits?[1].markThrough(0)
        check(await wholeStore.saveProgressChanges(whole,from:beforeWhole,unitID:"season:2"),"Multiple edited seasons can save through a whole-work association")
        try await awaitDeliveries(wholeStore)
        check(wholeStore.backup.deliveries.count == 1 && wholeStore.backup.deliveries.first?.state == "已跳过" && wholeStore.message == nil,"Zero episode mappings are logged as skipped without reporting a sync failure")
        check(wholeStore.deliveryErrorCount == 0 && wholeStore.backup.deliveries.first?.isPending == false,"Skipped progress is terminal and does not increase the error count")
        let beforeSkippedRetry = TraktFixtureProtocol.requests.count
        await wholeStore.retry()
        check(TraktFixtureProtocol.requests.count == beforeSkippedRetry,"Retry ignores skipped zero-mapping deliveries")
        let skippedReopened = TrackingStore(directory:diagnosticsDirectory.appending(path:"whole-work"),api:api)
        check(skippedReopened.backup.deliveries.first?.state == "已跳过" && skippedReopened.deliveryErrorCount == 0,"Skipped progress survives reopening without errors")
        wholeStore.backup.deliveries.append(Delivery(record:whole,target:b,associationID:b.id,fields:[.progress,.status],errorDetail:"旧失败",state:"失败"))
        await wholeStore.retry()
        check(wholeStore.backup.deliveries.last?.state == "已跳过" && wholeStore.backup.deliveries.last?.errorDetail == nil && TraktFixtureProtocol.requests.count == beforeSkippedRetry,"Old failed zero-mapping deliveries become skipped on retry without HTTP requests")
        var associationEdit = wholeStore.record(a)
        associationEdit.viewingUnits?[1].markThrough(8); associationEdit.score = 2
        associationEdit.platformLinks?[0].scope = .season; associationEdit.platformLinks?[0].season = 2
        wholeStore.saveAssociations(associationEdit)
        check(wholeStore.record(a).viewingUnits?[1].progress == 3 && wholeStore.record(a).score == nil && wholeStore.record(a).platformLinks?[0].scope == .season,"Immediate scope changes do not save unfinished progress or ratings")
        wholeStore.selected = b
        wholeStore.deleteRecords([a.id])
        check(wholeStore.selected == nil,"Deleting a canonical work clears selection opened through a platform identity")

        var oldMixed = TrackingRecord(work:a,viewingUnits:[
            ViewingUnit(id:"season:2",title:"Second",season:2,scopeConfirmed:true,progress:3),
            ViewingUnit(id:b.id,title:"日本語タイトル",season:1,progress:8,score:7.5,links:["anilist":b])])
        oldMixed.prepareUnits(); oldMixed.ensureSeason(1,title:"Season One")
        check(oldMixed.viewingUnits?.map(\.title) == ["第 1 季","第 2 季"],"Legacy mixed-language parts migrate out of the sorted season selector")
        check(oldMixed.platformLinks?.first?.scope == .unresolved && oldMixed.platformLinks?.first?.legacy?.progress == 8 && oldMixed.platformLinks?.first?.legacy?.score == 7.5,"Ambiguous old platform entries retain rating and progress awaiting range selection")
        let migratedData = try JSONEncoder().encode(oldMixed)
        oldMixed.prepareUnits()
        let migratedRoundtrip = try JSONDecoder().decode(TrackingRecord.self,from:migratedData)
        check(oldMixed.platformLinks?.count == 1 && migratedRoundtrip.archivedUnits?.count == 2 && migratedRoundtrip.platformLinks?.first?.legacy?.score == 7.5,"Migration is idempotent and archived source records survive backup round trip")
        var oldConfirmed = TrackingRecord(work:a,viewingUnits:[ViewingUnit(id:b.id,title:"Part",season:2,firstEpisode:3,lastEpisode:5,scopeConfirmed:true,progress:2,score:8,links:["anilist":b])])
        oldConfirmed.prepareUnits()
        check(oldConfirmed.platformLinks?.first?.scope == .whole && oldConfirmed.viewingUnits?.first?.watched == Set([3,4]) && oldConfirmed.archivedUnits?.first?.score == 8,"Confirmed legacy parts preserve exact episode addresses and their original rating")
        do { _ = try oldMixed.associationPayload(oldMixed.platformLinks![0]); preconditionFailure("Ambiguous migrated association was sent") }
        catch { check(true,"Unresolved legacy mapping cannot silently write platform progress") }

        let mangaStore = TrackingStore(directory:diagnosticsDirectory.appending(path:"retry-current"),api:api)
        var book = TrackingRecord(work:comic,progress:2,links:["anilist":comic])
        check(await mangaStore.save(book),"Book fixture saves")
        let staleBook = Delivery(record:book,target:comic,state:"网络失败")
        mangaStore.backup.deliveries.append(staleBook)
        book.progress = 9; book.score = 8
        check(await mangaStore.save(book,preservingPendingDeliveries:true),"Local book updates can preserve failed delivery")
        await mangaStore.retry()
        check(mangaStore.backup.deliveries.first?.record.progress == 9 && mangaStore.backup.deliveries.first?.record.score == 8,"Book retries read the latest saved progress and rating")
        let orphan = Delivery(record:book,target:comic,state:"网络失败")
        mangaStore.backup.deliveries.append(orphan); mangaStore.backup.records = [:]
        let beforeOrphan = TraktFixtureProtocol.requests.count
        await mangaStore.retry()
        check(TraktFixtureProtocol.requests.count == beforeOrphan && !mangaStore.backup.deliveries.contains(where:{ $0.id == orphan.id }),"An orphaned pending delivery never recreates a deleted remote entry")
        let art = CatalogAPI.tmdbArtwork(["seasons":[["season_number":2,"episode_count":12],["season_number":1,"episode_count":10]]])
        check(art.seasons.map(\.number) == [1,2] && art.seasons.map(\.episodeCount) == [10,12],"Season artwork metadata includes sorted episode totals for whole-work progress")
        var bannerWork = a; bannerWork.remoteID = String(Int.random(in:1_000_000_000...2_000_000_000)); bannerWork.backdrop = "https://example.com/banner.jpg"
        let beforeArtwork = TraktFixtureProtocol.requests.count
        _ = try await api.artwork(bannerWork)
        check(TraktFixtureProtocol.requests.count == beforeArtwork + 1,"An existing backdrop cannot skip the request for actual season metadata")
        await api.invalidateArtwork([bannerWork.id])
        whole.score = 8.3
        whole.viewingUnits?[1].score = nil
        check(whole.effectiveRating(for:seasonLink).score == 8.3,"Unrated season inherits the overall rating")
        whole.viewingUnits?[1].score = 7.1
        check(whole.effectiveRating(for:seasonLink).score == 7.1 && whole.effectiveRating(for:whole.platformLinks![0]).score == 8.3,"Season overrides apply only to that season association")
        whole.viewingUnits?[1].score = nil; whole.viewingUnits?[1].scoreCleared = true
        check(whole.ratingPayload(for:seasonLink).score == 8.3 && whole.ratingPayload(for:seasonLink).scoreCleared == false,"Clearing a season override restores overall inheritance")
        whole.score = nil; whole.scoreCleared = true
        check(whole.ratingPayload(for:seasonLink).scoreCleared == true,"Clearing the overall rating clears inherited remote ratings")
        var noMetadata = whole; noMetadata.viewingUnits = []
        check(noMetadata.ratingPayload().syncFields == [.rating],"Rating-only payload requires no season metadata")
        let resetStore = TrackingStore(directory:diagnosticsDirectory.appending(path:"reset"),api:api)
        var resetRecord = seasons; resetRecord.setPlatformAssociation(b); resetRecord.links["tmdb"] = a
        resetRecord.score = 9.2
        check(await resetStore.save(resetRecord),"Cache-reset fixture saves")
        resetStore.setTitle("旧手动标题",for:a)
        resetStore.backup.deliveries.append(Delivery(record:resetRecord,target:b,fields:[.rating]))
        let reset = try resetStore.clearWorkCache(from:b)
        check(reset.work.source == .anilist && reset.work.remoteID == b.remoteID && reset.links.isEmpty && reset.platformLinks?.isEmpty == true,"Cache reset returns to entry platform and forgets all associations")
        check(reset.work.overview.isEmpty && reset.work.image.isEmpty && reset.viewingUnits?.isEmpty == true,"Cache reset removes metadata and season definitions")
        check(reset.score == 9.2 && reset.retainedSeasonTracking?.first?.score == 7 && reset.retainedSeasonTracking?.first?.progress == 6,"Cache reset retains personal scores and progress outside season metadata")
        check(resetStore.backup.deliveries.isEmpty && resetStore.titleTranslation(a) == nil,"Cache reset removes pending deliveries and translated titles")
        var rehydrated = reset; rehydrated.ensureSeason(1,title:"New")
        check(rehydrated.viewingUnits?.first?.progress == 6 && rehydrated.viewingUnits?.first?.lastEpisode == nil,"Refetched season restores tracking without restoring stale episode totals")
        let reloaded = TrackingStore(directory:diagnosticsDirectory.appending(path:"reset"),api:api)
        check(reloaded.record(b).links.isEmpty && reloaded.record(b).retainedSeasonTracking?.isEmpty == false,"Cleared cache remains cleared after restarting")
        var emptyUnit = seasons.viewingUnits![0]; emptyUnit.markThrough(0)
        let zeroPayload = try seasons.unitPayload(emptyUnit,target:traktTarget)
        check(zeroPayload.episodeHistory == [] && zeroPayload.syncSeason == 1,"Trakt zero progress is a scoped reconciliation, not a failure")
        let detailed = editor.backup.deliveries.first { $0.fields == [.rating] }!
        check(detailed.attempts?.first?.contents.isEmpty == false && detailed.attempts?.first?.steps.isEmpty == false,"Sync attempts persist concrete values and request steps")
        TraktFixtureProtocol.reconciliation = true
        TraktFixtureProtocol.bodies = []
        for platform in [Catalog.anilist,.mal] {
            for missing in [1,7,13] {
                let target = Work(source:platform,remoteID:"12",kind:.tv,title:"Partial",episodeCount:12)
                var projection = TrackingRecord(work:a)
                projection.ensureSeason(1,title:"")
                projection.viewingUnits?[0].lastEpisode = 13
                let available = (1...13).filter { $0 != missing }
                let mapping = ContentMapping(tmdbID:a.remoteID,confirmed:true,seasons:[1],coverage:"partial",episodes:available.enumerated().map {
                    EpisodeCorrespondence(platformEpisodes:[$0.offset+1],tmdbEpisodes:[EpisodeAddress(season:1,number:$0.element)])
                },platformEpisodeCount:12,complete:false)
                projection.platformLinks = [PlatformAssociation(target:target,scope:.season,season:1,mapping:mapping)]
                let before = projection
                projection.viewingUnits?[0].markThrough(7)
                let projectionStore = TrackingStore(directory:diagnosticsDirectory.appending(path:"partial-\(platform.rawValue)-\(missing)"),api:api)
                check(await projectionStore.saveProgressChanges(projection,from:before),"\(platform.title) automatically syncs partial progress with missing canonical episode \(missing)")
                try await awaitDeliveries(projectionStore)
                let expected = available.filter { $0 <= 7 }.count
                if platform == .anilist {
                    check((TraktFixtureProtocol.bodies.last(where: { ($0["variables"] as? [String:Any])?["progress"] != nil })?["variables"] as? [String:Any])?["progress"] as? Int == expected,"AniList mutation submits only the projected matched progress")
                } else {
                    check(TraktFixtureProtocol.forms.last(where: { $0["num_watched_episodes"] != nil })?["num_watched_episodes"] == String(expected),"MyAnimeList PATCH submits only the projected matched progress")
                }
                check(projectionStore.backup.deliveries.last?.errorDetail == nil && projectionStore.backup.deliveries.last?.state == "已同步","\(platform.title) partial mapping is not blocked as incomplete")
                var emptyProjection = projectionStore.record(a)
                emptyProjection.platformLinks?[0].mapping?.episodes = []
                projectionStore.saveAssociations(emptyProjection)
                let beforeEmpty = emptyProjection
                emptyProjection.viewingUnits?[0].markThrough(9)
                let beforeZeroRequests = TraktFixtureProtocol.requests.count
                check(await projectionStore.saveProgressChanges(emptyProjection,from:beforeEmpty),"\(platform.title) zero mapping saves without error")
                try await awaitDeliveries(projectionStore)
                check(projectionStore.backup.deliveries.last?.state == "已跳过" && projectionStore.message == nil && projectionStore.deliveryErrorCount == 0 && TraktFixtureProtocol.requests.count == beforeZeroRequests,"\(platform.title) zero mapping logs skipped without an API request or error")
            }
        }
        let bgm = Work(source:.bangumi,remoteID:"55",kind:.tv,title:"Progress")
        for platform in [Catalog.anilist,.mal,.bangumi] {
            let target = Work(source:platform,remoteID:platform == .bangumi ? "55" : "12",kind:.tv,title:"Zero mapping")
            var zero = TrackingRecord(work:a,score:8)
            zero.ensureSeason(1,title:""); zero.viewingUnits?[0].lastEpisode = 13; zero.viewingUnits?[0].markThrough(13)
            zero.platformLinks = [PlatformAssociation(target:target,scope:.season,season:1,mapping:ContentMapping(tmdbID:a.remoteID,confirmed:true,seasons:[1]))]
            let fullStore = TrackingStore(directory:diagnosticsDirectory.appending(path:"full-zero-\(platform.rawValue)"),api:api)
            check(await fullStore.save(zero,synchronize:true),"\(platform.title) full synchronization skips zero episode mappings without failing")
            check(fullStore.backup.deliveries.contains { $0.target.id == target.id && $0.fields == [.progress,.status] && $0.state == "已跳过" } && fullStore.message == nil && fullStore.deliveryErrorCount == 0,"\(platform.title) full synchronization logs progress as skipped with no error")
            check(fullStore.backup.deliveries.contains { $0.target.id == target.id && $0.fields == [.rating] && $0.state == "已同步" },"\(platform.title) zero episode mappings leave rating synchronization active")
        }
        var rollback = TrackingRecord(work:bgm,progress:1); rollback.syncFields = [.progress]
        var steps: [SyncStep] = []
        try await api.save(rollback,to:bgm) { steps.append($0) }
        check(TraktFixtureProtocol.bodies.contains { $0["episode_id"] as? [Int] == [12,13] && $0["type"] as? Int == 0 },"Bangumi rollback unmarks watched episodes beyond the new progress")
        check(steps.allSatisfy { $0.status == 200 } && steps.last?.requestBody?.contains("episode_id") == true,"Detailed sync steps retain actual HTTP status and submitted values")
        func bangumiRows(_ count:Int, start:Int, local:Bool = true, watched:Int = 0) -> [[String:Any]] {
            (0..<count).map { index in
                var ep: [String:Any] = ["id":1000+index,"sort":start+index,"type":0,"subject_id":55]
                if local { ep["ep"] = index+1 }
                return ["type":index < watched ? 2 : 0,"episode":ep]
            }
        }
        for (start,total) in [(26,12),(38,12),(50,10),(60,16),(76,12)] {
            TraktFixtureProtocol.bangumiRows = bangumiRows(total,start:start)
            TraktFixtureProtocol.bodies = []
            var full = rollback; full.progress = total
            try await api.save(full,to:bgm)
            check(TraktFixtureProtocol.bodies.contains { $0["episode_id"] as? [Int] == Array(1000..<(1000+total)) && $0["type"] as? Int == 2 }, "Bangumi broadcast numbering \(start) maps complete local progress to real episode IDs")
        }
        TraktFixtureProtocol.bangumiRows = bangumiRows(12,start:76,watched:12).reversed()
        TraktFixtureProtocol.bangumiPageSize = 5
        TraktFixtureProtocol.bodies = []; TraktFixtureProtocol.requests = []
        var partial = rollback; partial.progress = 2
        try await api.save(partial,to:bgm)
        check(TraktFixtureProtocol.bodies.contains { $0["episode_id"] as? [Int] == Array(1002..<1012) && $0["type"] as? Int == 0 }, "Paginated out-of-order Bangumi chapters roll back by local episode number")
        check(TraktFixtureProtocol.requests.filter { $0.httpMethod == "GET" && $0.url?.path.hasSuffix("/55/episodes") == true }.count == 3, "Bangumi fetches every page before submitting progress")
        TraktFixtureProtocol.bangumiPageSize = 100
        TraktFixtureProtocol.bangumiRows = bangumiRows(10,start:50)
        var splitRecord = TrackingRecord(work:Work(source:.tmdb,remoteID:"1429",kind:.tv,title:"进击的巨人"))
        splitRecord.ensureSeason(3,title:"第三季")
        let seasonIndex = splitRecord.viewingUnits!.firstIndex { $0.season == 3 }!
        splitRecord.viewingUnits![seasonIndex].lastEpisode = 22
        splitRecord.viewingUnits![seasonIndex].markThrough(14)
        let partMapping = ContentMapping(tmdbID:"1429",confirmed:true,seasons:[3],coverage:"partial",episodes:(1...10).map {
            EpisodeCorrespondence(platformEpisodes:[$0],tmdbEpisodes:[EpisodeAddress(season:3,number:$0+12)])
        },platformEpisodeCount:10,complete:true)
        let splitAssociation = PlatformAssociation(target:bgm,scope:.season,season:3,mapping:partMapping)
        let splitPayload = try splitRecord.mappedPayload(splitAssociation)
        TraktFixtureProtocol.bodies = []
        try await api.save(splitPayload,to:bgm)
        check(splitPayload.progress == 2 && TraktFixtureProtocol.bodies.contains { $0["episode_id"] as? [Int] == [1000,1001] && $0["type"] as? Int == 2 }, "TMDB S03E14 projects through the existing split mapping to Bangumi Part 2's first two real IDs")
        var sparseMapping = partMapping
        sparseMapping.complete = false
        sparseMapping.episodes = [
            EpisodeCorrespondence(platformEpisodes:[2],tmdbEpisodes:[EpisodeAddress(season:3,number:13)]),
            EpisodeCorrespondence(platformEpisodes:[4],tmdbEpisodes:[EpisodeAddress(season:3,number:14)]),
            EpisodeCorrespondence(platformEpisodes:[5],tmdbEpisodes:[EpisodeAddress(season:3,number:15)])]
        var sparseAssociation = splitAssociation; sparseAssociation.mapping = sparseMapping
        TraktFixtureProtocol.bangumiRows = bangumiRows(10,start:50,watched:10)
        TraktFixtureProtocol.bodies = []
        let sparsePayload = try splitRecord.mappedPayload(sparseAssociation)
        try await api.save(sparsePayload,to:bgm)
        check(sparsePayload.progress == 4 && TraktFixtureProtocol.bodies.contains { $0["episode_id"] as? [Int] == [1004] && $0["type"] as? Int == 0 },"Partial Bangumi mapping skips holes and only clears the mapped unwatched chapter")
        check(!TraktFixtureProtocol.bodies.contains { body in (body["episode_id"] as? [Int] ?? []).contains(where:{ [1000,1002,1005,1006,1007,1008,1009].contains($0) }) },"Unmapped Bangumi chapters retain their remote watch state")
        TraktFixtureProtocol.bangumiRows = bangumiRows(10,start:50)
        TraktFixtureProtocol.bodies = []
        try await api.save(sparsePayload,to:bgm)
        check(TraktFixtureProtocol.bodies.contains { $0["episode_id"] as? [Int] == [1001,1003] && $0["type"] as? Int == 2 },"Partial Bangumi progress submits only the actual matched watched chapter IDs")
        TraktFixtureProtocol.bangumiPageSize = 100
        TraktFixtureProtocol.bangumiRows = bangumiRows(10,start:50,local:false)
        TraktFixtureProtocol.bodies = []
        try await api.save(partial,to:bgm)
        check(TraktFixtureProtocol.bodies.contains { $0["episode_id"] as? [Int] == [1000,1001] && $0["type"] as? Int == 2 }, "Legacy Bangumi tables without ep normalize broadcast order into local positions")
        TraktFixtureProtocol.bangumiRows = bangumiRows(3,start:26,watched:3)
        TraktFixtureProtocol.bodies = []; partial.progress = 0
        try await api.save(partial,to:bgm)
        check(TraktFixtureProtocol.bodies.contains { $0["episode_id"] as? [Int] == [1000,1001,1002] && $0["type"] as? Int == 0 }, "Zero progress clears the subject's watched chapters")
        for failure in ["duplicate", "truncated", "overflow", "subject", "missingID"] {
            var rows = bangumiRows(3,start:26)
            if failure == "duplicate" { rows[1] = rows[0] }
            if failure == "subject" { rows[0]["episode"] = ["id":1000,"sort":26,"subject_id":999] }
            if failure == "missingID" { rows[0]["episode"] = ["sort":26,"ep":1] }
            TraktFixtureProtocol.bangumiRows = rows; TraktFixtureProtocol.bangumiTruncated = failure == "truncated"
            TraktFixtureProtocol.requests = []; TraktFixtureProtocol.bodies = []
            var invalid = rollback; invalid.progress = failure == "overflow" ? 4 : 2; invalid.syncFields = [.progress,.status]
            do { try await api.save(invalid,to:bgm); preconditionFailure("Invalid Bangumi table accepted") }
            catch { check(!TraktFixtureProtocol.requests.contains { $0.httpMethod == "POST" || $0.httpMethod == "PATCH" }, "Bangumi \(failure) fails before any status or episode mutation") }
        }
        check(try BangumiEpisodeNumbering.orderedIDs([["id":2,"sort":10.5],["id":1,"sort":10.0]]) == [1,2], "Fractional broadcast numbers retain ordering without entering the local cursor")
        check(try BangumiEpisodeNumbering.orderedIDs([["id":2,"ep":27,"sort":27],["id":1,"ep":26,"sort":26]]) == [1,2], "Nonlocal ep values fall back to the complete broadcast order")
        for rows: [[String:Any]] in [[["id":1,"sort":26],["id":2,"sort":26]], [["id":1]], [["id":1,"sort":26,"type":1]]] {
            do { _ = try BangumiEpisodeNumbering.orderedIDs(rows); preconditionFailure("Ambiguous Bangumi chapters accepted") }
            catch { check(true,"Ambiguous or nonregular Bangumi chapter tables are rejected") }
        }
        TraktFixtureProtocol.bangumiRows = nil; TraktFixtureProtocol.bangumiTruncated = false
        TraktFixtureProtocol.bodies = []
        var rollbackUnit = seasons.viewingUnits![0]; rollbackUnit.markThrough(1)
        var traktRollback = try seasons.unitPayload(rollbackUnit,target:traktTarget); traktRollback.syncFields = [.progress]
        try await api.save(traktRollback,to:traktTarget)
        check(TraktFixtureProtocol.bodies.contains { $0["ids"] as? [Int] == [102] },"Trakt rollback deletes only excess records in the edited season")
        TraktFixtureProtocol.bodies = []
        let tmdbRating = TrackingRecord(work:a,score:8.3).ratingPayload()
        try await api.save(tmdbRating,to:a)
        check(TraktFixtureProtocol.bodies.last?["value"] as? Double == 8.5,"TMDB submission uses half-point rating steps")
        let clearRating = TrackingRecord(work:a,scoreCleared:true).ratingPayload()
        try await api.save(clearRating,to:a)
        check(TraktFixtureProtocol.requests.last?.httpMethod == "DELETE","Clearing TMDB rating calls the delete endpoint")
        let noSession = CatalogAPI(session:URLSession(configuration:configuration),credential:{ $0 == "tmdb.session" ? "" : "fixture" },diagnostics:DiagnosticLog(directory:diagnosticsDirectory))
        let beforeMissingSession = TraktFixtureProtocol.requests.count
        do { try await noSession.save(tmdbRating,to:a); preconditionFailure("Missing account session accepted") }
        catch { check(TraktFixtureProtocol.requests.count == beforeMissingSession && error.localizedDescription.contains("登录 TMDB"),"TMDB requires user authorization before rating writes") }
        TraktFixtureProtocol.failRating = true
        var failureSteps: [SyncStep] = []
        do { try await api.save(tmdbRating,to:a) { failureSteps.append($0) }; preconditionFailure("Remote failure accepted") }
        catch { check(failureSteps.last?.status == 503 && failureSteps.last?.error?.contains("503") == true,"Sync failure exposes HTTP status and error detail") }
        TraktFixtureProtocol.failRating = false
        let deletionStore = TrackingStore(directory:diagnosticsDirectory.appending(path:"deletion"),api:api)
        let deleteTrakt = Work(source:.trakt,remoteID:"42",kind:.tv,title:"Delete test")
        let deleteMAL = Work(source:.mal,remoteID:"43",kind:.tv,title:"Delete test")
        let deleteBangumi = Work(source:.bangumi,remoteID:"44",kind:.tv,title:"Delete test")
        var deletion = TrackingRecord(work:a,score:8,progress:3)
        deletion.links = ["trakt":deleteTrakt,"mal":deleteMAL,"bangumi":deleteBangumi]
        check(await deletionStore.save(deletion),"Deletion fixture saved")
        let localScore = deletionStore.record(a).score
        deletionStore.backup.deliveries.append(Delivery(record:deletion,target:deleteTrakt,state:"网络失败"))
        deletionStore.persist()
        TraktFixtureProtocol.requests = []
        try await deletionStore.deleteSourceRecord(TrackingRecord(work:deleteTrakt))
        check(!deletionStore.backup.deliveries.contains { $0.target.id == deleteTrakt.id },"Platform removal cancels queued writes for that target")
        let restoredDeletion = TrackingStore(directory:diagnosticsDirectory.appending(path:"deletion"),api:api)
        check(!restoredDeletion.backup.deliveries.contains { $0.target.id == deleteTrakt.id },"Removed platform writes stay removed after restart")
        check(deletionStore.record(a).score == localScore && deletionStore.isInLibrary(a),"Platform deletion retains local rating and membership")
        check(Set(TraktFixtureProtocol.requests.compactMap { $0.url?.path }) == Set(["/sync/watchlist/remove","/sync/collection/remove","/sync/ratings/remove","/sync/history/remove"]),"Trakt removal clears all four tracked categories")
        TraktFixtureProtocol.failRating = true
        do { try await deletionStore.removeEverywhere(deletion); preconditionFailure("Partial failure accepted") }
        catch { check(deletionStore.isInLibrary(a) && error.localizedDescription.contains("TMDB"),"Partial remote deletion retains local record and identifies failed platform") }
        TraktFixtureProtocol.failRating = false; TraktFixtureProtocol.requests = []
        try await deletionStore.removeEverywhere(deletion)
        check(!deletionStore.isInLibrary(a),"Successful retry removes local membership")
        check(!TraktFixtureProtocol.requests.contains { $0.url?.host == "api.bgm.tv" },"All-platform removal skips unsupported Bangumi")
        check(TraktFixtureProtocol.requests.contains { $0.url?.path == "/v2/anime/43/my_list_status" && $0.httpMethod == "DELETE" },"MAL deletion uses the list-status endpoint")
        var duplicateTargets = deletion; duplicateTargets.links["tmdb"] = a
        duplicateTargets.platformLinks = [PlatformAssociation(target:deleteMAL)]
        check(TrackingStore.removalTargets(duplicateTargets).filter { $0.id == deleteMAL.id }.count == 1,"All-platform target enumeration deduplicates associations")
        let replacement = Work(source:.tmdb,remoteID:"99",kind:.tv,title:"Correct match")
        let corrected = try LibraryIdentity.canonical(resetRecord,using:replacement)
        check(!corrected.relatedWorkIDs.contains(a.id) && corrected.relatedWorkIDs.contains(b.id),"Correcting TMDB identity preserves source association without aliasing the wrong TMDB work")
        check(corrected.viewingUnits?.isEmpty == true && corrected.retainedSeasonTracking?.isEmpty == false,"Correcting TMDB identity invalidates season metadata but keeps personal tracking")
        var absentOverall = whole; absentOverall.score = nil; absentOverall.scoreCleared = false
        absentOverall.viewingUnits?[1].score = nil
        check(absentOverall.ratingPayload(for:seasonLink).scoreCleared == true,"Removing the last season override clears the remote rating when no overall rating exists")
        let correctedStore = TrackingStore(directory:diagnosticsDirectory.appending(path:"corrected-reset"),api:api)
        check(await correctedStore.save(corrected),"Corrected identity fixture saves")
        let resetCorrected = try correctedStore.clearWorkCache(from:a,current:replacement)
        check(correctedStore.backup.records[replacement.id] == nil && resetCorrected.work.id == a.id && resetCorrected.score == corrected.score,"Reset after correcting a match clears the current record and fetches the original entry identity")
        var freshSource = TrackingRecord(work:b)
        freshSource.prepareUnits()
        check(freshSource.platformLinks?.first?.scope == .whole,"Opening a new non-TMDB entry defaults to whole work")
        var canonicalSource = try LibraryIdentity.canonical(freshSource,using:a)
        canonicalSource.ensureSeason(1,title:"第一季")
        canonicalSource.ensureSeason(0,title:"特别篇")
        for number in [1,0] {
            check(canonicalSource.platformRatingEntries(season:number).contains { $0.id == b.id && $0.scope == .whole },"Whole-work source rating is visible for regular seasons and specials")
        }
        let roundtripSource = try JSONDecoder().decode(TrackingRecord.self,from:JSONEncoder().encode(canonicalSource))
        check(roundtripSource.platformRatingEntries(season:0).contains { $0.id == b.id && $0.scope == .whole },"Whole-work scope survives serialization")
        var overrideSource = canonicalSource
        var overrideWork = b; overrideWork.remoteID = "season-override"
        overrideSource.platformLinks?.append(PlatformAssociation(target:overrideWork,scope:.season,season:1))
        check(overrideSource.platformRatingEntries(season:1).filter { $0.target.source == b.source }.map(\.id) == [overrideWork.id],"Explicit season entry takes precedence over whole-work entry on the same platform")
        check(overrideSource.platformRatingEntries(season:0).contains { $0.id == b.id },"Season override does not hide whole-work rating for specials")
        var mainRating = a; mainRating.rating = 8.2
        var firstSeasonRating = b; firstSeasonRating.rating = 7.8
        var secondSeasonRating = b; secondSeasonRating.remoteID = "22"; secondSeasonRating.rating = 9.1
        var specialRating = b; specialRating.remoteID = "23"; specialRating.rating = 7.4
        var publicRatings = TrackingRecord(work:mainRating,score:2,links:["tmdb":mainRating,"trakt":traktTarget,"anilist":firstSeasonRating])
        publicRatings.platformLinks = [PlatformAssociation(target:secondSeasonRating,scope:.season,season:2),PlatformAssociation(target:specialRating,scope:.season,season:0),PlatformAssociation(target:firstSeasonRating,scope:.season,season:1)]
        let allRatings = publicRatings.platformRatingEntries()
        check(allRatings.count == 5 && Set(allRatings.map(\.id)).count == 5,"Platform overview contains every linked entry without duplicating primary or compatibility links")
        check(allRatings.filter { $0.target.source == .anilist }.map(\.season) == [1,2,0],"Split-platform public ratings follow season order with specials last")
        check(!allRatings.contains { $0.target.source == .anilist && $0.scope == .whole },"A season compatibility link is never presented as a whole-series rating")
        let seasonTwoRatings = publicRatings.platformRatingEntries(season:2)
        check(seasonTwoRatings.filter { $0.target.source == .anilist }.count == 1 && seasonTwoRatings.first { $0.target.source == .anilist }?.target.publicRating == 9.1,"Selecting season two shows exactly its associated public score")
        check(seasonTwoRatings.first { $0.target.source == .anilist }?.target.catalogURL?.absoluteString == "https://anilist.co/anime/22","Season score links to the exact selected platform entry")
        check(publicRatings.platformRatingEntries(season:0).contains { $0.id == specialRating.id },"Specials have their own public ratings")
        check(publicRatings.platformRatingEntries(season:3).allSatisfy { $0.scope == .whole },"Unmapped seasons show only whole-work ratings, never another season rating")
        check(allRatings.contains { $0.id == secondSeasonRating.id },"Disabled synchronization never hides public platform ratings")
        check(allRatings.first?.target.publicRating == 8.2 && publicRatings.score == 2,"Public platform averages remain separate from personal ratings")
        var missingRating = firstSeasonRating; missingRating.rating = nil
        check(missingRating.publicRating == nil && missingRating.catalogURL != nil,"An unrated platform entry still has a usable detail link")
        missingRating.rating = 0
        check(missingRating.publicRating == nil,"Zero-vote score is shown as unavailable instead of zero stars")
        missingRating.rating = .nan
        check(missingRating.publicRating == nil,"Nonfinite public ratings are rejected")
        var freshRating = secondSeasonRating; freshRating.rating = 8.9; freshRating.url = "https://anilist.co/anime/22/refreshed"
        let beforeRatingRefresh = publicRatings
        publicRatings.applyPlatformRating(freshRating)
        check(publicRatings.platformRatingEntries(season:2).first { $0.target.source == .anilist }?.target.publicRating == 8.9 && !publicRatings.hasTrackingChanges(from:beforeRatingRefresh),"Public rating refresh updates the selected season without creating personal edits")
        check(publicRatings.platformLinks?.first?.season == 2,"Public rating refresh preserves binding scope")
        let ratingsStore = TrackingStore(directory:diagnosticsDirectory.appending(path:"public-ratings"),api:api)
        check(await ratingsStore.save(beforeRatingRefresh),"Public rating persistence fixture saves")
        let ratingModifiedAt = ratingsStore.record(mainRating).modifiedAt
        await ratingsStore.cachePlatformRating(freshRating,for:mainRating)
        check(ratingsStore.record(mainRating).platformRatingEntries(season:2).first { $0.id == secondSeasonRating.id }?.target.publicRating == 8.9 && ratingsStore.record(mainRating).modifiedAt == ratingModifiedAt && ratingsStore.backup.deliveries.isEmpty,"Caching public ratings preserves library dates and never queues synchronization")
        let restoredRatings = TrackingStore(directory:diagnosticsDirectory.appending(path:"public-ratings"),api:api)
        check(restoredRatings.record(mainRating).platformRatingEntries(season:2).first { $0.id == secondSeasonRating.id }?.target.publicRating == 8.9,"Refreshed platform scores survive reopening from home")
        var removedRating = ratingsStore.record(mainRating); removedRating.platformLinks?.removeAll { $0.id == secondSeasonRating.id }
        ratingsStore.saveAssociations(removedRating); await ratingsStore.cachePlatformRating(freshRating,for:mainRating)
        check(!ratingsStore.record(mainRating).platformRatingEntries().contains { $0.id == secondSeasonRating.id },"Late rating responses never restore removed associations")
        print("\(count) tracking checks passed.")
    }
}

final class TraktFixtureProtocol: URLProtocol, @unchecked Sendable {
    static var historyFailure:Error?
    static var requests: [URLRequest] = []
    static var bodies: [[String:Any]] = []
    static var forms: [[String:String]] = []
    static var reconciliation = false
    static var failRating = false
    static var bangumiRows: [[String:Any]]?
    static var bangumiPageSize = 100
    static var bangumiTruncated = false
    override class func canInit(with request:URLRequest) -> Bool { true }
    override class func canonicalRequest(for request:URLRequest) -> URLRequest { request }
    override func startLoading() {
        if request.url?.path == "/sync/history", let error = Self.historyFailure {
            client?.urlProtocol(self,didFailWithError:error)
            return
        }
        Self.requests.append(request)
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating:0,count:4096)
            while stream.hasBytesAvailable { let count = stream.read(&buffer,maxLength:buffer.count); if count <= 0 { break }; body.append(buffer,count:count) }
        }
        Self.bodies.append((try? JSONSerialization.jsonObject(with:body)) as? [String:Any] ?? [:])
        if request.value(forHTTPHeaderField:"Content-Type")?.contains("application/x-www-form-urlencoded") == true {
            var form = URLComponents(); form.percentEncodedQuery = String(decoding:body,as:UTF8.self)
            Self.forms.append(Dictionary(uniqueKeysWithValues:(form.queryItems ?? []).map { ($0.name,$0.value ?? "") }))
        }
        let url = request.url!
        let page = URLComponents(url:url,resolvingAgainstBaseURL:false)?.queryItems?.first { $0.name == "page" }?.value
        func media(_ id:Int) -> [String:Any] { ["title":"Movie \(id)","ids":["trakt":id],"images":["poster":["cdn.trakt.tv/\(id).webp"]]] }
        var object: Any?
        var rows: [[String:Any]] = []
        var pageCount = "1"
        switch url.path {
        case "/sync/watched/movies":
            pageCount = "2"
            rows = [["movie":media(page == "2" ? 2 : 1),"plays":1]]
        case "/sync/ratings/movies": rows = [["movie":media(1),"rating":9],["movie":media(3),"rating":7]]
        case "/sync/history": rows = [["id":100,"show":media(42),"episode":["season":2,"number":4]]]
        case "/v0/users/-/collections/55/episodes":
            if request.httpMethod == "GET" {
                let all = Self.bangumiRows ?? (1...3).map { ["type":2,"episode":["id":10+$0,"sort":$0]] }
                let offset = Int(URLComponents(url:url,resolvingAgainstBaseURL:false)?.queryItems?.first { $0.name == "offset" }?.value ?? "0") ?? 0
                object = ["total":all.count + (Self.bangumiTruncated ? 1 : 0),"data":Array(all.dropFirst(offset).prefix(Self.bangumiPageSize))]
            } else { object = [:] }
        case "/sync/history/shows/42":
            if Self.reconciliation { rows = [["id":101,"episode":["season":1,"number":1]],["id":102,"episode":["season":1,"number":2]],["id":901,"episode":["season":9,"number":1]]] }
        default: break
        }
        let response = HTTPURLResponse(url:url,statusCode:url.path == "/unauthorized" ? 401 : Self.failRating && url.path.hasSuffix("/rating") ? 503 : 200,httpVersion:nil,headerFields:["X-Pagination-Page-Count":pageCount,"X-Pagination-Limit":"1"])!
        client?.urlProtocol(self,didReceive:response,cacheStoragePolicy:.notAllowed)
        client?.urlProtocol(self,didLoad:try! JSONSerialization.data(withJSONObject:object ?? rows))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class AccountFixtureProtocol: URLProtocol, @unchecked Sendable {
    static var status = 200
    static var requests = 0
    override class func canInit(with request:URLRequest) -> Bool { true }
    override class func canonicalRequest(for request:URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests += 1
        let url = request.url!
        let user:[String:Any] = ["username":"fixture-user","name":"fixture-user"]
        let object:[String:Any] = url.path == "/users/settings" ? ["user":user] : url.path == "/3/authentication" ? ["success":true] : user
        client?.urlProtocol(self,didReceive:HTTPURLResponse(url:url,statusCode:Self.status,httpVersion:nil,headerFields:nil)!,cacheStoragePolicy:.notAllowed)
        client?.urlProtocol(self,didLoad:try! JSONSerialization.data(withJSONObject:object))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
