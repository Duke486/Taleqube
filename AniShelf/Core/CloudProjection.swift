import Foundation

/// The cloud schema explicitly excludes regenerated translation/image caches and executable deliveries.
enum CloudProjection {
    static let preferenceKeys = ["anilist.clientID"]
    static func isDevicePreference(_ field:String) -> Bool {
        field.hasPrefix("settings/") && !field.hasPrefix("settings/credential/") &&
            !preferenceKeys.contains(String(field.dropFirst("settings/".count)))
    }
    static func encode(_ value:Any) throws -> Data { try CloudEncoding.json(value) }
    static func fields(_ backup:Backup) throws -> [String:Data] {
        var result:[String:Data] = [:]
        for (id,record) in backup.records {
            let object = try JSONSerialization.jsonObject(with:CloudEncoding.data(record)) as! [String:Any]
            // Existence is independent of fields, so stale edits never resurrect a deletion.
            result["item/\(id)/exists"] = Data("true".utf8)
            let grouped:Set<String> = ["progress","status","season","volumes","progressSubmitted"]
            let rating:Set<String> = ["score","scoreCleared","ratingOrigin"]
            result["item/\(id)/group/rating"] = try encode(object.filter { rating.contains($0.key) })
            result["item/\(id)/group/tracking"] = try encode(object.filter { grouped.contains($0.key) })
            for (key,value) in object where !grouped.contains(key) && !rating.contains(key) {
                if key == "platformLinks", let links = value as? [[String:Any]] {
                    for link in links {
                        let data = try encode(link)
                        let association = try JSONDecoder().decode(PlatformAssociation.self,from:data)
                        result["item/\(id)/link/" + association.id] = data
                    }
                } else if key == "viewingUnits", let units = value as? [[String:Any]] {
                    for unit in units {
                        let identity = String(describing:unit["season"] ?? unit["id"] ?? "unknown")
                        result["item/\(id)/season/\(identity)"] = try encode(unit.filter { !["score","scoreCleared"].contains($0.key) })
                        result["item/\(id)/seasonRating/\(identity)"] = try encode(unit.filter { ["score","scoreCleared"].contains($0.key) })
                    }
                } else { result["item/\(id)/field/\(key)"] = try encode(value) }
            }
        }
        for (id,value) in backup.associations ?? [:] { result["association/"+id] = try CloudEncoding.data(value) }
        for (id,value) in backup.localizations?.titles ?? [:] { result["title/"+id] = try CloudEncoding.data(value) }
        for (id,value) in backup.bookFormats ?? [:] { result["bookFormat/"+id] = try CloudEncoding.data(value) }
        for event in backup.handledHistory { result["handled/"+event] = Data("true".utf8) }
        for value in backup.history ?? [] {
            let data = try CloudEncoding.data(value)
            result["history/" + LibraryDatabase.digest(data)] = data
        }
        return result
    }
    static func changedFields(_ value:Backup,previous:Backup) throws -> (values:[String:Data],removed:Set<String>) {
        var current = Backup(), old = Backup()
        let recordIDs = Set(value.records.keys).union(previous.records.keys).filter { value.records[$0] != previous.records[$0] }
        for id in recordIDs { current.records[id] = value.records[id]; old.records[id] = previous.records[id] }
        current.associations = [:]; old.associations = [:]
        for id in Set((value.associations ?? [:]).keys).union((previous.associations ?? [:]).keys) where value.associations?[id] != previous.associations?[id] {
            current.associations?[id] = value.associations?[id]; old.associations?[id] = previous.associations?[id]
        }
        current.localizations = LocalizationArchive(); old.localizations = LocalizationArchive()
        for id in Set((value.localizations?.titles ?? [:]).keys).union((previous.localizations?.titles ?? [:]).keys) where value.localizations?.titles[id] != previous.localizations?.titles[id] {
            current.localizations?.titles[id] = value.localizations?.titles[id]; old.localizations?.titles[id] = previous.localizations?.titles[id]
        }
        if value.bookFormats != previous.bookFormats { current.bookFormats = value.bookFormats; old.bookFormats = previous.bookFormats }
        if value.history != previous.history { current.history = value.history; old.history = previous.history }
        current.handledHistory = value.handledHistory.subtracting(previous.handledHistory)
        old.handledHistory = previous.handledHistory.subtracting(value.handledHistory)
        let a = try fields(current), b = try fields(old)
        return (a.filter { b[$0.key] != $0.value },Set(b.keys).subtracting(a.keys))
    }
    static func rebase(_ edited:Backup,from base:Backup,onto current:Backup) throws -> Backup {
        let changes = try changedFields(edited,previous:base)
        var result = current
        if !changes.values.isEmpty || !changes.removed.isEmpty {
            var fields = try self.fields(current)
            for key in changes.removed { fields.removeValue(forKey:key) }
            for (key,value) in changes.values { fields[key] = value }
            result = try apply(fields,to:current)
        }
        func merge<T:Equatable>(_ old:[String:T],_ new:[String:T],_ current:[String:T]) -> [String:T] {
            var values = current
            for key in Set(old.keys).union(new.keys) where old[key] != new[key] { values[key] = new[key] }
            return values
        }
        let jobs = { (backup:Backup) in Dictionary(uniqueKeysWithValues:backup.deliveries.map { ($0.id.uuidString,$0) }) }
        let delivery = merge(jobs(base),jobs(edited),jobs(current))
        var seen = Set<UUID>()
        result.deliveries = (current.deliveries + edited.deliveries).compactMap {
            seen.insert($0.id).inserted ? delivery[$0.id.uuidString] : nil
        }
        result.translations = merge(base.translations,edited.translations,current.translations)
        var localization = result.localizations ?? LocalizationArchive()
        localization.overviews = merge(base.localizations?.overviews ?? [:],edited.localizations?.overviews ?? [:],current.localizations?.overviews ?? [:])
        result.localizations = localization
        result.recommendations = merge(base.recommendations ?? [:],edited.recommendations ?? [:],current.recommendations ?? [:])
        if edited.acknowledgedDeliveryErrors != base.acknowledgedDeliveryErrors { result.acknowledgedDeliveryErrors = edited.acknowledgedDeliveryErrors }
        return result
    }

    static func mergeEdit(_ draft:TrackingRecord,base:TrackingRecord,current:TrackingRecord) throws -> TrackingRecord {
        guard draft.id == base.id, draft.id == current.id else { return draft }
        var edited = Backup(), before = Backup(), latest = Backup()
        edited.records[draft.id] = draft; before.records[base.id] = base; latest.records[current.id] = current
        let changes = try changedFields(edited,previous:before)
        var merged = try fields(latest)
        for key in changes.removed { merged.removeValue(forKey:key) }
        for (key,value) in changes.values { merged[key] = value }
        guard let result = try apply(merged,to:latest).records[draft.id] else { throw CloudJournalError.invalidOperation }
        return result
    }
    static func apply(_ fields:[String:Data],to original:Backup) throws -> Backup {
        var result = original
        var records:[String:TrackingRecord] = [:]
        var itemFields:[String:[String:Data]] = [:]
        for (key,value) in fields where key.hasPrefix("item/") {
            let parts = key.split(separator:"/",maxSplits:2).map(String.init)
            guard parts.count == 3 else { throw CloudJournalError.invalidOperation }
            itemFields[parts[1],default:[:]][parts[2]] = value
        }
        for (id,local) in itemFields where local["exists"] != nil {
            var object:[String:Any] = [:], units:[[String:Any]] = [], links:[[String:Any]] = []
            for (suffix,data) in local {
                if suffix.hasPrefix("group/"), let values = try JSONSerialization.jsonObject(with:data) as? [String:Any] { object.merge(values) { _,new in new } }
                if suffix.hasPrefix("link/"), let link = try JSONSerialization.jsonObject(with:data) as? [String:Any] { links.append(link) }
                if suffix.hasPrefix("field/") { object[String(suffix.dropFirst(6))] = try JSONSerialization.jsonObject(with:data,options:.fragmentsAllowed) }
                if suffix.hasPrefix("season/"), var unit = try JSONSerialization.jsonObject(with:data) as? [String:Any] {
                    if let rating = local["seasonRating/"+String(suffix.dropFirst(7))], let values = try JSONSerialization.jsonObject(with:rating) as? [String:Any] { unit.merge(values) { _,new in new } }
                    if unit["scoreCleared"] == nil { unit["scoreCleared"] = false }
                    units.append(unit)
                }
            }
            if !links.isEmpty { object["platformLinks"] = links.sorted { a,b in ((try? encode(a).base64EncodedString()) ?? "") < ((try? encode(b).base64EncodedString()) ?? "") } }
            if !units.isEmpty { object["viewingUnits"] = units.sorted { ($0["season"] as? Int ?? 0) < ($1["season"] as? Int ?? 0) } }
            var record = try JSONDecoder().decode(TrackingRecord.self,from:encode(object))
            guard record.id == id else { throw CloudJournalError.invalidOperation }
            for association in record.platformLinks ?? [] {
                record.noEntryPlatforms?.remove(association.target.source.rawValue)
                record.retiredAssociationIDs?.remove(association.id)
            }
            for platform in record.links.keys { record.noEntryPlatforms?.remove(platform) }
            record.refreshOverallStatus(); records[id] = record
        }
        result.history = try fields.filter { $0.key.hasPrefix("history/") }.sorted { $0.key < $1.key }.map { try JSONDecoder().decode(ArchivedHistory.self,from:$0.value) }
        result.records = records
        result.associations = [:]
        var titles:[String:LocalizedText] = [:], formats:[String:String] = [:], handled = Set<String>()
        for (key,value) in fields {
            if key.hasPrefix("association/") { result.associations?[String(key.dropFirst(12))] = try JSONDecoder().decode(AssociationState.self,from:value) }
            if key.hasPrefix("title/") { titles[String(key.dropFirst(6))] = try JSONDecoder().decode(LocalizedText.self,from:value) }
            if key.hasPrefix("bookFormat/") { formats[String(key.dropFirst(11))] = try JSONDecoder().decode(String.self,from:value) }
            if key.hasPrefix("handled/") { handled.insert(String(key.dropFirst(8))) }
        }
        // A library record is the authority for its cached association copy.
        for (id,record) in records where result.associations?[id] != nil {
            result.associations?[id] = AssociationState(links:record.links,confirmedProgress:record.confirmedProgress,progressMappings:record.progressMappings,unitAssociations:record.viewingUnits?.map(UnitAssociation.init),platformLinks:record.platformLinks,retiredAssociationIDs:record.retiredAssociationIDs,noEntryPlatforms:record.noEntryPlatforms)
        }
        var localization = result.localizations ?? LocalizationArchive(); localization.titles = titles; result.localizations = localization
        result.bookFormats = formats; result.handledHistory = handled
        return result
    }
}
