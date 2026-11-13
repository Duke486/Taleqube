import Foundation

struct ProgressSyncSkipped: LocalizedError {
    var errorDescription: String? { "集匹配为 0 集，已跳过进度同步" }
}

/// Versioned independently from legacy custom ranges. An unresolved new mapping must never
/// be migrated to a whole-series link by prepareUnits().
struct MappingEvidence: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var title: String
    var url: String?
    var text: String
}
struct EpisodeCorrespondence: Codable, Equatable, Identifiable, Sendable {
    var platformEpisodes: [Int]
    var tmdbEpisodes: [EpisodeAddress]
    var evidenceIDs: [String] = []
    var id: String { platformEpisodes.map(String.init).joined(separator:",") }
}
struct ContentMapping: Codable, Equatable, Sendable {
    var version = 1
    var revision = UUID()
    var tmdbID: String
    var confirmed = false
    var seasons: [Int] = []
    var coverage = "unknown" // full / partial / unknown
    var episodes: [EpisodeCorrespondence] = []
    var platformEpisodeCount: Int?
    var complete = false // all platform content is accounted for, not merely all fetched rows
    var manual = false
    var useOverallRating = false
    var evidence: [MappingEvidence] = []
    var reason = "对应范围待确认"
    var updatedAt = Date()
    var matchedEpisodeCount: Int { Set(episodes.flatMap(\.platformEpisodes)).count }

    var seasonLabel: String {
        seasons.sorted().map { $0 == 0 ? "特别篇" : "第 \($0) 季" }.joined(separator:"、")
    }
    func validate(seasonCounts:[Int:Int], requireEvidence:Bool = false) throws {
        guard version == 1, !tmdbID.isEmpty, Set(seasons).count == seasons.count,
              seasons.allSatisfy({ seasonCounts[$0] != nil }),
              ["full","partial","unknown"].contains(coverage),
              !confirmed || !seasons.isEmpty else { throw APIError.message("对应季不在当前 TMDB 季列表中") }
        if let count = platformEpisodeCount, !(1...100000).contains(count) { throw APIError.message("平台集数无效") }
        var seenPlatform = Set<Int>(), seenTMDB = Set<EpisodeAddress>()
        let evidenceIDs = Set(evidence.map(\.id))
        for group in episodes {
            guard confirmed, !group.platformEpisodes.isEmpty, !group.tmdbEpisodes.isEmpty,
                  group.platformEpisodes.count == 1 || group.tmdbEpisodes.count == 1 else {
                throw APIError.message("集映射为空或包含多对多关系；连续对应须逐集输出独立映射组")
            }
            guard !requireEvidence || (!group.evidenceIDs.isEmpty && group.evidenceIDs.allSatisfy(evidenceIDs.contains)) else {
                throw APIError.message("集映射缺少有效依据；每组必须引用已提供的 evidenceIDs")
            }
            for number in group.platformEpisodes {
                guard number > 0, number <= (platformEpisodeCount ?? 100000), seenPlatform.insert(number).inserted else { throw APIError.message("平台集编号越界或重复") }
            }
            for address in group.tmdbEpisodes {
                guard seasons.contains(address.season) else {
                    throw APIError.message("S\(address.season)E\(address.number) 不属于声明的 seasons=\(seasons)；跨季对应须声明全部涉及季")
                }
                guard address.number > 0, address.number <= (seasonCounts[address.season] ?? 0) else {
                    throw APIError.message("S\(address.season)E\(address.number) 越界；该季集数=\(seasonCounts[address.season] ?? 0)，不得将特别篇追加到正片季末")
                }
                guard seenTMDB.insert(address).inserted else {
                    throw APIError.message("S\(address.season)E\(address.number) 重复；需要多对一时合并为同一映射组")
                }
            }
        }
        if complete {
            guard let total = platformEpisodeCount, seenPlatform.count == total,
                  seenPlatform == Set(1...total) else { throw APIError.message("完整映射仍有缺集") }
        }
    }
}

extension TrackingRecord {
    var mappingSeasonCounts: [Int:Int] {
        Dictionary((viewingUnits ?? []).map { ($0.season,$0.total ?? 0) },uniquingKeysWith:max)
    }
    func mappingRatingError(_ association:PlatformAssociation?) -> String? {
        guard let association else { return nil }
        guard let map = association.mapping else { return association.scope == .unresolved ? "评分等待季归属确认" : nil }
        guard map.tmdbID == (links["tmdb"]?.remoteID ?? work.remoteID) else { return "TMDB 身份已改变，请重新匹配" }
        guard map.confirmed, !map.seasons.isEmpty else { return "评分等待季归属确认" }
        if map.useOverallRating { return score == nil && scoreCleared != true ? "请先设置整部评分" : nil }
        if map.seasons.count > 1 {
            let values = map.seasons.map { number in viewingUnits?.first { $0.season == number }?.score ?? score }
            if values.contains(where:{ $0 == nil }) { return "跨季条目存在未评分的季；可选择使用整部评分" }
            if Set(values.compactMap { $0 }).count > 1 { return "跨季评分不同；请选择使用整部评分或暂停评分同步" }
        }
        return nil
    }
    func checkedRatingPayload(for association:PlatformAssociation?) throws -> TrackingRecord {
        if let error = mappingRatingError(association) { throw APIError.message(error) }
        return ratingPayload(for:association)
    }
    func mappedPayload(_ association:PlatformAssociation, fields:Set<SyncField> = [.progress,.status]) throws -> TrackingRecord {
        guard association.mapping?.matchedEpisodeCount ?? 0 > 0 else { throw ProgressSyncSkipped() }
        guard let map = association.mapping, map.confirmed, map.tmdbID == (links["tmdb"]?.remoteID ?? work.remoteID) else {
            throw APIError.message("请先确认当前 TMDB 作品的内容映射")
        }
        try map.validate(seasonCounts:mappingSeasonCounts)
        var completed = Set<Int>(), mapped = Set<Int>()
        for group in map.episodes {
            mapped.formUnion(group.platformEpisodes)
            let watched = group.tmdbEpisodes.allSatisfy { address in
                guard let unit = viewingUnits?.first(where:{ $0.season == address.season }),
                      let index = unit.episodeIndex(season:address.season,number:address.number) else { return false }
                return unit.hasWatched(index)
            }
            if watched { completed.formUnion(group.platformEpisodes) }
        }
        var progress = 0
        for number in mapped.sorted() {
            guard completed.contains(number) else { break }
            progress = number
        }
        var payload = self
        payload.syncFields = fields; payload.episodeHistory = nil; payload.progress = progress
        payload.syncMappedEpisodes = mapped.sorted()
        payload.syncWatchedEpisodes = completed.sorted()
        payload.progressDisabled.remove(association.target.source.rawValue)
        payload.status = map.complete && progress == map.platformEpisodeCount ? "已完成" : progress > 0 ? "进行中" : "计划中"
        if fields.contains(.rating) {
            let rating = try checkedRatingPayload(for:association)
            payload.score = rating.score; payload.scoreCleared = rating.scoreCleared; payload.ratingOrigin = rating.ratingOrigin
        }
        return payload
    }
    mutating func addPlatformSelections(_ targets:[Work], replacing:String? = nil) {
        for target in targets {
            let existing = platformLinks?.contains { $0.id == target.id } == true
            guard setPlatformAssociation(target,replacing:replacing) else { continue }
            if work.kind == .tv, ![Catalog.tmdb,.trakt].contains(target.source), !existing, replacing == nil,
               let index = platformLinks?.firstIndex(where:{ $0.id == target.id }) {
                platformLinks?[index].scope = .unresolved
                platformLinks?[index].mapping = ContentMapping(tmdbID:links["tmdb"]?.remoteID ?? (work.source == .tmdb ? work.remoteID : "pending"))
            }
        }
    }
    mutating func applyMatching(_ result:SeasonMatchResult, platform:Catalog, replace:Bool, reconsideredIDs:Set<String> = []) throws {
        guard result.associations.allSatisfy({ $0.target.source == platform && $0.mapping?.confirmed == true }) else {
            throw APIError.message("匹配结果包含未确认或错误平台的关联")
        }
        guard Set(result.associations.map(\.id)).isDisjoint(with:result.excludedIDs) else {
            throw APIError.message("匹配结果同时包含关联和排除同一条目")
        }
        prepareUnits()
        let excluded = Set(result.excludedIDs)
        let removed = Set((platformLinks ?? []).filter {
            $0.target.source == platform && excluded.contains($0.id) && (replace || $0.mapping?.manual != true)
        }.map(\.id))
        retiredAssociationIDs = (retiredAssociationIDs ?? []).union(removed)
        platformLinks?.removeAll { removed.contains($0.id) }
        if let target = links[platform.rawValue], removed.contains(target.id) { links[platform.rawValue] = nil }
        // Explicit per-item retry can replace that manual mapping, without unlocking its peers.
        let retried = result.associations.filter { reconsideredIDs.contains($0.id) }
        applyMatching(retried,platform:platform,replace:false,updateConfirmed:true)
        applyMatching(result.associations,platform:platform,replace:replace && result.canReplaceAssociations,updateConfirmed:replace)
    }
    /// One mutation for the entire platform result; replacement removes absent old links as well.
    mutating func applyMatching(_ linksToApply:[PlatformAssociation], platform:Catalog, replace:Bool, updateConfirmed:Bool = false) {
        prepareUnits()
        if replace {
            let oldIDs = Set((platformLinks ?? []).filter { $0.target.source == platform }.map(\.id))
                .union((sourceRecords ?? [:]).values.filter { $0.work.source == platform }.map(\.id))
            retiredAssociationIDs = (retiredAssociationIDs ?? []).union(oldIDs)
            platformLinks?.removeAll { $0.target.source == platform }
        }
        retiredAssociationIDs = (retiredAssociationIDs ?? []).subtracting(linksToApply.map(\.id))
        for association in linksToApply {
            if let index = platformLinks?.firstIndex(where:{ $0.id == association.id }) {
                let prior = platformLinks?[index].mapping
                let fillsManualScope = prior?.manual == true && prior?.episodes.isEmpty == true && association.mapping?.manual == true && prior?.seasons.sorted() == association.mapping?.seasons.sorted()
                if replace || updateConfirmed || prior?.manual != true || fillsManualScope { platformLinks?[index] = association }
            } else { platformLinks?.append(association) }
        }
        links[platform.rawValue] = platformLinks?.first { $0.target.source == platform }?.target
        if links[platform.rawValue] != nil { noEntryPlatforms?.remove(platform.rawValue) }
    }
}
