import Foundation

struct MatchSeason: Codable, Equatable, Sendable {
    var number: Int
    var name: String
    var date: String
    var count: Int
}
struct MatchCatalog: Sendable {
    var work: Work
    var seasons: [MatchSeason]
    var counts: [Int:Int] { Dictionary(seasons.map { ($0.number,$0.count) },uniquingKeysWith:max) }
    var evidence: MappingEvidence
}
struct PlatformMatchDetails: Sendable {
    var evidence: MappingEvidence
    var episodeCount: Int?
}
extension CatalogAPI {
    func matchingCatalog(_ work:Work) async throws -> MatchCatalog {
        guard work.source == .tmdb, work.kind == .tv else { throw APIError.message("请先确认 TMDB 剧集身份") }
        let root = try await request("https://api.themoviedb.org/3/tv/\(work.remoteID)?language=zh-CN",headers:["Authorization":"Bearer \(credential("tmdb.token"))"]) as? [String:Any] ?? [:]
        guard let returned = Self.tmdbWork(root,kind:.tv), returned.remoteID == work.remoteID,
              let rows = root["seasons"] as? [[String:Any]] else { throw APIError.message("TMDB 季资料不完整，保留现有关联") }
        let seasons = rows.compactMap { row -> MatchSeason? in
            guard let number = row["season_number"] as? Int, let count = row["episode_count"] as? Int, number >= 0, count >= 0 else { return nil }
            return MatchSeason(number:number,name:row["name"] as? String ?? "",date:row["air_date"] as? String ?? "",count:count)
        }
        guard !seasons.isEmpty else { throw APIError.message("TMDB 尚无真实季资料") }
        let text = try Self.matchJSON(["work":["id":returned.id,"title":returned.title,"original":returned.original,"year":returned.year,"overview":String(returned.overview.prefix(1200))],
            "seasons":try JSONSerialization.jsonObject(with:JSONEncoder().encode(seasons))])
        return MatchCatalog(work:returned,seasons:seasons,evidence:MappingEvidence(id:"tmdb_seasons",title:returned.title,url:returned.url,text:text))
    }
    func matchingSeason(_ work:Work, number:Int) async throws -> MappingEvidence {
        let root = try await request("https://api.themoviedb.org/3/tv/\(work.remoteID)/season/\(number)?language=zh-CN",headers:["Authorization":"Bearer \(credential("tmdb.token"))"]) as? [String:Any] ?? [:]
        guard root["season_number"] as? Int == number, let episodes = root["episodes"] as? [[String:Any]] else { throw APIError.message("TMDB 返回的季身份不一致") }
        let values = episodes.map { row in row.filter { ["id","episode_number","season_number","name","air_date","runtime","overview"].contains($0.key) } }
        return MappingEvidence(id:"tmdb_season_\(number)",title:"TMDB 第 \(number) 季集表",url:work.url + "/season/\(number)",text:try Self.matchJSON(["episodes":values]))
    }
    static func matchJSON(_ object:Any) throws -> String {
        String(decoding:try JSONSerialization.data(withJSONObject:object,options:[.sortedKeys]),as:UTF8.self)
    }
    func matchingDetails(_ work:Work) async throws -> PlatformMatchDetails {
        guard let id = Int(work.remoteID), id > 0 else { throw APIError.message("平台条目 ID 无效") }
        var metadata: [String:Any] = [:]
        var count: Int?
        switch work.source {
        case .anilist:
            let query = "query($id:Int){Media(id:$id){id title{romaji english native} synonyms format episodes startDate{year month day} endDate{year month day} description relations{edges{relationType node{id title{romaji english native} format episodes startDate{year month day}}}}}}"
            let root = try await request("https://graphql.anilist.co",method:"POST",body:["query":query,"variables":["id":id]]) as? [String:Any]
            guard let value = (root?["data"] as? [String:Any])?["Media"] as? [String:Any], value["id"] as? Int == id else { throw APIError.message("AniList 返回条目身份不一致") }
            metadata = value; count = value["episodes"] as? Int
        case .mal:
            let root = try await request("https://api.myanimelist.net/v2/anime/\(id)?fields=alternative_titles,start_date,end_date,synopsis,media_type,num_episodes,related_anime",headers:["X-MAL-CLIENT-ID":credential("mal.clientID")]) as? [String:Any] ?? [:]
            guard root["id"] as? Int == id else { throw APIError.message("MAL 返回条目身份不一致") }
            metadata = root.filter { !["main_picture","pictures"].contains($0.key) }; count = root["num_episodes"] as? Int
        case .bangumi:
            let root = try await request("https://api.bgm.tv/v0/subjects/\(id)") as? [String:Any] ?? [:]
            guard root["id"] as? Int == id else { throw APIError.message("Bangumi 返回条目身份不一致") }
            metadata = root.filter { ["id","name","name_cn","date","summary","eps","total_episodes","infobox","platform"].contains($0.key) }
            var episodes: [[String:Any]] = []
            var total = 0
            for page in 0..<5 {
                let response = try await request("https://api.bgm.tv/v0/episodes?subject_id=\(id)&type=0&limit=100&offset=\(page*100)") as? [String:Any] ?? [:]
                guard let rows = response["data"] as? [[String:Any]], let size = response["total"] as? Int else { throw APIError.message("Bangumi 集表不完整") }
                total = size
                episodes += rows.map { $0.filter { ["id","sort","ep","name","name_cn","airdate","type","desc"].contains($0.key) } }
                if episodes.count >= total || rows.isEmpty { break }
            }
            metadata["episodes"] = episodes; metadata["episode_list_complete"] = episodes.count == total
            // API eps describes regular episodes; specials are not silently counted into this cursor.
            count = root["eps"] as? Int
        default:
            let fresh = try await details(work)
            metadata = ["id":fresh.id,"title":fresh.title,"original":fresh.original,"overview":fresh.overview,"year":fresh.year]
        }
        if let value = count, value <= 0 { count = nil }
        return PlatformMatchDetails(evidence:MappingEvidence(id:"detail_" + work.id,title:work.title,url:work.catalogURL?.absoluteString,text:try Self.matchJSON(metadata)),episodeCount:count)
    }
}
