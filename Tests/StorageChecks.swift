import Foundation

@main struct StorageChecks {
    @MainActor static func main() async throws {
        setbuf(stdout,nil)
        var count = 0
        func check(_ value:Bool,_ label:String) { precondition(value,label); count += 1; print("PASS: \(label)") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let source = root.appendingPathComponent("legacy")
        try FileManager.default.createDirectory(at:source,withIntermediateDirectories:true)
        let diagnostic = DiagnosticLog(directory:root.appendingPathComponent("diagnostic"))
        let api = CatalogAPI(credential:{ _ in "" },diagnostics:diagnostic)
        let primary = Work(source:.tmdb,remoteID:"42",kind:.tv,title:"Local title",overview:"Local TMDB overview")
        let platform = Work(source:.anilist,remoteID:"77",kind:.tv,title:"Platform title")
        let groups = (1...24).map { EpisodeCorrespondence(platformEpisodes:[$0],tmdbEpisodes:[EpisodeAddress(season:1,number:$0)],evidenceIDs:["season"]) }
        let evidence = MappingEvidence(id:"season",title:"Season evidence",url:"https://example.org",text:String(repeating:"Episode title and overview. ",count:2000))
        var record = TrackingRecord(work:primary,score:8)
        record.links["tmdb"] = primary; record.links["anilist"] = platform
        record.platformLinks = [PlatformAssociation(target:platform,mapping:ContentMapping(tmdbID:"42",confirmed:true,seasons:[1],coverage:"full",episodes:groups,platformEpisodeCount:24,complete:true,manual:true,evidence:[evidence]))]
        record.prepareUnits()
        var backup = Backup(); backup.records[primary.id] = record
        backup.deliveries = (0..<8).map { _ in Delivery(record:record,target:platform,state:"已同步") }
        let snapshot = LibrarySnapshot(credential:"fingerprint",records:[TrackingRecord(work:platform)])
        let db = try LibraryDatabase(directory:source)
        try db.saveBackup(backup,previous:nil)
        try db.saveSnapshots(["anilist":snapshot])
        check(try db.loadBackup()?.records == backup.records,"Every record and manual mapping round-trips exactly")
        check(try db.loadBackup()?.deliveries == backup.deliveries,"Completed sync history retains complete historical semantics")
        check(try db.loadSnapshots()["anilist"] == snapshot,"Platform snapshots survive migration")
        let rows = try db.archiveRows()
        let evidenceNodes = rows.nodes.filter { $0[1].contains("Episode title and overview") }
        check(evidenceNodes.count == 1,"Eight deliveries, live record share one evidence body")
        check(rows.nodes.contains { $0[1].contains("episodeRun") },"Exact one-to-one mappings use a compact interval")
        let priorNode = try db.query("SELECT node FROM roots WHERE collection=? AND key=?",["deliveries",backup.deliveries[0].id.uuidString])
        var changed = backup; changed.records[primary.id]?.score = 9
        try db.saveBackup(changed,previous:backup)
        check(try db.query("SELECT node FROM roots WHERE collection=? AND key=?",["deliveries",backup.deliveries[0].id.uuidString]) == priorNode,"Rating updates do not rewrite sync history")
        check(try db.loadBackup()?.deliveries[0].record.score == 8,"Historical score remains immutable after live edit")
        let store = TrackingStore(directory:source,api:api)
        for linked in [platform,primary] { check(store.detailWork(for:linked).id == primary.id && store.record(linked).work.overview == primary.overview,"Linked platform opens admitted canonical metadata") }
        var staleMetadata = store.record(primary)
        staleMetadata.links["tmdb"]?.overview = "outdated linked snapshot"
        check(store.detailSource(staleMetadata).overview == primary.overview,"Detail metadata prefers canonical library work over stale linked copies")
        for source in [Catalog.trakt,.mal,.bangumi] {
            let linked = Work(source:source,remoteID:"extra-\(source.rawValue)",kind:.tv,title:"Other platform")
            staleMetadata.links[source.rawValue] = linked
            store.backup.records[primary.id] = staleMetadata
            check(store.detailWork(for:linked).id == primary.id,"All associated platform pages resolve the admitted work")
        }
        let legacyArchive = ApplicationArchive(backup:backup,snapshots:["anilist":snapshot],history:[],recommendations:[:],preferences:[:],credentials:["tmdb.session":"session","cloud.secret":"s3-secret"],diagnostics:try diagnostic.archiveData())
        let legacyData = try JSONEncoder().encode(legacyArchive)
        do { _ = try LibraryArchive.decode(legacyData); preconditionFailure("Accepted old JSON backup") }
        catch { check(true,"Retired JSON backups are rejected") }
        let archive = try LibraryArchive.encode(legacyArchive)
        check(LibraryArchive.isNative(archive) && archive.count < legacyData.count/4,"Private ZIP backup deduplicates and compresses repeated content")
        let protected = try LibraryArchive.encode(legacyArchive,password:"test-password")
        check(try LibraryArchive.isEncrypted(protected) && LibraryArchive.decode(protected,password:"test-password").backup.records == backup.records,"Password-protected backups restore the same records")
        do { _ = try LibraryArchive.decode(protected,password:"wrong"); preconditionFailure("Accepted wrong password") } catch { check(true,"Wrong backup password is rejected before import") }
        let restored = try LibraryArchive.decode(archive)
        check(restored.backup.records == backup.records && restored.backup.deliveries == backup.deliveries && restored.credentials == legacyArchive.credentials,"Native backup restores records, sync history and secrets")
        var corrupt = archive; corrupt[50] ^= 255
        do { _ = try LibraryArchive.decode(corrupt); preconditionFailure("Accepted damaged archive") } catch { check(true,"Corrupt backup is rejected") }
        do { _ = try LibraryArchive.decode(archive.dropLast(12)); preconditionFailure("Accepted truncated archive") } catch { check(true,"Truncated backup is rejected") }
        // Durable recovery around the database/Keychain boundary, without using the real Keychain.
        var credentials = Dictionary(uniqueKeysWithValues:Credentials.names.map { ($0,"old") })
        let oldCredentials = credentials, oldDiagnostic = try diagnostic.archiveData()
        let suite = UserDefaults(suiteName:UUID().uuidString)!
        let pending = try LibraryImportRecovery.prepare(directory:source,credentials:credentials,diagnostics:oldDiagnostic,preferences:["workspace.destination":"2"],write:{ credentials.merge($0) { _,new in new } })
        credentials["anilist.token"] = "new"
        try LibraryImportRecovery.recover(directory:source,database:db,diagnostics:diagnostic,defaults:suite,read:{ credentials[$0] ?? "" },write:{ credentials.merge($0) { _,new in new } })
        check(Credentials.names.allSatisfy { credentials[$0] == oldCredentials[$0] },"Interrupted pre-commit import restores credentials on recovery")
        let committed = try LibraryImportRecovery.prepare(directory:source,credentials:oldCredentials,diagnostics:oldDiagnostic,preferences:["workspace.destination":"2"],write:{ credentials.merge($0) { _,new in new } })
        credentials["anilist.token"] = "new"
        try db.setState("import.committed",committed)
        try LibraryImportRecovery.recover(directory:source,database:db,diagnostics:diagnostic,defaults:suite,read:{ credentials[$0] ?? "" },write:{ credentials.merge($0) { _,new in new } })
        check(committed != pending && credentials["anilist.token"] == "new" && suite.integer(forKey:"workspace.destination") == 2,"Interrupted post-commit import finishes preferences without reverting credentials")
        // Bounded live data: obsolete live versions are reclaimed, referenced history remains.
        let initialCount = try db.query("SELECT count(*) FROM nodes")[0][0]
        var last = changed
        for index in 0..<20 { var next = last; next.records[primary.id]?.score = Double(index); try db.saveBackup(next,previous:last); last = next }
        check(try db.query("SELECT count(*) FROM nodes")[0][0] == initialCount,"Unreferenced live versions are reclaimed instead of accumulating")
        try db.check()
        let cloudField = "settings/credential/tmdb"
        let operation = CloudOperation(id:"backup-source:1",device:"backup-source",sequence:1,field:cloudField,
                                       parents:[],timestamp:Date(),value:Data("{}".utf8))
        try db.receiveCloudBatch(CloudBatch(operations:[operation]))
        try db.put(operation,collection:"cloud-outbox",key:operation.id)
        try db.setState("cloud.device","backup-source")
        try db.setState("cloud.sequence","1")
        suite.set(Data("{\"enabled\":true}".utf8),forKey:"cloud.configuration")
        suite.set(176.5,forKey:"shelf.cardWidth")
        let sensitive = ["tmdb.session":"test-session","cloud.access":"test-access","cloud.secret":"test-secret"]
        let full = try await store.exportApplicationDataAsync(credentials:sensitive,password:"backup-password",defaults:suite)
        let targetDirectory = root.appendingPathComponent("restored")
        let target = TrackingStore(directory:targetDirectory,api:api)
        let restoredDefaults = UserDefaults(suiteName:UUID().uuidString)!
        var restoredCredentials:[String:String] = [:]
        try await target.importApplicationDataAsync(full,password:"backup-password",defaults:restoredDefaults,
            readCredential:{ restoredCredentials[$0] ?? "" },writeCredential:{ restoredCredentials.merge($0) { _,new in new } })
        let targetDB = try target.cloudStorage().db
        let restoredConfig = try JSONSerialization.jsonObject(with:restoredDefaults.data(forKey:"cloud.configuration")!) as? [String:Bool]
        check(sensitive.allSatisfy { restoredCredentials[$0.key] == $0.value } &&
              restoredDefaults.double(forKey:"shelf.cardWidth") == 176.5 && restoredConfig?["enabled"] == false,
              "Password-protected app backup restores platform and S3 secrets and display settings with sync paused")
        check(try targetDB.pendingCloudOperations().contains(operation) && targetDB.cloudDeviceID() != "backup-source",
              "Backup preserves pending cloud operations without cloning the device identity")
        if CommandLine.arguments.contains("--benchmark") {
            var large = Backup()
            for index in 0..<100 {
                var item = record
                item.work.remoteID = String(1000+index); item.work.title = "Fixture \(index)"
                var linked = platform; linked.remoteID = String(2000+index)
                item.links = ["tmdb":item.work,"anilist":linked]
                var map = item.platformLinks![0].mapping!
                map.tmdbID = item.work.remoteID
                map.evidence[0].text += " Work \(index)"
                item.platformLinks = [PlatformAssociation(target:linked,mapping:map)]
                large.records[item.id] = item
                large.deliveries += (0..<8).map { _ in Delivery(record:item,target:linked,state:"已同步") }
            }
            let payload = ApplicationArchive(backup:large,snapshots:[:],history:[],recommendations:[:],preferences:[:],credentials:[:],diagnostics:try diagnostic.archiveData())
            let oldBytes = try JSONEncoder().encode(payload).count
            let start = Date()
            let packed = try LibraryArchive.encode(payload)
            let seconds = Date().timeIntervalSince(start)
            let unpacked = try LibraryArchive.decode(packed)
            check(unpacked.backup.records == large.records && unpacked.backup.deliveries == large.deliveries,"100-work benchmark preserves all 800 completed tasks and mappings")
            print("BENCHMARK: 100 works, 800 completed tasks; JSON \(oldBytes) bytes; native \(packed.count) bytes; export \(seconds) seconds")
        }
        print("Fixture: legacy JSON \(legacyData.count) bytes; .anishelf \(archive.count) bytes")
        print("\(count) storage checks passed.")
    }
}
