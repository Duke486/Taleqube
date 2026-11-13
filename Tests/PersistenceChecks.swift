import Foundation

@main struct PersistenceChecks {
    @MainActor static func main() async throws {
        var count = 0
        func check(_ value:Bool,_ label:String) { precondition(value,label); count += 1; print("PASS: \(label)") }
        let directory = FileManager.default.temporaryDirectory.appending(path:UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:directory) }
        let api = CatalogAPI(credential:{ _ in "" },diagnostics:DiagnosticLog(directory:directory.appending(path:"diagnostics")))
        let noEntryDirectory = directory.appending(path:"no-entry")
        let noEntryStore = TrackingStore(directory:noEntryDirectory,api:api)
        let book = Work(source:.anilist,remoteID:"book",kind:.manga,title:"Book")
        let bookRecord = TrackingRecord(work:book)
        check(bookRecord.matchingPlatforms.count == 3 && !bookRecord.needsMatching(.tmdb) && !bookRecord.needsMatching(.trakt),"Book inspection considers only three book platforms")
        check(!bookRecord.needsMatching(.anilist) && bookRecord.needsMatching(.mal),"Inspection recognizes the source platform and missing associations")
        check(bookRecord.needsMatching(.mal),"Missing platform remains unmatched")
        try noEntryStore.admit(bookRecord,using:book)
        let pendingBook = Work(source:.mal,remoteID:"pending",kind:.manga,title:"Book")
        noEntryStore.backup.deliveries.append(Delivery(record:bookRecord,target:pendingBook))
        check(noEntryStore.persist(),"Pending delivery fixture persists")
        noEntryStore.setNoEntry([book.id],platform:.mal)
        check(noEntryStore.backup.deliveries.isEmpty,"Batch no-entry removes pending platform deliveries")
        let noEntryReopened = TrackingStore(directory:noEntryDirectory,api:api)
        check(noEntryReopened.record(book).hasNoEntry(.mal) && !noEntryReopened.record(book).needsMatching(.mal) && !noEntryReopened.record(book).isPlatformEnabled(.mal),"Batch no-entry survives reopening, completes inspection and disables sync")
        check(!noEntryReopened.record(book).shouldAttemptMatching(.mal) && noEntryReopened.record(book).shouldAttemptMatching(.mal,explicitRetry:true),"Only explicit platform retry bypasses no-entry")
        var staleBook = bookRecord
        staleBook.restoreAssociations(from:noEntryReopened.record(book))
        check(staleBook.hasNoEntry(.mal),"Stale progress drafts inherit current no-entry decisions")
        var markedBook = noEntryReopened.record(book)
        markedBook.setNoEntry(.bangumi)
        check(!markedBook.matchingPlatforms.contains(where:markedBook.needsMatching),"All three book platforms can be resolved without movie platforms")
        let encodedNoEntry = try JSONEncoder().encode(markedBook)
        let decodedNoEntry = try JSONDecoder().decode(TrackingRecord.self,from:encodedNoEntry)
        check(decodedNoEntry.hasNoEntry(.bangumi),"No-entry survives backup encoding")
        let malBook = Work(source:.mal,remoteID:"book",kind:.manga,title:"Book")
        _ = markedBook.setPlatformAssociation(malBook)
        check(!markedBook.hasNoEntry(.mal) && markedBook.isPlatformEnabled(.mal),"Successful explicit reassociation restores platform sync")
        let external = Work(source:.bangumi,remoteID:"external",kind:.movie,title:"External")
        for platform in [Catalog.tmdb,.trakt] {
            var inspection = TrackingRecord(work:Work(source:platform,remoteID:"inspection",kind:.tv,title:"Inspection"))
            check(!inspection.needsMatching(platform),"Source platform counts as linked before no-entry")
            for resolvedPlatform in inspection.matchingPlatforms { inspection.setNoEntry(resolvedPlatform) }
            let reopened = try JSONDecoder().decode(TrackingRecord.self,from:JSONEncoder().encode(inspection))
            check(!reopened.needsMatching(platform) && !reopened.matchingPlatforms.contains(where:reopened.needsMatching),"TMDB/Trakt no-entry completes platform and any-platform inspection")
            check(!reopened.shouldAttemptMatching(platform) && !reopened.isPlatformEnabled(platform),"Inspection does not restart matching or enable sync for no-entry")
        }
        var noEntryExternalRecord = TrackingRecord(work:external); noEntryExternalRecord.setNoEntry(.mal)
        noEntryStore.saveAssociations(noEntryExternalRecord)
        check(TrackingStore(directory:noEntryDirectory,api:api).record(external).hasNoEntry(.mal),"Non-library association cache persists no-entry")
        let unchangedDirectory = directory.appending(path:"unchanged")
        let unchanged = TrackingStore(directory:unchangedDirectory,api:api)
        check(unchanged.persist(),"Initial empty library commit succeeds")
        let unchangedDB = try LibraryDatabase(directory:unchangedDirectory)
        let unchangedRoots = try unchangedDB.archiveRows().roots
        check(unchanged.persist(),"Unchanged library commit succeeds")
        check(try unchangedDB.archiveRows().roots == unchangedRoots,"Unchanged commits preserve every content root")
        check(!FileManager.default.fileExists(atPath:unchangedDirectory.appending(path:"tracking-v1.json").path),"New installs never create legacy JSON")
        let tmdb = Work(source:.tmdb,remoteID:"77",kind:.tv,title:"Series")
        let ani = Work(source:.anilist,remoteID:"88",kind:.tv,title:"Series")
        let mal = Work(source:.mal,remoteID:"99",kind:.tv,title:"Series")
        var noEntryTV = TrackingRecord(work:tmdb)
        noEntryTV.setNoEntry(.mal); noEntryTV.setNoEntry(.bangumi)
        noEntryTV.applyMatching([],platform:.mal,replace:false)
        check(noEntryTV.hasNoEntry(.mal),"Empty matching result preserves explicit no-entry")
        noEntryTV.applyMatching([PlatformAssociation(target:mal)],platform:.mal,replace:false)
        noEntryTV.prepareUnits()
        check(!noEntryTV.hasNoEntry(.mal) && noEntryTV.platformLinks?.contains(where:{ $0.id == mal.id }) == true,"Season reassociation immediately clears no-entry and survives unit preparation")
        check(noEntryTV.hasNoEntry(.bangumi),"Reassociation preserves other platforms' no-entry states")
        var manualTV = TrackingRecord(work:tmdb); manualTV.setNoEntry(.mal)
        _ = manualTV.setPlatformAssociation(mal)
        manualTV.prepareUnits()
        check(!manualTV.hasNoEntry(.mal) && manualTV.isPlatformEnabled(.mal),"Manual TV reassociation clears explicit no-entry")
        var canonicalTV = TrackingRecord(work:ani); canonicalTV.setNoEntry(.tmdb)
        canonicalTV = try LibraryIdentity.canonical(canonicalTV,using:tmdb)
        check(!canonicalTV.hasNoEntry(.tmdb) && canonicalTV.links["tmdb"]?.id == tmdb.id,"Canonical TMDB association clears explicit no-entry")
        var importTV = TrackingRecord(work:tmdb); importTV.setNoEntry(.mal)
        var importedTV = TrackingRecord(work:tmdb); _ = importedTV.setPlatformAssociation(mal)
        importTV = LibraryIdentity.mergeImport(importedTV,existing:importTV)
        importTV.prepareUnits()
        check(!importTV.hasNoEntry(.mal) && importTV.isPlatformEnabled(.mal),"Imported association clears explicit no-entry and remains linked")
        let restoredTV = try JSONDecoder().decode(TrackingRecord.self,from:JSONEncoder().encode(noEntryTV))
        check(!restoredTV.hasNoEntry(.mal) && restoredTV.hasNoEntry(.bangumi),"Reassociated and untouched platform states survive persistence")
        let store = TrackingStore(directory:directory,api:api)
        var source = TrackingRecord(work:ani)
        source.links = ["anilist":ani,"tmdb":tmdb]; source.prepareUnits()
        store.saveAssociations(source)
        let canonical = try LibraryIdentity.canonical(source,using:tmdb)
        check(store.record(tmdb).platformLinks?.contains(where:{ $0.id == ani.id }) == true,"Pre-import association follows the canonical platform identity")
        var next = canonical
        _ = next.setPlatformAssociation(mal)
        store.saveAssociations(next)
        let reopened = TrackingStore(directory:directory,api:api)
        check(reopened.record(tmdb).platformLinks?.count == 2 && reopened.record(ani).platformLinks?.count == 2,"Both platform entry points recover the latest associations after restart")
        check(reopened.backup.records.isEmpty,"Association persistence does not admit the work")

        next.ensureSeason(1,title:"Season 1")
        try store.admit(next,using:tmdb)
        var edited = store.record(tmdb)
        edited.score = 8
        edited.viewingUnits?[0].markThrough(3)
        var removed = store.record(tmdb)
        removed.platformLinks?.removeAll { $0.id == mal.id }; removed.links["mal"] = nil
        store.saveAssociations(removed)

        check(await store.saveProgressChanges(edited,from:next),"Progress from an already open editor saves after association changes")
        check(store.record(tmdb).platformLinks?.contains(where:{ $0.id == mal.id }) == false,"Saving stale editor progress cannot restore removed links")

        let identityStore = TrackingStore(directory:directory.appending(path:"identity"),api:api)
        var externalRecord = TrackingRecord(work:ani)
        externalRecord.links = ["anilist":ani,"tmdb":tmdb]
        identityStore.saveAssociations(externalRecord)
        try identityStore.admit(TrackingRecord(work:tmdb),using:tmdb)
        check(identityStore.isInLibrary(ani),"Cached canonical identity excludes a separate platform entry from imports")
        let sharedID = Work(source:.trakt,remoteID:"other",kind:.tv,title:"Series",tmdbID:77)
        check(identityStore.isInLibrary(sharedID),"Platform-provided TMDB ID also resolves an imported canonical work")
        var indexed = identityStore.record(tmdb)
        let extra = Work(source:.mal,remoteID:"extra",kind:.tv,title:"Series")
        _ = indexed.setPlatformAssociation(extra)
        identityStore.saveAssociations(indexed)
        check(identityStore.isInLibrary(extra),"Library identity index invalidates after association edits")
        var snapshot = TrackingRecord(work:Work(source:.mal,remoteID:"snapshot",kind:.tv,title:"Series"))
        snapshot.links["tmdb"] = tmdb
        identityStore.library["mal"] = [snapshot]
        check(identityStore.isInLibrary(snapshot.work),"Platform snapshot associations use the same imported identity lookup")
        identityStore.library["mal"] = []
        check(!identityStore.isInLibrary(snapshot.work),"Replacing a platform snapshot invalidates its lookup index")
        let artworkDirectory = directory.appending(path:"artwork")
        let artworkCache = ArtworkMetadataCache(directory:artworkDirectory)
        await artworkCache.store(MediaArtwork(images:[GalleryImage(url:"https://example.com/backdrop",caption:"Hero")],seasons:[MediaSeason(number:1,title:"S1",episodeCount:12)]),for:tmdb.id)
        let reopenedArtwork = ArtworkMetadataCache(directory:artworkDirectory)
        let cachedArtwork = await reopenedArtwork.value(for:tmdb.id)
        check(cachedArtwork?.images.first?.url == "https://example.com/backdrop" && cachedArtwork?.seasons.first?.episodeCount == 12,"Backdrop address and season metadata survive cache restart")
        await reopenedArtwork.remove([tmdb.id])
        let removedArtwork = await ArtworkMetadataCache(directory:artworkDirectory).value(for:tmdb.id)
        check(removedArtwork == nil,"Artwork invalidation clears both disk and memory")

        let artworkConfiguration = URLSessionConfiguration.ephemeral
        artworkConfiguration.protocolClasses = [ArtworkFixture.self]
        let artworkAPI = CatalogAPI(session:URLSession(configuration:artworkConfiguration),credential:{ _ in "fixture" },diagnostics:DiagnosticLog(directory:directory.appending(path:"artwork-log")))
        let artworkWork = Work(source:.tmdb,remoteID:UUID().uuidString,kind:.tv,title:"Cached hero")
        async let firstArtwork = artworkAPI.artwork(artworkWork)
        async let secondArtwork = artworkAPI.artwork(artworkWork)
        let (one,two) = try await (firstArtwork,secondArtwork)
        check(one.images == two.images && ArtworkFixture.requests == 1,"Concurrent hero requests share one metadata fetch")
        _ = try await artworkAPI.artwork(artworkWork)
        check(ArtworkFixture.requests == 1,"Reopening a hero uses metadata without a network request")
        await artworkAPI.invalidateArtwork([artworkWork.id])
        _ = try await artworkAPI.artwork(artworkWork)
        check(ArtworkFixture.requests == 2,"Explicit artwork reset forces a fresh metadata fetch")
        await artworkAPI.invalidateArtwork([artworkWork.id])

        do {
        // Parent status is independent of the season whose editor happens to be open.
        let summaryDirectory = directory.appending(path:"season-summary")
        let summaryStore = TrackingStore(directory:summaryDirectory,api:api)
        var summary = TrackingRecord(work:tmdb,viewingUnits:[],platformLinks:[])
        for number in 0...4 { summary.ensureSeason(number,title:"Season \(number)") }
        func seasonIndex(_ number:Int,in record:TrackingRecord) -> Int { record.viewingUnits!.firstIndex { $0.season == number }! }
        let first = seasonIndex(1,in:summary), second = seasonIndex(2,in:summary), special = seasonIndex(0,in:summary)
        summary.viewingUnits?[first].lastEpisode = 12
        summary.viewingUnits?[first].markThrough(12)
        summary.viewingUnits?[special].setStatus("重温中")
        check(summary.aggregatedSeasonStatus == "已完成","Completed regular seasons ignore unmarked future seasons and rewatching specials")
        summary.viewingUnits?[second].lastEpisode = 12
        summary.viewingUnits?[second].markThrough(3)
        check(summary.aggregatedSeasonStatus == "进行中","An active regular season outranks completed seasons")
        check(await summaryStore.save(summary,unitID:"season:1"),"Multi-season progress saves while a completed season is open")
        let summaryReopened = TrackingStore(directory:summaryDirectory,api:api)
        let durable = summaryReopened.record(tmdb)
        check(durable.status == "进行中" && durable.viewingUnits?[second].progress == 3,"Restart restores season progress and aggregate status, not the last-opened season")
        check(durable.viewingUnits?[first].trackingMarked == true && durable.viewingUnits?[seasonIndex(3,in:durable)].trackingMarked == false,"Explicit and untouched season markers survive disk round trip")
        var ranking = durable
        ranking.viewingUnits?[first].setStatus("重温中")
        check(ranking.aggregatedSeasonStatus == "重温中","Rewatch outranks watching")
        ranking.viewingUnits?[first].setStatus("已完成")
        ranking.viewingUnits?[second].setStatus("计划中")
        check(ranking.aggregatedSeasonStatus == "计划中","An explicitly planned season outranks completed seasons")
        let third = seasonIndex(3,in:ranking)
        ranking.viewingUnits?[third].setStatus("已暂停",at:Date(timeIntervalSince1970:10))
        check(ranking.aggregatedSeasonStatus == "计划中","Plan outranks pause")
        ranking.viewingUnits?[second].setStatus("已放弃",at:Date(timeIntervalSince1970:20))
        check(ranking.aggregatedSeasonStatus == "已放弃","Equal-priority pause and drop use the most recent explicit mark")
        ranking.viewingUnits?[third].setStatus("已暂停",at:Date(timeIntervalSince1970:30))
        check(ranking.aggregatedSeasonStatus == "已放弃" && ranking.viewingUnits?[third].trackingUpdatedAt == Date(timeIntervalSince1970:10),"Repeated pause preserves timestamp and equal-priority aggregate status")
        ranking.viewingUnits?[third].setStatus("已完成",at:Date(timeIntervalSince1970:31))
        ranking.viewingUnits?[third].setStatus("已暂停",at:Date(timeIntervalSince1970:32))
        check(ranking.aggregatedSeasonStatus == "已暂停","A genuine newer pause wins a same-priority drop")
        ranking.viewingUnits?[second].setStatus("已完成")
        ranking.viewingUnits?[third].setStatus("已完成")
        check(ranking.aggregatedSeasonStatus == "已完成","Only completed marked seasons produce completed main status")
        var metadata = UnitAssociation(ranking.viewingUnits![first])
        check(metadata.unit.trackingMarked == false,"Metadata association snapshots do not mark a season as watched")
        metadata = UnitAssociation(durable.viewingUnits![second])
        let restoredTracking = metadata.applying(to:durable.viewingUnits![second])
        check(restoredTracking.trackingMarked == true && restoredTracking.progress == 3,"Association reconciliation preserves locally marked watch progress")
        var fresh = TrackingRecord(work:tmdb); fresh.prepareUnits()
        check(fresh.aggregatedSeasonStatus == nil,"Opening a fresh TMDB work does not implicitly mark its first season")
        var planned = fresh
        planned.viewingUnits?[0].setStatus("计划中")
        check(planned.hasTrackingChanges(from:fresh),"Explicitly choosing plan is a persistable edit even at zero progress")
        var unmarkedPlan = fresh
        unmarkedPlan.ensureSeason(2,title:"Second season")
        var explicitPlan = unmarkedPlan
        let plannedIndex = seasonIndex(2,in:explicitPlan)
        explicitPlan.viewingUnits?[plannedIndex].setStatus("计划中")
        check(explicitPlan.hasTrackingChanges(from:unmarkedPlan) && explicitPlan.viewingUnits?[plannedIndex].progressState != unmarkedPlan.viewingUnits?[plannedIndex].progressState,"Marking an untouched planned season changes both persistence and sync state")
        var legacyObject = try JSONSerialization.jsonObject(with:JSONEncoder().encode(durable)) as! [String:Any]
        var legacyUnits = legacyObject["viewingUnits"] as! [[String:Any]]
        for index in legacyUnits.indices { legacyUnits[index].removeValue(forKey:"trackingMarked"); legacyUnits[index].removeValue(forKey:"trackingUpdatedAt") }
        legacyObject["viewingUnits"] = legacyUnits
        let legacySummary = try JSONDecoder().decode(TrackingRecord.self,from:JSONSerialization.data(withJSONObject:legacyObject))
        check(legacySummary.aggregatedSeasonStatus == "进行中","Legacy backups infer watched seasons and ignore untouched planned metadata")

        let retargeted = try LibraryIdentity.canonical(ranking,using:Work(source:.tmdb,remoteID:"retarget",kind:.tv,title:"Corrected series"))
        check(retargeted.retainedSeasonTracking?.first(where:{ $0.season == 4 })?.trackingMarked == false && retargeted.aggregatedSeasonStatus == "已完成","Changing the TMDB identity preserves marked and unmarked season tracking")
        summaryReopened.updateStatus([tmdb.id],to:"已暂停")
        let quickState = TrackingStore(directory:summaryDirectory,api:api).record(tmdb)
        check(quickState.status == "已暂停" && quickState.viewingUnits?[first].status == "已暂停" && quickState.viewingUnits?[second].status == "已暂停","Poster status actions persist consistently with tracked season aggregation")
        check(quickState.viewingUnits?[special].status == "重温中" && quickState.viewingUnits?[seasonIndex(4,in:quickState)].trackingMarked == false,"Poster status changes leave specials and unmarked future seasons alone")
        }

        let corruptDirectory = directory.appending(path:"corrupt")
        try FileManager.default.createDirectory(at:corruptDirectory,withIntermediateDirectories:true)
        let corruptFile = corruptDirectory.appending(path:LibraryDatabase.filename)
        let damaged = Data("{broken".utf8)
        try damaged.write(to:corruptFile)
        let corrupt = TrackingStore(directory:corruptDirectory,api:api)
        check(corrupt.message != nil,"Unreadable library surfaces an error")
        check(await corrupt.save(TrackingRecord(work:tmdb)) == false && corrupt.backup.records.isEmpty,"Unreadable library rejects saves and rolls back memory")
        check(try Data(contentsOf:corruptFile) == damaged,"Unreadable library bytes are never overwritten by empty state")
        do { _ = try corrupt.exportApplicationData(credentials:[:]); preconditionFailure("Exported unreadable library") } catch { check(true,"Unreadable library cannot be exported as a successful empty backup") }

        let failedDirectory = directory.appending(path:"failed")
        let failure = TrackingStore(directory:failedDirectory,api:api)
        check(await failure.save(TrackingRecord(work:tmdb,score:6)),"Failure fixture saves")
        let failedDB = try LibraryDatabase(directory:failedDirectory)
        try failedDB.execute("CREATE TRIGGER reject_update BEFORE UPDATE ON roots BEGIN SELECT RAISE(ABORT,'injected write failure'); END")
        try failedDB.execute("CREATE TRIGGER reject_delete BEFORE DELETE ON roots BEGIN SELECT RAISE(ABORT,'injected write failure'); END")
        var invalid = failure.record(tmdb); invalid.score = 10
        check(await failure.save(invalid) == false && failure.record(tmdb).score == 6,"Failed progress writes restore the committed record")
        failure.updateStatus([tmdb.id],to:"已完成")
        check(failure.record(tmdb).status != "已完成","Failed status writes restore the committed status")
        failure.deleteRecords([tmdb.id])
        check(failure.isInLibrary(tmdb),"Failed deletion preserves the committed library record")
        try failedDB.execute("DROP TRIGGER reject_update"); try failedDB.execute("DROP TRIGGER reject_delete")

        let concurrentDirectory = directory.appending(path:"concurrent")
        let first = TrackingStore(directory:concurrentDirectory,api:api)
        let second = TrackingStore(directory:concurrentDirectory,api:api)
        check(await first.save(TrackingRecord(work:tmdb,score:8)),"First writer commits")
        check(await second.save(TrackingRecord(work:tmdb,score:2)) == false,"Stale writer cannot overwrite another store's changes")
        check(TrackingStore(directory:concurrentDirectory,api:api).record(tmdb).score == 8,"Concurrent change rejection preserves disk data")

        let archive = try first.exportApplicationData(credentials:["anilist.token":"new-token"])
        let targetDirectory = directory.appending(path:"import")
        let target = TrackingStore(directory:targetDirectory,api:api)
        check(await target.save(TrackingRecord(work:tmdb,score:4)),"Import target saves")
        let targetDB = try LibraryDatabase(directory:targetDirectory)
        let beforeImport = try targetDB.archiveRows().roots
        var credentials = Dictionary(uniqueKeysWithValues:Credentials.names.map { ($0,"old-" + $0) })
        let oldCredentials = credentials
        var injected = false
        do {
            try target.importApplicationData(archive,readCredential:{ credentials[$0] ?? "" },writeCredential:{ values in
                credentials.merge(values) { _,new in new }
                if values["anilist.token"] != nil && !injected { injected = true; throw APIError.message("Injected credential failure") }
            })
            preconditionFailure("Accepted failing import")
        } catch { check(true,"Credential failure aborts full archive import") }
        check(Credentials.names.allSatisfy { credentials[$0] == oldCredentials[$0] },"Failed import restores every changed credential")
        check(try targetDB.archiveRows().roots == beforeImport && target.record(tmdb).score == 4,"Failed import restores the original file and published state")
        check(!FileManager.default.fileExists(atPath:targetDirectory.appending(path:"platform-library.json").path),"Failed import removes newly created auxiliary files")
        do {
            try target.importApplicationData(archive,readCredential:{ _ in throw APIError.message("Keychain locked") },writeCredential:{ _ in preconditionFailure("Wrote unreadable credentials") })
            preconditionFailure("Imported with unreadable credentials")
        } catch { check(try targetDB.archiveRows().roots == beforeImport,"Unreadable credentials stop import before changing files") }
        try target.importApplicationData(archive,readCredential:{ credentials[$0] ?? "" },writeCredential:{ credentials.merge($0) { _,new in new } })
        check(target.record(tmdb).score == 8 && TrackingStore(directory:targetDirectory,api:api).record(tmdb).score == 8,"Full archive publishes and persists only after all writes succeed")
        print("\(count) persistence checks passed.")
    }
}

private final class ArtworkFixture: URLProtocol {
    static var requests = 0
    override class func canInit(with request:URLRequest) -> Bool { true }
    override class func canonicalRequest(for request:URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests += 1
        let data = Data(#"{"backdrop_path":"/hero.jpg","seasons":[{"season_number":1,"name":"Season 1","episode_count":12}]}"#.utf8)
        client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:nil)!,cacheStoragePolicy:.notAllowed)
        client?.urlProtocol(self,didLoad:data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
