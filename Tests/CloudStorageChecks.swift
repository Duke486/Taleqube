import Foundation

@main struct CloudStorageChecks {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let a = try LibraryDatabase(directory:root.appendingPathComponent("a")), b = try LibraryDatabase(directory:root.appendingPathComponent("b"))
        var count = 0
        func check(_ condition:Bool,_ label:String) { precondition(condition,label); count += 1; print("PASS: " + label) }
        let work = Work(source:.tmdb,remoteID:"42",kind:.tv,title:"Original")
        var record = TrackingRecord(work:work,score:8)
        record.viewingUnits = [ViewingUnit(title:"S1",season:1,progress:3,status:"进行中",trackingMarked:true)]
        var original = Backup(); original.records[work.id] = record
        original.translations = ["cache":["must not upload"]]
        original.localizations = LocalizationArchive(titles:[work.id:LocalizedText(original:"Original",text:"中文名",origin:"user")],overviews:[work.id:LocalizedText(original:"overview",text:"translation cache",origin:"AI")])
        let fields = try CloudProjection.fields(original)
        check(!fields.values.contains { String(data:$0,encoding:.utf8)?.contains("must not upload") == true || String(data:$0,encoding:.utf8)?.contains("translation cache") == true },"Caches excluded")
        let restored = try CloudProjection.apply(fields,to:Backup())
        check(restored.records[work.id]?.score == 8 && restored.records[work.id]?.viewingUnits == record.viewingUnits,"Tracking and seasons round-trip")
        check(restored.localizations?.titles == original.localizations?.titles,"Chinese names retained")
        try a.captureCloudFields(fields,namespace:"library")
        let seed = try a.pendingCloudOperations()
        let defaults = UserDefaults(suiteName:"Taleqube.CloudInboxTest." + UUID().uuidString)!
        let storage = CloudStorage(db:b,cloudPreferences:defaults,cloudReadCredentials:{ names in Dictionary(uniqueKeysWithValues:names.map { ($0,"") }) },cloudWriteCredentials:{ _ in })
        let inboxKey = "anishelf/v1/journal/test.json"
        check(try !storage.cloudHasBatch(inboxKey),"Unknown batch requires download")
        try storage.cloudReceive(CloudBatch(operations:seed),key:inboxKey)
        check(try storage.cloudHasBatch(inboxKey),"Durable inbox batch is not downloaded again before application")
        let reopenedStorage = CloudStorage(db:try LibraryDatabase(directory:root.appendingPathComponent("b")),cloudPreferences:defaults,cloudReadCredentials:{ names in Dictionary(uniqueKeysWithValues:names.map { ($0,"") }) },cloudWriteCredentials:{ _ in })
        check(try reopenedStorage.cloudHasBatch(inboxKey),"Pending inbox batch remains available after reopening")
        try b.delete(collection:"cloud-inbox",key:inboxKey)
        try b.receiveCloudBatch(CloudBatch(operations:seed))
        try b.put(fields,collection:"cloud-baseline",key:"library")
        var changedA = original; changedA.records[work.id]?.score = 9
        var changedB = original; changedB.localizations?.titles[work.id]?.text = "新的中文名"
        try a.captureCloudFields(CloudProjection.fields(changedA),namespace:"library")
        try b.captureCloudFields(CloudProjection.fields(changedB),namespace:"library")
        let changesA = try a.pendingCloudOperations(), changesB = try b.pendingCloudOperations()
        try a.receiveCloudBatch(CloudBatch(operations:changesB.reversed()))
        try b.receiveCloudBatch(CloudBatch(operations:changesA.reversed()))
        check(try a.cloudValues(namespace:"library") == b.cloudValues(namespace:"library"),"Different arrival orders converge")
        let merged = try CloudProjection.apply(a.cloudValues(namespace:"library"),to:Backup())
        check(merged.records[work.id]?.score == 9 && merged.localizations?.titles[work.id]?.text == "新的中文名","Concurrent rating and name survive")
        let before = try a.pendingCloudOperations()
        enum Abort:Error { case rollback }
        do { try a.transaction { try a.captureCloudFields([:],namespace:"library"); throw Abort.rollback } } catch Abort.rollback {}
        check(try a.pendingCloudOperations() == before,"Outbox rolls back atomically")
        let reopened = try LibraryDatabase(directory:root.appendingPathComponent("a"))
        check(try reopened.pendingCloudOperations() == before,"Outbox survives reopening")
        try a.acknowledgeCloudOperations(before.map(\.id))
        check(try a.pendingCloudOperations().isEmpty,"Acknowledgement clears only durable queue entries")
        try a.receiveCloudBatch(CloudBatch(operations:changesB))
        check(try a.cloudValues(namespace:"library") == b.cloudValues(namespace:"library"),"Duplicate delivery is idempotent")
        try a.captureCloudFields([:],namespace:"library")
        try b.receiveCloudBatch(CloudBatch(operations:a.pendingCloudOperations()))
        check(try CloudProjection.apply(b.cloudValues(namespace:"library"),to:Backup()).records.isEmpty,"Deletion propagates without resurrection")
        let conflictField = "library/item/\(work.id)/group/rating"
        let frontier = try b.read(CloudRegister.self,collection:"cloud-registers",key:conflictField)!.frontier.map(\.id)
        let branchA = CloudOperation(id:"migration-a:1",device:"migration-a",sequence:1,field:conflictField,parents:frontier,timestamp:Date(),value:Data("{\"score\":3}".utf8))
        let branchB = CloudOperation(id:"migration-b:1",device:"migration-b",sequence:1,field:conflictField,parents:frontier,timestamp:Date(),value:Data("{\"score\":4}".utf8))
        try b.receiveCloudBatch(CloudBatch(operations:[branchA,branchB]))
        check(try b.cloudConflictRows().contains { $0.id == conflictField },"Migration fixture contains a real conflict")
        let sourceStorage = CloudStorage(db:b,cloudPreferences:defaults,cloudReadCredentials:{ names in Dictionary(uniqueKeysWithValues:names.map { ($0,"") }) },cloudWriteCredentials:{ _ in })
        let migration = try sourceStorage.migrationBatches()
        let targetDB = try LibraryDatabase(directory:root.appendingPathComponent("migration-target"))
        let targetStorage = CloudStorage(db:targetDB,cloudPreferences:defaults,cloudReadCredentials:{ names in Dictionary(uniqueKeysWithValues:names.map { ($0,"") }) },cloudWriteCredentials:{ _ in })
        for (index,batch) in migration.enumerated() { try targetStorage.cloudReceive(batch,key:"migration-\(index)") }
        _ = try targetStorage.applyInbox(to:Backup())
        check(try targetDB.cloudValues(namespace:"library") == b.cloudValues(namespace:"library"),"Migration preserves materialized library fields")
        check(try targetDB.cloudConflictRows().map(\.id).sorted() == b.cloudConflictRows().map(\.id).sorted(),"Migration preserves concurrent branches")
        check(try targetDB.cloudDeletedItems().map(\.id) == b.cloudDeletedItems().map(\.id),"Migration preserves deletion recovery records")
        let snapshotIDs = Set(migration.last!.operations.map(\.id))
        try b.captureCloudChanges(["late":Data("true".utf8)],removed:[],namespace:"test")
        var scoreEdit = original; scoreEdit.records[work.id]?.score = 5
        var progressEdit = original; progressEdit.records[work.id]?.viewingUnits?[0].progress = 9
        let scoreChanges = try CloudProjection.changedFields(scoreEdit,previous:original)
        let progressChanges = try CloudProjection.changedFields(progressEdit,previous:original)
        check(Set(scoreChanges.values.keys).isDisjoint(with:progressChanges.values.keys),"Rating and season progress use independent registers")
        check(scoreChanges.values.count == 1 && scoreChanges.removed.isEmpty,"A rating edit encodes one field")
        let noChanges = try CloudProjection.changedFields(original,previous:original)
        check(noChanges.values.isEmpty && noChanges.removed.isEmpty,"Unchanged save produces no projection changes")
        let child = CloudOperation(id:"remote:2",device:"remote",sequence:2,field:"settings/test",parents:["remote:1"],timestamp:Date(),value:Data("2".utf8))
        try a.receiveCloudBatch(CloudBatch(operations:[child]))
        do { try a.validateCloudAncestry(fields:[child.field]); fatalError("Accepted missing ancestor") } catch CloudJournalError.missingAncestors { check(true,"Missing ancestor defers materialization") }
        let parent = CloudOperation(id:"remote:1",device:"remote",sequence:1,field:child.field,parents:[],timestamp:Date(),value:Data("1".utf8))
        try a.receiveCloudBatch(CloudBatch(operations:[parent]))
        try a.validateCloudAncestry(fields:[child.field]); check(true,"Later arrival fills causal gap")
        let canonicalA = try CloudEncoding.json(["watched":[3,1,2],"episodes":[3,1,2]])
        let canonicalB = try CloudEncoding.json(["watched":[2,3,1],"episodes":[3,1,2]])
        check(canonicalA == canonicalB,"Unordered sets have stable cross-device encoding")
        let canonicalC = try CloudEncoding.json(["watched":[2,3,1],"episodes":[1,2,3]])
        check(canonicalA != canonicalC,"Ordered content arrays retain their order")
        let credentialDB = try LibraryDatabase(directory:root.appendingPathComponent("credentials"))
        var credentialValues = ["trakt.clientID":"client","trakt.token":"access-1","trakt.refresh":"refresh-1"]
        let credentialStorage = CloudStorage(db:credentialDB,cloudPreferences:defaults,cloudReadCredentials:{ names in Dictionary(uniqueKeysWithValues:names.map { ($0,credentialValues[$0] ?? "") }) },cloudWriteCredentials:{ credentialValues.merge($0) { _,new in new } })
        try credentialStorage.captureMetadata(Backup())
        let credentialSeed = try credentialDB.pendingCloudOperations()
        check(credentialSeed.filter { $0.field == "settings/credential/trakt" }.count == 1,"OAuth client, access and refresh tokens share one atomic cloud register")
        try credentialDB.acknowledgeCloudOperations(credentialSeed.map(\.id))
        try credentialStorage.captureMetadata(Backup())
        check(try credentialDB.pendingCloudOperations().isEmpty,"Unchanged account credentials generate no cloud writes")
        credentialValues["trakt.token"] = "access-2"; credentialValues["trakt.refresh"] = "refresh-2"
        try credentialStorage.captureMetadata(Backup())
        let rotation = try credentialDB.pendingCloudOperations()
        check(rotation.count == 1 && rotation[0].field == "settings/credential/trakt","Token rotation uploads only the changed account group")
        let rotatedValues = try JSONDecoder().decode([String:String].self,from:rotation[0].value!)
        check(rotatedValues == credentialValues,"Rotated access and refresh tokens travel together")
        let credentialTargetDB = try LibraryDatabase(directory:root.appendingPathComponent("credential-target"))
        var targetCredentials:[String:String] = [:]
        let credentialTarget = CloudStorage(db:credentialTargetDB,cloudPreferences:defaults,cloudReadCredentials:{ names in Dictionary(uniqueKeysWithValues:names.map { ($0,targetCredentials[$0] ?? "") }) },cloudWriteCredentials:{ targetCredentials.merge($0) { _,new in new } })
        try credentialTarget.cloudReceive(CloudBatch(operations:credentialSeed + rotation),key:"account-rotation")
        _ = try credentialTarget.applyInbox(to:Backup())
        try credentialTarget.cloudApplySettings()
        check(targetCredentials["trakt.token"] == "access-2" && targetCredentials["trakt.refresh"] == "refresh-2","A second device installs the complete latest credential group")
        try credentialTarget.captureMetadata(Backup())
        check(try credentialTargetDB.pendingCloudOperations().isEmpty,"Applying remote credentials does not echo them back to the cloud")
        try credentialDB.acknowledgeCloudOperations(rotation.map(\.id))
        credentialValues = ["trakt.clientID":"client","trakt.token":"","trakt.refresh":""]
        try credentialStorage.captureMetadata(Backup())
        let disconnect = try credentialDB.pendingCloudOperations()
        try credentialTarget.cloudReceive(CloudBatch(operations:disconnect),key:"account-disconnect")
        _ = try credentialTarget.applyInbox(to:Backup()); try credentialTarget.cloudApplySettings()
        check(targetCredentials["trakt.token"] == "" && targetCredentials["trakt.refresh"] == "","Explicit disconnect clears authorization on the second device")
        let atomicDB = try LibraryDatabase(directory:root.appendingPathComponent("atomic-credentials"))
        var atomicItems = ["trakt.clientID":"client","trakt.token":"access-1","trakt.refresh":"refresh-1"]
        var rejectCredentialWrite = false
        let atomicVault = CredentialVault(read:{ atomicItems[$0] ?? "" },write:{ name,value in
            if rejectCredentialWrite && name.hasPrefix("oauth-group.v1.") { throw APIError.message("Injected group write failure") }
            atomicItems[name] = value
        })
        let atomicStorage = CloudStorage(db:atomicDB,cloudPreferences:defaults,
            cloudReadCredentials:atomicVault.read,cloudWriteCredentials:atomicVault.write)
        try atomicStorage.cloudReceive(CloudBatch(operations:credentialSeed),key:"atomic-seed")
        _ = try atomicStorage.applyInbox(to:Backup()); try atomicStorage.cloudApplySettings()
        try atomicStorage.cloudReceive(CloudBatch(operations:rotation),key:"atomic-rotation")
        _ = try atomicStorage.applyInbox(to:Backup())
        rejectCredentialWrite = true
        do { try atomicStorage.cloudApplySettings(); fatalError("Accepted failing cloud credential install") }
        catch { }
        let atomicNames = ["trakt.clientID","trakt.token","trakt.refresh"]
        check(try atomicVault.read(atomicNames)["trakt.token"] == "access-1" && atomicVault.read(atomicNames)["trakt.refresh"] == "refresh-1",
              "A failed cloud credential install leaves the complete old login available")
        check(try !atomicDB.keys("cloud-settings-pending").isEmpty,"A failed credential install retains its durable retry intent")
        rejectCredentialWrite = false
        try atomicStorage.cloudApplySettings()
        let restartedVault = CredentialVault(read:{ atomicItems[$0] ?? "" },write:{ atomicItems[$0] = $1 })
        check(try restartedVault.read(atomicNames)["trakt.token"] == "access-2" && restartedVault.read(atomicNames)["trakt.refresh"] == "refresh-2",
              "Retry and restart retain both new cloud OAuth tokens")
        check(try atomicDB.keys("cloud-settings-pending").isEmpty,"Successful grouped credential retry clears its intent")
        try atomicStorage.captureMetadata(Backup())
        check(try atomicDB.pendingCloudOperations().isEmpty,"Grouped credential recovery creates no cloud echo")
        var large = Backup()
        for index in 0..<1000 {
            let item = Work(source:.tmdb,remoteID:String(index),kind:.movie,title:"Movie \(index)")
            large.records[item.id] = TrackingRecord(work:item,score:8)
        }
        let began = Date()
        let largeFields = try CloudProjection.fields(large)
        let largeRoundTrip = try CloudProjection.apply(largeFields,to:Backup())
        check(largeRoundTrip.records.count == 1000,"Thousand-item library materializes without missing records")
        print("1000-item projection and merge: \(Date().timeIntervalSince(began)) seconds")
        var oneChange = large; oneChange.records["tmdb:movie:500"]?.score = 9
        let delta = try CloudProjection.changedFields(oneChange,previous:large)
        check(delta.values.count == 1 && delta.removed.isEmpty,"Thousand-item library emits only one changed rating")
        var localDraft = record; localDraft.viewingUnits?[0].progress = 8
        var remoteCurrent = record; remoteCurrent.score = 9
        let savedDraft = try CloudProjection.mergeEdit(localDraft,base:record,current:remoteCurrent)
        check(savedDraft.score == 9 && savedDraft.viewingUnits?[0].progress == 8,"Saving an open draft preserves unrelated remote edits")
        print("\(count) cloud storage checks passed")
    }
}
