import Foundation

enum MediaKind: String, CaseIterable, Codable, Identifiable, Sendable {
    case anime = "ANIME", manga = "MANGA"
    var id: String { rawValue }
    var title: String { self == .anime ? "动画" : "书籍" }
    var unit: String { self == .anime ? "集" : "话" }
}

enum ListStatus: String, CaseIterable, Codable, Identifiable, Sendable {
    case current = "CURRENT", planning = "PLANNING", completed = "COMPLETED"
    case paused = "PAUSED", dropped = "DROPPED", repeating = "REPEATING"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .current: "进行中"
        case .planning: "计划中"
        case .completed: "已完成"
        case .paused: "已暂停"
        case .dropped: "已放弃"
        case .repeating: "重温中"
        }
    }
    var icon: String {
        switch self {
        case .current: "play.circle"
        case .planning: "bookmark"
        case .completed: "checkmark.circle"
        case .paused: "pause.circle"
        case .dropped: "minus.circle"
        case .repeating: "repeat"
        }
    }
}

enum BrowseSort: String, CaseIterable, Identifiable, Sendable {
    case trending = "TRENDING_DESC", popular = "POPULARITY_DESC", score = "SCORE_DESC", newest = "START_DATE_DESC"
    case oldest = "START_DATE", title = "TITLE_ROMAJI", favourites = "FAVOURITES_DESC", lowScore = "SCORE", unpopular = "POPULARITY"
    var id: String { rawValue }
    var title: String {
        switch self { case .trending: "正在流行"; case .popular: "人气排行"; case .score: "高分作品"; case .newest: "最新发行"; case .oldest: "最早发行"; case .title: "名称顺序"; case .favourites: "收藏最多"; case .lowScore: "评分升序"; case .unpopular: "人气升序" }
    }
}

struct AniListFilters: Equatable, Sendable {
    var year: Int?
    var season: String?
    var format: String?
    var status: String?
    var genre: String?
    var allAnime = false
    var minimumScore: Int?
    var country: String?
    var sort: BrowseSort = .popular
    var key: String { "\(year ?? 0)|\(season ?? "")|\(format ?? "")|\(status ?? "")|\(genre ?? "")|\(sort.rawValue)|\(allAnime)|\(minimumScore ?? 0)|\(country ?? "")" }
}

struct Media: Codable, Hashable, Identifiable, Sendable {
    struct Title: Codable, Hashable, Sendable {
        var romaji: String?
        var english: String?
        var native: String?
        var localized: String? = nil
        var display: String { localized ?? native ?? english ?? romaji ?? "未命名作品" }
        var subtitle: String { english ?? romaji ?? "" }
    }
    struct Cover: Codable, Hashable, Sendable { var large: String?; var extraLarge: String? }
    var id: Int
    var title: Title
    var coverImage: Cover?
    var bannerImage: String?
    var description: String?
    var format: String?
    var status: String?
    var episodes: Int?
    var volumes: Int?
    var chapters: Int?
    var averageScore: Int?
    var seasonYear: Int?
    var genres: [String]?
    var siteUrl: String?
    var type: MediaKind?
    var total: Int? { type == .manga ? chapters : episodes }
    var unit: String { type?.unit ?? "集" }
    var coverURL: URL? { (coverImage?.extraLarge ?? coverImage?.large).flatMap(URL.init(string:)) }
    var metadata: String {
        [seasonYear.map(String.init), format?.replacingOccurrences(of: "_", with: " "), total.map { "\($0)\(unit)" }]
            .compactMap { $0 }.joined(separator: " · ")
    }
    var releaseStatus: String {
        switch status {
        case "FINISHED": "已完结"
        case "RELEASING": "连载中"
        case "NOT_YET_RELEASED": "未开播 / 未发行"
        case "CANCELLED": "已取消"
        case "HIATUS": "休刊中"
        default: "暂未公布"
        }
    }
}

struct ListEntry: Codable, Hashable, Identifiable, Sendable {
    var id: Int
    var status: ListStatus
    var progress: Int
    var score: Double?
    var media: Media
}
struct EntryValue: Codable, Sendable {
    var id: Int
    var status: ListStatus
    var progress: Int
    var score: Double?
}
struct Viewer: Codable, Sendable {
    struct Avatar: Codable, Sendable { var large: String? }
    var id: Int
    var name: String
    var avatar: Avatar?
}

struct APIPage: Sendable { var media: [Media]; var hasNextPage: Bool }

struct OAuthCallback {
    static let scheme = "anishelf"
    static let redirect = "anishelf://oauth"
    static func token(from url: URL, expectedState: String) throws -> String {
        guard url.scheme == scheme, url.host == "oauth" else { throw APIError.message("登录回调地址不匹配。") }
        let parts = URLComponents(string: "?" + (url.fragment ?? ""))?.queryItems ?? []
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let values = Dictionary((parts + query).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
        guard values["state"] == expectedState else { throw APIError.message("登录会话不匹配，请重新登录。") }
        if let error = values["error"] { throw APIError.message("AniList 未完成授权：\(error)") }
        guard let token = values["access_token"], !token.isEmpty else { throw APIError.message("授权未返回访问令牌。") }
        return token
    }
}

enum APIError: LocalizedError {
    case unauthorized, rateLimited(Int), message(String)
    var errorDescription: String? {
        switch self {
        case .unauthorized: "登录已过期，请重新授权 AniList。"
        case .rateLimited(let seconds): "AniList 请求次数已达上限，请在 \(seconds) 秒后重试。"
        case .message(let message): message
        }
    }
}

// Public book metadata stays independent of personal library records.
struct BookDetails: Codable, Sendable {
    struct DateParts: Codable, Sendable {
        var year: Int?; var month: Int?; var day: Int?
        var display: String { [year,month,day].compactMap { $0.map(String.init) }.joined(separator:"-") }
    }
    struct Person: Codable, Identifiable, Sendable {
        struct Name: Codable, Sendable { var full: String?; var native: String? }
        struct Image: Codable, Sendable { var large: String? }
        var id: Int; var name: Name; var image: Image?; var description: String?; var siteUrl: String?
        var displayName: String { name.native ?? name.full ?? "未命名" }
    }
    struct PersonEdge: Codable, Identifiable, Sendable {
        var role: String?; var node: Person
        var id: String { "\(node.id):\(role ?? "")" }
        var roleTitle: String {
            ["MAIN":"主角","SUPPORTING":"配角","BACKGROUND":"背景角色","Story & Art":"原作与作画","Story":"原作","Art":"作画","Original Story":"原作","Illustration":"插画","Character Design":"角色设计"][role ?? ""] ?? role ?? ""
        }
    }
    struct People: Codable, Sendable {
        struct PageInfo: Codable, Sendable { var hasNextPage: Bool? }
        var edges: [PersonEdge]; var pageInfo: PageInfo?
    }
    struct Relation: Codable, Identifiable, Sendable {
        var relationType: String?; var node: Media
        var id: Int { node.id }
        var title: String {
            ["ADAPTATION":"改编","PREQUEL":"前传","SEQUEL":"续作","PARENT":"本篇","SIDE_STORY":"外传","CHARACTER":"共同角色","SUMMARY":"总集篇","ALTERNATIVE":"其他版本","SPIN_OFF":"衍生作品","SOURCE":"原作","COMPILATION":"合集","CONTAINS":"收录作品","SAME_UNIVERSE":"同一世界观","OTHER":"其他关联"][relationType ?? ""] ?? "关联作品"
        }
    }
    struct Relations: Codable, Sendable { var edges: [Relation] }
    struct ExternalLink: Codable, Identifiable, Sendable { var id: Int; var site: String; var url: String? }
    var id: Int; var title: Media.Title; var format: String?; var status: String?
    var startDate: DateParts?; var endDate: DateParts?; var chapters: Int?; var volumes: Int?
    var genres: [String]?; var synonyms: [String]?; var characters: People?; var staff: People?
    var relations: Relations?; var externalLinks: [ExternalLink]?
    var releaseStatus: String {
        ["FINISHED":"已完结","RELEASING":"连载中","NOT_YET_RELEASED":"未发行","CANCELLED":"已取消","HIATUS":"休刊中"][status ?? ""] ?? ""
    }
}
