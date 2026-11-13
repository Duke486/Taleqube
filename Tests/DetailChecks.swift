import Foundation

@main struct DetailChecks {
    @MainActor static func main() async throws {
        var count = 0
        func check(_ value:Bool,_ label:String) { precondition(value,label); count += 1; print("PASS: \(label)") }
        let translations = Intelligence.metadataTranslations(["translations":["name":"  小樱  ","description":"完整介绍","unknown":"注入","bad":42,"empty":"  "]],fields:["name":"Sakura","description":"Biography","bad":"raw","empty":"raw"])
        check(translations == ["name":"小樱","description":"完整介绍"],"Metadata parser accepts known nonempty strings only and ignores foreign IDs")
        let arrayTranslations = Intelligence.metadataTranslations(["translations":[["id":"name","text":"小樱"],["id":"name","text":"另一名字"],["id":"bio","translation":"人物介绍"]]],fields:["name":"Sakura","bio":"Biography"])
        check(arrayTranslations == ["bio":"人物介绍"],"Metadata array recovery rejects duplicate IDs")
        let credits = CatalogAPI.screenCredits(["created_by":[["id":2,"name":"Creator"]],"aggregate_credits":["cast":[["id":1,"name":"Actor","roles":[["character":"Hero"],["character":"Narrator"]]],["id":1,"name":"Duplicate"]],"crew":[["id":2,"name":"Creator","jobs":[["job":"Director"]]],["id":3,"name":"Assistant","jobs":[["job":"Driver"]]]]],"genres":[["name":"Drama"]]],creditKey:"aggregate_credits")
        check(credits.cast.count == 1 && credits.cast[0].role == "Hero / Narrator","TMDB aggregate roles retain names and deduplicate people")
        check(credits.crew.count == 1 && credits.crew[0].role.contains("导演") && credits.crew[0].role.contains("主创"),"TMDB key crew jobs merge and omit incidental jobs")
        var title = Media.Title(romaji:"Original",english:"Original",native:"原題")
        title.localized = "中文译名"
        check(title.display == "中文译名" && title.native == "原題","Related title translations preserve original matching metadata")
        for value in [1.0,5,10,85,100] {
            let stored = PercentRating.storedValue(String(value))!
            check(PercentRating.displayValue(stored) == value,"Percent score round trip preserves \(value) without guessing scale")
        }
        check(PercentRating.storedValue("101") == nil && PercentRating.storedValue("nan") == nil,"Invalid percent scores are rejected")
        let early = Date(timeIntervalSince1970:1000), late = Date(timeIntervalSince1970:2000)
        var unmarked = ViewingUnit(title:"第一季",season:1,trackingMarked:false)
        unmarked.setStatus("计划中",at:early)
        check(unmarked.isTrackingMarked && unmarked.trackingUpdatedAt == early,"First explicit planned mark is retained")
        unmarked.setStatus("计划中",at:late)
        check(unmarked.trackingUpdatedAt == early,"Repeated season status does not update its timestamp")
        let directory = FileManager.default.temporaryDirectory.appending(path:UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:directory) }
        let api = CatalogAPI(credential:{ _ in "" },diagnostics:DiagnosticLog(directory:directory.appending(path:"diagnostics")))
        let store = TrackingStore(directory:directory,api:api,intelligence:Intelligence(api:api,credential:{ _ in "" }))
        let tv = Work(source:.tmdb,remoteID:"1",kind:.tv,title:"Test")
        var first = ViewingUnit(id:"season:1",title:"第一季",season:1,scopeConfirmed:true); first.setStatus("已暂停",at:early)
        var second = ViewingUnit(id:"season:2",title:"第二季",season:2,scopeConfirmed:true); second.setStatus("已放弃",at:late)
        var record = TrackingRecord(work:tv,modifiedAt:early)
        record.viewingUnits = [first,second]; record.refreshOverallStatus()
        // Seed through the persisted content graph using a valid TMDB identity.
        let seeded = await store.save(record)
        check(seeded,"Season status fixture saves through the production persistence path")
        store.updateStatus([tv.id],to:"已暂停")
        let updated = store.backup.records[tv.id]!
        check(updated.viewingUnits?[0].trackingUpdatedAt == early && updated.viewingUnits?[1].status == "已暂停","Bulk status leaves unchanged seasons untouched and updates changed seasons")
        store.updateStatus([tv.id],to:"已暂停")
        check(store.backup.records[tv.id]?.modifiedAt == updated.modifiedAt,"Repeated bulk status preserves work modified date")
        print("Passed \(count) detail checks")
    }
}
