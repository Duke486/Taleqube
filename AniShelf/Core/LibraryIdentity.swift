import Foundation

struct AssociationState: Codable, Equatable {
    var links: [String:Work]
    var confirmedProgress: Set<String>
    var progressMappings: [String:ProgressMapping]? = nil
    var unitAssociations: [UnitAssociation]? = nil
    var platformLinks: [PlatformAssociation]? = nil
    var retiredAssociationIDs: Set<String>? = nil
    var noEntryPlatforms: Set<String>? = nil
}

enum AssociationScope: String, Codable, CaseIterable, Sendable {
    case whole, season, custom, unresolved
}
struct PlatformAssociation: Codable, Equatable, Identifiable, Sendable {
    var target: Work
    var scope: AssociationScope = .whole
    var season = 1
    var customRanges: [EpisodeRange] = []
    // Old part records stay intact here, separate from actual seasons.
    var legacy: ViewingUnit?
    var mapping: ContentMapping?
    var id: String { target.id }
    func mappingLabel(regularSeasons:[Int]) -> String {
        guard let map = mapping else { return title }
        guard map.confirmed else { return "待确认" }
        let all = Set(regularSeasons.filter { $0 > 0 })
        if scope == .whole, !all.isEmpty, Set(map.seasons) == all, map.coverage == "full" || map.manual { return "整部作品" }
        return map.seasonLabel
    }
    var title: String {
        switch scope {
        case .whole: "整部作品"
        case .season: season == 0 ? "特别篇" : "第 \(season) 季"
        case .custom: "自定义集数范围"
        case .unresolved: "待确认对应范围"
        }
    }
    func includes(_ unit:ViewingUnit) -> Bool {
        if let mapping { return mapping.confirmed && mapping.seasons.contains(unit.season) }
        switch scope {
        case .whole: return unit.season > 0
        case .season: return unit.season == season
        case .custom: return customRanges.contains { $0.season == unit.season }
        case .unresolved: return true
        }
    }
}
struct SourceProgress: Codable, Equatable, Identifiable {
    var work: Work
    var score: Double?
    var progress: Int
    var season: Int
    var status: String
    var id: String { work.id }
}
enum LibraryIdentity {
    static func primarySource(for kind:WorkKind) -> Catalog { kind == .manga ? .anilist : .tmdb }
    static func canonical(_ record:TrackingRecord, using primary:Work, exception:Bool = false) throws -> TrackingRecord {
        guard primary.kind == record.work.kind else { throw APIError.message("所选作品的类型不一致") }
        guard exception || primary.source == primarySource(for:record.work.kind) else { throw APIError.message("请为影视选择 TMDB 作品，为书籍选择 AniList 作品") }
        var result = record
        if result.sourceRecords == nil { result.sourceRecords = [:] }
        if record.work.source != primary.source {
            if !record.hasNoEntry(record.work.source) {
                result.sourceRecords?[record.id] = SourceProgress(work:record.work,score:record.score,progress:record.progress,season:record.season,status:record.status)
                result.links[record.work.source.rawValue] = record.work
            }
        } else if record.id != primary.id { result.sourceRecords?[record.id] = nil }
        result.links[primary.source.rawValue] = primary
        result.noEntryPlatforms?.remove(primary.source.rawValue)
        result.prepareUnits()
        if record.work.source == .tmdb && record.id != primary.id {
            result.retainedSeasonTracking = (record.viewingUnits ?? []) + (record.retainedSeasonTracking ?? [])
            result.retainedSeasonTracking = result.retainedSeasonTracking?.map { value in
                var item = ViewingUnit(id:"season:\(value.season)",title:"",season:value.season,scopeConfirmed:true)
                item.score = value.score; item.progress = value.progress; item.watched = value.watched; item.status = value.status
                item.trackingMarked = value.trackingMarked; item.trackingUpdatedAt = value.trackingUpdatedAt
                return item
            }
            result.viewingUnits = []
        }
        result.work = primary
        result.libraryException = exception ? "用户选择保留平台条目" : nil
        return result
    }
    static func mergeImport(_ imported:TrackingRecord, existing:TrackingRecord?) -> TrackingRecord {
        guard var existing else { return imported }
        var changed = false
        for (source,work) in imported.links where existing.links[source] == nil {
            existing.links[source] = work; existing.noEntryPlatforms?.remove(source); changed = true
        }
        if existing.sourceRecords == nil { existing.sourceRecords = [:] }
        for (id,progress) in imported.sourceRecords ?? [:] where existing.sourceRecords?[id] == nil { existing.sourceRecords?[id] = progress; changed = true }
        if imported.work.kind == .tv {
            existing.prepareUnits()
            var incoming = imported; incoming.prepareUnits()
            for unit in incoming.viewingUnits ?? [] where existing.viewingUnits?.contains(where:{ $0.id == unit.id }) != true { existing.viewingUnits?.append(unit); changed = true }
            for link in incoming.platformLinks ?? [] where existing.platformLinks?.contains(where:{ $0.id == link.id }) != true {
                existing.platformLinks?.append(link); existing.noEntryPlatforms?.remove(link.target.source.rawValue); changed = true
            }
            if existing.archivedUnits == nil { existing.archivedUnits = [] }
            for unit in incoming.archivedUnits ?? [] where existing.archivedUnits?.contains(where:{ $0.id == unit.id }) != true { existing.archivedUnits?.append(unit) }
            existing.viewingUnits?.sort { $0.season < $1.season }
        }
        if changed { existing.modifiedAt = Date() }
        return existing
    }
}
extension TrackingStore {
    /// Keep source records intact; only AniList shelf presentation groups shared library identities.
    func platformShelfGroups(_ records:[TrackingRecord], source:Catalog) -> [[TrackingRecord]] {
        var groups: [[TrackingRecord]] = []
        var positions: [String:Int] = [:]
        var seen = Set<String>()
        for record in records where seen.insert(record.id).inserted {
            guard source == .anilist, let libraryRecord = libraryRecord(for:record.work) else {
                groups.append([record]); continue
            }
            if let position = positions[libraryRecord.id] {
                groups[position].append(record)
            } else {
                positions[libraryRecord.id] = groups.count
                groups.append([record])
            }
        }
        return groups
    }
    /// Every platform entry opens the locally admitted canonical work.
    func detailWork(for work:Work) -> Work { libraryRecord(for:work)?.work ?? work }
    func detailSource(_ record:TrackingRecord) -> Work {
        if record.work.source == .tmdb || record.work.kind == .manga { return record.work }
        return record.links["tmdb"] ?? record.work
    }
    func isInLibrary(_ work:Work) -> Bool {
        libraryRecord(for:work) != nil
    }
    func libraryRecord(for work:Work) -> TrackingRecord? {
        if let direct = indexedLibraryRecord(work.id) { return direct }
        let primary = LibraryIdentity.primarySource(for:work.kind).rawValue
        let target = backup.associations?[work.id]?.links[primary]
            ?? platformRecord(for:work.id)?.links[primary]
        if let target { return indexedLibraryRecord(target.id) }
        if work.kind != .manga, let tmdbID = work.tmdbID, tmdbID > 0 {
            return indexedLibraryRecord(Work(source:.tmdb,remoteID:String(tmdbID),kind:work.kind,title:"").id)
        }
        return nil
    }
    func admit(_ record:TrackingRecord, using primary:Work, exception:Bool = false) throws {
        message = nil
        var canonical = try LibraryIdentity.canonical(record,using:primary,exception:exception)
        let now = Date()
        canonical.addedAt = canonical.addedAt ?? now
        canonical.modifiedAt = canonical.modifiedAt ?? now
        backup.records[canonical.id] = LibraryIdentity.mergeImport(canonical,existing:backup.records[canonical.id])
        persist()
        if let message { throw APIError.message(message) }
    }
}

/// A locally tracked season or part. Provider entries keep their own identity.
struct ViewingUnit: Codable, Equatable, Identifiable, Sendable {
    var id: String = UUID().uuidString
    var title: String
    var season: Int
    var firstEpisode = 1
    var lastEpisode: Int?
    var additionalRanges: [EpisodeRange]?
    var scopeConfirmed = false
    var progress = 0
    var watched: Set<Int>? = nil
    var score: Double?
    var scoreCleared = false
    var status = "计划中"
    var links: [String:Work] = [:]
    // nil reads legacy records; false distinguishes downloaded metadata from an explicit watch choice.
    var trackingMarked: Bool?
    var trackingUpdatedAt: Date?
    var isTrackingMarked: Bool {
        trackingMarked ?? (progress > 0 || watched != nil || !["计划中", ""].contains(status))
    }
    mutating func setStatus(_ value:String,at date:Date = Date()) {
        guard status != value || !isTrackingMarked else { return }
        status = value; trackingMarked = true; trackingUpdatedAt = date
    }
    var ranges: [EpisodeRange] { [EpisodeRange(season:season,first:firstEpisode,last:lastEpisode)] + (additionalRanges ?? []) }
    var total: Int? {
        guard ranges.allSatisfy({ $0.last != nil && ($0.last ?? 0) >= $0.first }) else { return nil }
        return ranges.reduce(0) { $0 + (($1.last ?? 0) - $1.first + 1) }
    }
    var validScope: Bool {
        guard ranges.allSatisfy({ $0.season >= 0 && $0.first > 0 && ($0.last.map { $0 >= 1 } ?? true) && ($0.last ?? Int.max) >= $0.first }) else { return false }
        for (index,range) in ranges.enumerated() {
            for other in ranges.dropFirst(index + 1) where range.season == other.season {
                if range.first <= (other.last ?? Int.max) && other.first <= (range.last ?? Int.max) { return false }
            }
        }
        return ranges.count == 1 || ranges.allSatisfy { $0.last != nil }
    }
    func episodeIndex(season:Int,number:Int) -> Int? {
        var offset = 0
        for range in ranges {
            if range.season == season && number >= range.first && number <= (range.last ?? Int.max) { return offset + number - range.first + 1 }
            guard let last = range.last else { return nil }; offset += max(0,last - range.first + 1)
        }
        return nil
    }
    func episodeAddress(_ index:Int) -> EpisodeAddress? {
        guard index > 0 else { return nil }
        var remaining = index
        for range in ranges {
            let count = range.last.map { max(0,$0 - range.first + 1) } ?? Int.max
            if remaining <= count { return EpisodeAddress(season:range.season,number:range.first + remaining - 1) }
            remaining -= count
        }
        return nil
    }
    var contiguousProgress: Int {
        guard let watched else { return progress }
        var cursor = 0
        while watched.contains(cursor + 1) { cursor += 1 }
        return cursor
    }
    func hasWatched(_ episode:Int) -> Bool { watched?.contains(episode) ?? (episode > 0 && episode <= progress) }
    mutating func markThrough(_ episode:Int) {
        trackingMarked = true; trackingUpdatedAt = Date()
        progress = max(0,episode)
        watched = progress > 0 ? Set(1...progress) : []
        updateStatus()
    }
    mutating func toggle(_ episode:Int) {
        guard episode > 0 else { return }
        trackingMarked = true; trackingUpdatedAt = Date()
        if watched == nil { watched = progress > 0 ? Set(1...progress) : [] }
        if watched?.remove(episode) == nil { watched?.insert(episode) }
        progress = contiguousProgress
        updateStatus()
    }
    private mutating func updateStatus() {
        if let total, total > 0, contiguousProgress == total { status = "已完成" }
        else if !(watched ?? []).isEmpty || progress > 0 { if status != "重温中" { status = "进行中" } }
        else { status = "计划中" }
    }
}
extension TrackingRecord {
    /// Main TMDB entries summarize explicitly tracked regular seasons, never specials or metadata-only seasons.
    var aggregatedSeasonStatus: String? {
        guard work.source == .tmdb, work.kind == .tv else { return nil }
        func priority(_ status:String) -> Int {
            switch status {
            case "重温中": return 5
            case "进行中", "观看中", "在看": return 4
            case "计划中": return 3
            case "已暂停", "已放弃": return 2
            case "已完成", "已观看": return 1
            default: return 0
            }
        }
        // Retained season tracking remains authoritative while metadata is reloaded.
        let current = viewingUnits ?? []
        let retained = (retainedSeasonTracking ?? []).filter { old in !current.contains(where:{ $0.season == old.season }) }
        let candidates = (current + retained).filter { $0.season > 0 && $0.isTrackingMarked && priority($0.status) > 0 }
        let winner = candidates.sorted {
            if priority($0.status) != priority($1.status) { return priority($0.status) > priority($1.status) }
            if $0.trackingUpdatedAt != $1.trackingUpdatedAt { return ($0.trackingUpdatedAt ?? .distantPast) > ($1.trackingUpdatedAt ?? .distantPast) }
            if ($0.status == status) != ($1.status == status) { return $0.status == status }
            return $0.season < $1.season
        }.first
        switch winner?.status {
        case "观看中", "在看": return "进行中"
        case "已观看": return "已完成"
        default: return winner?.status
        }
    }
    mutating func refreshOverallStatus() {
        if let aggregate = aggregatedSeasonStatus { status = aggregate }
    }
    /// Compare user edits only; downloaded metadata and saved associations are independent.
    func hasTrackingChanges(from previous:TrackingRecord) -> Bool {
        if score != previous.score || (scoreCleared == true) != (previous.scoreCleared == true) || progressState != previous.progressState { return true }
        return ((viewingUnits ?? []) + (retainedSeasonTracking ?? [])).contains { unit in
            let old = ((previous.viewingUnits ?? []) + (previous.retainedSeasonTracking ?? [])).first { $0.id == unit.id }
            return unit.score != old?.score || unit.scoreCleared != (old?.scoreCleared ?? false) || unit.progressState != (old?.progressState ?? .emptyUnit) || unit.isTrackingMarked != (old?.isTrackingMarked ?? false) || unit.trackingUpdatedAt != old?.trackingUpdatedAt
        }
    }
    var progressState: ViewingProgressState {
        ViewingProgressState(progress:progress,season:season,volumes:volumes,status:status,watched:nil)
    }
    mutating func prepareUnits() {
        guard work.kind == .tv else { return }
        let creatingUnits = viewingUnits == nil
        defer {
            migratePlatformAssociations(); simplifyAssociations()
            for key in noEntryPlatforms ?? [] { if let platform = Catalog(rawValue:key) { setNoEntry(platform) } }
            // Newly constructed source entries default to the whole work. Explicit
            // legacy units retain their original scope and migration evidence.
            if creatingUnits {
                for index in platformLinks?.indices ?? 0..<0 where platformLinks?[index].scope == .unresolved && platformLinks?[index].mapping == nil {
                    platformLinks?[index].scope = .whole
                }
            }
        }
        guard viewingUnits == nil else { return }
        viewingUnits = []
        let imported = (sourceRecords ?? [:]).values.filter { [.anilist,.mal,.bangumi].contains($0.work.source) }
        if !imported.isEmpty {
            for source in imported.sorted(by:{ $0.id < $1.id }) {
                viewingUnits?.append(ViewingUnit(id:source.id,title:source.work.title,season:source.season,progress:source.progress,score:source.score,status:source.status,links:[source.work.source.rawValue:source.work],trackingMarked:true))
            }
        } else if [.anilist,.mal,.bangumi].contains(work.source) {
            viewingUnits = [ViewingUnit(id:work.id,title:work.title,season:season,progress:progress,score:score,status:status,links:[work.source.rawValue:work])]
        } else {
            var initial = ViewingUnit(id:"season:\(season)",title:season == 0 ? "特别篇" : "第 \(season) 季",season:season,scopeConfirmed:true,progress:progress,status:status,
                                      trackingMarked:progress > 0 || addedAt != nil || !["计划中","进行中"].contains(status))
            for (source,target) in links where [.anilist,.mal,.bangumi].contains(target.source) {
                if let mapping = progressMappings?[source], confirmedProgress.contains(source), mapping.localSeason == season, mapping.episodeOffset <= 0 {
                    initial.firstEpisode = 1 - mapping.episodeOffset
                    initial.progress = max(0,progress + mapping.episodeOffset)
                    initial.links[source] = target
                } else {
                    viewingUnits?.append(ViewingUnit(id:target.id,title:target.title,season:season,links:[source:target]))
                }
            }
            viewingUnits?.insert(initial,at:0)
        }
    }
    mutating func ensureSeason(_ number:Int, title:String) {
        prepareUnits()
        guard viewingUnits?.contains(where:{ $0.id == "season:\(number)" || ($0.season == number && $0.scopeConfirmed) }) != true else { return }
        var unit = retainedSeasonTracking?.first(where:{ $0.season == number }) ?? ViewingUnit(id:"season:\(number)",title:"",season:number,scopeConfirmed:true,trackingMarked:false)
        unit.title = number == 0 ? "特别篇" : "第 \(number) 季"
        viewingUnits?.append(unit)
        retainedSeasonTracking?.removeAll { $0.season == number }
        viewingUnits?.sort { $0.season < $1.season }
    }
    func unitPayload(_ unit:ViewingUnit, target:Work) throws -> TrackingRecord {
        guard unit.validScope, unit.progress >= 0,
              unit.lastEpisode.map({ $0 >= unit.firstEpisode }) ?? true,
              unit.total.map({ unit.contiguousProgress <= $0 && (unit.watched?.max() ?? 0) <= $0 }) ?? true,
              unit.score.map({ $0.isFinite && $0 > 0 && $0 <= 10 }) ?? true else { throw APIError.message("请检查本季的评分和集数范围") }
        var payload = self
        payload.score = unit.score; payload.scoreCleared = unit.scoreCleared
        payload.progress = unit.contiguousProgress; payload.status = unit.status; payload.season = unit.season
        payload.progressDisabled.remove(target.source.rawValue)
        if target.source == .trakt {
            guard unit.scopeConfirmed else { throw APIError.message("请先设置“\(unit.title)”对应的季和集数") }
            // A part rating must never overwrite the series rating on Trakt.
            payload.score = nil; payload.scoreCleared = false
            payload.progress = unit.firstEpisode + unit.contiguousProgress - 1
            let watched = unit.watched ?? (unit.progress > 0 ? Set(1...unit.progress) : [])
            payload.episodeHistory = watched.sorted().compactMap { unit.episodeAddress($0) }
            if let latest = payload.episodeHistory?.last { payload.season = latest.season; payload.progress = latest.number }
            payload.syncSeason = unit.season
        } else {
            guard unit.links[target.source.rawValue]?.id == target.id else { throw APIError.message("请先关联本季在 \(target.source.title) 的条目") }
        }
        return payload
    }
}

struct ViewingProgressState: Equatable {
    var progress: Int
    var season: Int
    var volumes: Int
    var status: String
    var watched: Set<Int>?
    var trackingMarked = false
    static let emptyUnit = ViewingProgressState(progress:0,season:0,volumes:0,status:"计划中",watched:[])
}
extension ViewingUnit {
    var progressState: ViewingProgressState {
        ViewingProgressState(progress:progress,season:0,volumes:0,status:status,
                             watched:watched ?? (progress > 0 ? Set(1...progress) : []),trackingMarked:isTrackingMarked)
    }
}
struct EpisodeAddress: Codable, Hashable, Sendable {
    var season: Int
    var number: Int
}

struct EpisodeRange: Codable, Equatable, Identifiable, Sendable {
    var id: String = UUID().uuidString
    var season: Int
    var first: Int
    var last: Int?
}

/// Persist association edits independently from unfinished rating/progress edits.
struct UnitAssociation: Codable, Equatable {
    var unit: ViewingUnit
    init(_ value:ViewingUnit) {
        unit = value
        unit.score = nil; unit.scoreCleared = false; unit.progress = 0
        unit.watched = nil; unit.status = "计划中"
        unit.trackingMarked = false; unit.trackingUpdatedAt = nil
    }
    func applying(to existing:ViewingUnit?) -> ViewingUnit {
        var result = unit
        if let existing {
            result.score = existing.score; result.scoreCleared = existing.scoreCleared
            result.progress = existing.progress; result.watched = existing.watched; result.status = existing.status
            result.trackingMarked = existing.trackingMarked; result.trackingUpdatedAt = existing.trackingUpdatedAt
        }
        return result
    }
}
extension TrackingRecord {
    mutating func applyUnitAssociations(_ values:[UnitAssociation]) {
        prepareUnits()
        for value in values {
            if let index = viewingUnits?.firstIndex(where:{ $0.id == value.unit.id }) {
                let existing = viewingUnits?[index]
                viewingUnits?[index] = value.applying(to:existing)
            } else { viewingUnits?.append(value.applying(to:nil)) }
        }
    }
    @discardableResult mutating func associate(_ target:Work, unitID:String?, onlyIfMissing:Bool = false) -> Bool {
        guard target.kind == work.kind else { return false }
        let source = target.source.rawValue
        if work.kind == .tv, ![Catalog.tmdb,.trakt].contains(target.source) {
            guard let unitID, let index = viewingUnits?.firstIndex(where:{ $0.id == unitID }) else { return false }
            let number = viewingUnits![index].season
            guard !onlyIfMissing || platformLinks?.contains(where:{ $0.target.source == target.source && $0.season == number && $0.scope == .season }) != true else { return false }
            guard setPlatformAssociation(target) else { return false }
            if let linkIndex = platformLinks?.firstIndex(where:{ $0.id == target.id }) {
                platformLinks?[linkIndex].scope = .season; platformLinks?[linkIndex].season = number
            }
        } else {
            guard !onlyIfMissing || links[source] == nil else { return false }
            associate(target)
        }
        return true
    }
}

extension Backup {
    @discardableResult mutating func fillMissingLibraryDates(now:Date = Date()) -> Bool {
        var changed = false
        for id in Array(records.keys) {
            if records[id]?.addedAt == nil { records[id]?.addedAt = now; changed = true }
            if records[id]?.modifiedAt == nil { records[id]?.modifiedAt = now; changed = true }
        }
        return changed
    }
}
enum LibrarySort: String, CaseIterable, Identifiable {
    case added = "入库日期 · 从新到旧"
    case modified = "修改日期 · 从新到旧"
    case title = "标题"
    case score = "我的评分"
    var id:String { rawValue }
    func precedes(_ a:TrackingRecord,_ b:TrackingRecord,titleA:String,titleB:String) -> Bool {
        switch self {
        case .added: if a.addedAt != b.addedAt { return (a.addedAt ?? .distantPast) > (b.addedAt ?? .distantPast) }
        case .modified: if a.modifiedAt != b.modifiedAt { return (a.modifiedAt ?? .distantPast) > (b.modifiedAt ?? .distantPast) }
        case .score: if a.score != b.score { return (a.score ?? -1) > (b.score ?? -1) }
        case .title: break
        }
        let order = titleA.localizedStandardCompare(titleB)
        return order == .orderedSame ? a.id < b.id : order == .orderedAscending
    }
}
enum BookFilter: String, CaseIterable, Identifiable {
    case all = "全部", manga = "漫画", novel = "轻小说"
    var id:String { rawValue }
    func includes(_ work:Work) -> Bool {
        guard work.kind == .manga else { return false }
        switch self {
        case .all: return true
        case .novel: return work.isNovel
        case .manga: return work.isComic
        }
    }
}
extension TrackingRecord {
    mutating func migratePlatformAssociations() {
        guard platformLinks == nil else { return }
        var associations: [PlatformAssociation] = []
        let old = viewingUnits ?? []
        if archivedUnits == nil { archivedUnits = old }
        var real = old.filter { $0.id.hasPrefix("season:") && $0.firstEpisode == 1 && ($0.additionalRanges?.isEmpty ?? true) }
        for unit in old {
            for target in unit.links.values.sorted(by:{ $0.id < $1.id }) where ![Catalog.tmdb,.trakt].contains(target.source) {
                guard !associations.contains(where:{ $0.id == target.id }) else { continue }
                let scope: AssociationScope = !unit.scopeConfirmed ? .unresolved : unit.firstEpisode == 1 && (unit.additionalRanges?.isEmpty ?? true) ? .season : .custom
                associations.append(PlatformAssociation(target:target,scope:scope,season:unit.season,
                    customRanges:scope == .custom ? unit.ranges : [],legacy:unit))
            }
            guard !real.contains(where:{ $0.id == unit.id }), unit.scopeConfirmed, unit.validScope else { continue }
            for range in unit.ranges {
                if !real.contains(where:{ $0.season == range.season }) {
                    real.append(ViewingUnit(id:"season:\(range.season)",title:"",season:range.season,scopeConfirmed:true,trackingMarked:false))
                }
                guard let index = real.firstIndex(where:{ $0.season == range.season }) else { continue }
                let watched = unit.watched ?? (unit.progress > 0 ? Set(1...unit.progress) : [])
                let mapped = Set(watched.compactMap { unit.episodeAddress($0) }.filter { $0.season == range.season }.map(\.number))
                var existing = real[index].watched ?? (real[index].progress > 0 ? Set(1...real[index].progress) : [])
                existing.formUnion(mapped); real[index].watched = existing; real[index].progress = real[index].contiguousProgress
                if range.first == 1 && unit.ranges.count == 1 && real[index].score == nil {
                    real[index].score = unit.score; real[index].status = unit.status
                    real[index].trackingMarked = unit.isTrackingMarked; real[index].trackingUpdatedAt = unit.trackingUpdatedAt
                }
            }
        }
        for target in links.values.sorted(by:{ $0.id < $1.id }) where ![Catalog.tmdb,.trakt].contains(target.source) && !associations.contains(where:{ $0.id == target.id }) {
            associations.append(PlatformAssociation(target:target))
        }
        var unique: [Int:ViewingUnit] = [:]
        for var unit in real {
            unit.id = "season:\(unit.season)"; unit.title = unit.season == 0 ? "特别篇" : "第 \(unit.season) 季"
            // Identity and synchronization now live in platformLinks.
            unit.links = [:]
            if unique[unit.season] == nil { unique[unit.season] = unit }
        }
        viewingUnits = unique.values.sorted { $0.season < $1.season }
        platformLinks = associations
    }
    var relatedWorkIDs: Set<String> {
        Set([id] + links.values.map(\.id) + Array((sourceRecords ?? [:]).keys) + (platformLinks ?? []).map(\.id) + (viewingUnits ?? []).flatMap { $0.links.values.map(\.id) }).subtracting(retiredAssociationIDs ?? []).union([id])
    }
    @discardableResult mutating func setPlatformAssociation(_ target:Work, replacing oldID:String? = nil, onlyIfMissing:Bool = false) -> Bool {
        guard target.kind == work.kind else { return false }
        retiredAssociationIDs?.remove(target.id)
        if work.kind != .tv || [Catalog.tmdb,.trakt].contains(target.source) {
            guard !onlyIfMissing || links[target.source.rawValue] == nil else { return false }
            associate(target); return true
        }
        prepareUnits()
        if onlyIfMissing && platformLinks?.contains(where:{ $0.target.source == target.source }) == true { return false }
        if let oldID, let index = platformLinks?.firstIndex(where:{ $0.id == oldID }) {
            guard !platformLinks!.contains(where:{ $0.id == target.id && $0.id != oldID }) else { return false }
            platformLinks?[index].target = target
            // A replacement entry needs a new episode map; the old numbering is not transferable.
            if var map = platformLinks?[index].mapping {
                map.episodes = []; map.complete = false; map.platformEpisodeCount = nil
                map.manual = true; map.revision = UUID(); map.reason = "已更换条目，集映射待确认"
                platformLinks?[index].mapping = map
            }
        } else if !platformLinks!.contains(where:{ $0.id == target.id }) {
            platformLinks?.append(PlatformAssociation(target:target))
        }
        links[target.source.rawValue] = platformLinks?.first(where:{ $0.target.source == target.source })?.target
        noEntryPlatforms?.remove(target.source.rawValue)
        return true
    }
    func associationPayload(_ association:PlatformAssociation) throws -> TrackingRecord {
        if association.mapping != nil { return try mappedPayload(association) }
        guard association.scope != .unresolved else { throw APIError.message("请确认 \(association.target.source.title) 条目的对应范围") }
        let seasons = (viewingUnits ?? []).filter(association.includes).sorted { $0.season < $1.season }
        guard !seasons.isEmpty else { throw APIError.message("尚未读取对应季，请打开详情加载季资料") }
        var payload = self
        payload.progressDisabled.remove(association.target.source.rawValue)
        payload.episodeHistory = nil
        switch association.scope {
        case .season:
            let unit = seasons[0]
            payload.progress = unit.contiguousProgress; payload.status = unit.status; payload.season = unit.season
            payload.score = unit.score ?? score; payload.scoreCleared = unit.score == nil ? scoreCleared : false
        case .whole:
            var progress = 0
            for (index,unit) in seasons.enumerated() {
                guard unit.season == index + 1 else { throw APIError.message("整部进度缺少前面的季，请加载季资料或选择对应季") }
                progress += unit.contiguousProgress
                if let total = unit.total, unit.contiguousProgress >= total { continue }
                if unit.total == nil && seasons.dropFirst(index + 1).contains(where:{ $0.progress > 0 }) {
                    throw APIError.message("请先加载第 \(unit.season) 季集数，或将平台条目指定到对应季")
                }
                break
            }
            payload.progress = progress
            payload.status = seasons.allSatisfy { $0.status == "已完成" } ? "已完成" : status == "已完成" ? "进行中" : status
        case .custom:
            throw APIError.message("旧关联尚未迁移，请重新打开作品")
        case .unresolved: break
        }
        return payload
    }
}


extension TrackingRecord {
    mutating func simplifyAssociations() {
        for index in platformLinks?.indices ?? 0..<0 where platformLinks?[index].scope == .custom {
            platformLinks?[index].scope = .whole
            // Ranges remain decode-only migration evidence, never used for new payloads.
        }
    }
    func effectiveRating(for association:PlatformAssociation?) -> (score:Double?, cleared:Bool, source:String) {
        if let association, let map = association.mapping {
            if let error = mappingRatingError(association) { return (nil,false,error) }
            if !map.useOverallRating, let first = map.seasons.first {
                let value = viewingUnits?.first { $0.season == first }?.score ?? score
                return (value,value == nil && scoreCleared == true,map.seasonLabel + "评分")
            }
        }
        if let association, association.mapping == nil, association.scope == .season,
           let unit = viewingUnits?.first(where:{ $0.season == association.season }), let score = unit.score {
            return (score,false,unit.title + "评分")
        }
        return (score,scoreCleared == true,"整部评分")
    }
    func ratingPayload(for association:PlatformAssociation? = nil) -> TrackingRecord {
        var payload = self
        let rating = effectiveRating(for:association)
        payload.score = rating.score; payload.scoreCleared = rating.score == nil
        payload.syncFields = [.rating]; payload.ratingOrigin = rating.source
        return payload
    }
}

/// Public platform averages belong to the linked entry, independently of sync switches and personal scores.
struct PlatformRatingEntry: Identifiable {
    var target: Work
    var scope: AssociationScope
    var season: Int
    var coveredSeasons: [Int]? = nil
    var id: String { target.id }
    var scopeTitle: String {
        switch scope {
        case .whole: return target.kind == .tv ? "整部" : "作品"
        case .season: return season == 0 ? "特别篇" : "第 \(season) 季"
        case .custom, .unresolved: return "待确认对应季"
        }
    }
}
extension Work {
    var publicRating: Double? {
        guard let rating, rating.isFinite, rating > 0, rating <= 10 else { return nil }
        return rating
    }
    var catalogURL: URL? {
        if let value = URL(string:url), ["https","http"].contains(value.scheme?.lowercased() ?? ""), value.host != nil { return value }
        guard let number = Int(remoteID), number > 0 else { return nil }
        let path: String
        switch source {
        case .tmdb: path = "https://www.themoviedb.org/\(kind.rawValue)/\(number)"
        case .trakt: path = "https://trakt.tv/\(kind == .movie ? "movies" : "shows")/\(number)"
        case .anilist: path = "https://anilist.co/\(kind == .manga ? "manga" : "anime")/\(number)"
        case .mal: path = "https://myanimelist.net/\(kind == .manga ? "manga" : "anime")/\(number)"
        case .bangumi: path = "https://bgm.tv/subject/\(number)"
        }
        return URL(string:path)
    }
}
extension TrackingRecord {
    func platformRatingEntries(season selected:Int? = nil) -> [PlatformRatingEntry] {
        var entries: [PlatformRatingEntry] = []
        let associations = platformLinks ?? []
        for association in associations {
            entries.append(PlatformRatingEntry(target:association.target,scope:association.scope,season:association.season,coveredSeasons:association.mapping?.seasons))
        }
        // links holds a compatibility proxy for split platforms; it is not another whole-work entry.
        for target in [work] + links.values.sorted(by:{ $0.id < $1.id }) {
            guard !entries.contains(where:{ $0.id == target.id }),
                  !associations.contains(where:{ $0.target.source == target.source }) else { continue }
            entries.append(PlatformRatingEntry(target:target,scope:.whole,season:1))
        }
        let seasonPlatforms = Set(entries.filter { $0.scope == .season && $0.season == selected }.map { $0.target.source })
        return entries.filter {
            guard let selected else { return true }
            if let covered = $0.coveredSeasons { return covered.contains(selected) }
            if $0.scope == .season { return $0.season == selected }
            return $0.scope == .whole && !seasonPlatforms.contains($0.target.source)
        }.sorted { lhs,rhs in
            let leftPlatform = Catalog.allCases.firstIndex(of:lhs.target.source) ?? 0
            let rightPlatform = Catalog.allCases.firstIndex(of:rhs.target.source) ?? 0
            if leftPlatform != rightPlatform { return leftPlatform < rightPlatform }
            func order(_ item:PlatformRatingEntry) -> Int {
                if item.scope == .whole { return -1 }
                if item.scope != .season { return Int.max }
                return item.season == 0 ? Int.max-1 : item.season
            }
            if order(lhs) != order(rhs) { return order(lhs) < order(rhs) }
            return lhs.id < rhs.id
        }
    }
    mutating func applyPlatformRating(_ fresh:Work) {
        func update(_ value:inout Work) {
            guard value.id == fresh.id else { return }
            value.rating = fresh.publicRating
            if let url = fresh.catalogURL { value.url = url.absoluteString }
        }
        update(&work)
        for key in Array(links.keys) { update(&links[key]!) }
        for index in platformLinks?.indices ?? 0..<0 { update(&platformLinks![index].target) }
    }
}

// Association persistence is independent of tracking drafts, including drafts open
// in another window when a match is edited.
extension TrackingRecord {
    mutating func restoreAssociations(from saved:TrackingRecord) {
        links = saved.links; platformLinks = saved.platformLinks
        noEntryPlatforms = saved.noEntryPlatforms
        confirmedProgress = saved.confirmedProgress
        progressMappings = saved.progressMappings; mappedProgress = saved.mappedProgress
        retiredAssociationIDs = saved.retiredAssociationIDs
        if let units = saved.viewingUnits {
            let edited = viewingUnits ?? []
            viewingUnits = units.map { unit in UnitAssociation(unit).applying(to:edited.first(where:{ $0.id == unit.id })) }
            viewingUnits?.append(contentsOf:edited.filter { item in !units.contains(where:{ $0.id == item.id }) })
        }
    }
}
