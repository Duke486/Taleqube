import Foundation

// Standalone audit probes. All persistence is isolated in a temporary directory.
@main struct AuditProbes {
    @MainActor static func main() async throws {
        let root = URL.temporaryDirectory.appending(path:"AniShelf-audit-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let diagnostics = DiagnosticLog(directory:root.appending(path:"diagnostics"))
        let api = CatalogAPI(credential:{ _ in "" },diagnostics:diagnostics)
        let store = TrackingStore(directory:root.appending(path:"store"),api:api)
        let good = TrackingRecord(work:Work(source:.tmdb,remoteID:"1",kind:.movie,title:"Valid save"),score:8)
        var bad = TrackingRecord(work:Work(source:.tmdb,remoteID:"2",kind:.movie,title:"Invalid save"))
        bad.progress = -1
        let invalid = bad
        // This task is queued before the valid save yields for disk persistence.
        let otherSave = Task { @MainActor in await store.save(invalid) }
        let result = await store.save(good)
        _ = await otherSave.value
        let reopened = TrackingStore(directory:root.appending(path:"store"),api:api)
        let durable = reopened.backup.records[good.id]?.score == 8
        print("SAVE_RESULT: returned=\(result), durable=\(durable), message=\(store.message ?? "nil")")
        precondition(result && durable,"A separate operation must not change the successful save result")

        // Title persistence has no success result for its caller to gate dismissal on.
        let file = root.appending(path:"store/tracking-v1.json")
        try Data("external modification".utf8).write(to:file,options:.atomic)
        store.setTitle("New title",for:good.work)
        print("TITLE_FAILURE: displayed=\(store.display(good.work).title), message=\(store.message ?? "nil")")
        precondition(store.display(good.work).title != "New title")

        let large = TrackingStore(directory:root.appending(path:"large"),api:api)
        for index in 1...2000 {
            let work = Work(source:.tmdb,remoteID:String(index),kind:.movie,title:"Fixture \(index)",overview:String(repeating:"Synopsis. ",count:200))
            large.backup.records[work.id] = TrackingRecord(work:work)
        }
        let start = ContinuousClock.now
        let persisted = large.persist()
        let elapsed = start.duration(to:.now)
        precondition(persisted)
        print("MAIN_ACTOR_SYNC_PERSIST: 2000 records, \(elapsed)")
        print("Audit reproductions completed; temporary data removed on exit.")
    }
}
