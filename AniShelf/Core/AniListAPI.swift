import Foundation

actor AniListAPI {
    static let shared = AniListAPI()
    static let authorizationRejected = Notification.Name("AniShelf.anilistAuthorizationRejected")
    private let session: URLSession
    init(session: URLSession = .shared) { self.session = session }

    // Shared by public queries and the authenticated list. No client secret is used.
    static let mediaFields = """
    id type title { romaji english native }
    coverImage { large extraLarge } bannerImage description(asHtml: false)
    format status episodes chapters volumes averageScore seasonYear genres siteUrl
    """
    private struct Envelope<T: Decodable>: Decodable {
        struct Failure: Decodable { var message: String; var status: Int? }
        var data: T?
        var errors: [Failure]?
    }
    private func perform<T: Decodable>(_ query: String, variables: [String: Any] = [:], token: String? = nil) async throws -> T {
        var request = URLRequest(url: URL(string: "https://graphql.anilist.co")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 25
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONSerialization.data(withJSONObject: ["query": query, "variables": variables])
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.message("服务器没有返回 HTTP 响应。") }
        if http.statusCode == 401 {
            NotificationCenter.default.post(name:Self.authorizationRejected,object:token)
            throw APIError.unauthorized
        }
        if http.statusCode == 429 { throw APIError.rateLimited(Int(http.value(forHTTPHeaderField: "Retry-After") ?? "60") ?? 60) }
        guard (200..<300).contains(http.statusCode) else { throw APIError.message("AniList 服务返回 HTTP \(http.statusCode)。") }
        let result = try JSONDecoder().decode(Envelope<T>.self, from: data)
        if let errors = result.errors, !errors.isEmpty {
            if errors.contains(where: { $0.status == 401 }) {
                NotificationCenter.default.post(name:Self.authorizationRejected,object:token)
                throw APIError.unauthorized
            }
            throw APIError.message(errors.map(\.message).joined(separator: "\n"))
        }
        guard let value = result.data else { throw APIError.message("AniList 返回了空数据。") }
        return value
    }

    func deleteListEntry(mediaID:Int, token:String) async throws {
        let viewer = try await viewer(token:token)
        struct Lookup: Decodable { struct Entry: Decodable { let id:Int }; let MediaList:Entry? }
        let lookup:Lookup = try await perform("query($media:Int!,$user:Int!){MediaList(mediaId:$media,userId:$user){id}}",variables:["media":mediaID,"user":viewer.id],token:token)
        guard let entry = lookup.MediaList else { return }
        struct Result: Decodable { struct Deleted: Decodable { let deleted:Bool }; let DeleteMediaListEntry:Deleted }
        let result:Result = try await perform("mutation($id:Int!){DeleteMediaListEntry(id:$id){deleted}}",variables:["id":entry.id],token:token)
        guard result.DeleteMediaListEntry.deleted else { throw APIError.message("AniList 未确认删除，请重试") }
    }

    func browse(kind: MediaKind, search: String, sort: BrowseSort, page: Int, filters: AniListFilters = AniListFilters(), excludedFormat: String? = nil) async throws -> APIPage {
        struct Result: Decodable {
            struct PageValue: Decodable {
                struct Info: Decodable { var hasNextPage: Bool }
                var media: [Media]; var pageInfo: Info
            }
            var Page: PageValue
        }
        var variables: [String: Any] = ["type": kind.rawValue, "sort": [sort.rawValue], "page": page]
        if !search.isEmpty { variables["search"] = search }
        if let year = filters.year { if kind == .anime { variables["year"] = year } else { variables["startDate"] = "\(year)%" } }
        if kind == .anime, let season = filters.season { variables["season"] = season }
        if let format = filters.format { variables["format"] = format }
        if let excludedFormat { variables["excludedFormat"] = excludedFormat }
        if let status = filters.status { variables["status"] = status }
        if let genre = filters.genre { variables["genre"] = genre }
        if let score = filters.minimumScore { variables["minimumScore"] = score - 1 }
        if let country = filters.country { variables["country"] = country }
        let result: Result = try await perform("""
        query Browse($type: MediaType!, $search: String, $sort: [MediaSort], $page: Int!, $year: Int, $season: MediaSeason, $format: MediaFormat, $excludedFormat: MediaFormat, $status: MediaStatus, $genre: String, $startDate: String, $minimumScore: Int, $country: CountryCode) {
          Page(page: $page, perPage: 30) {
            pageInfo { hasNextPage }
            media(type: $type, search: $search, sort: $sort, seasonYear: $year, season: $season, format: $format, format_not: $excludedFormat, status: $status, genre: $genre, startDate_like: $startDate, averageScore_greater: $minimumScore, countryOfOrigin: $country) { \(Self.mediaFields) }
          }
        }
        """, variables: variables)
        return APIPage(media: result.Page.media, hasNextPage: result.Page.pageInfo.hasNextPage)
    }

    private static let personFields = "id name { full native } image { large } description(asHtml:false) siteUrl"
    func bookDetails(id:Int) async throws -> BookDetails {
        struct Result: Decodable { var Media: BookDetails? }
        let result:Result = try await perform("""
        query($id:Int!){ Media(id:$id,type:MANGA){
          id title{romaji english native} format status startDate{year month day} endDate{year month day}
          chapters volumes genres synonyms externalLinks{id site url}
          characters(sort:[ROLE,RELEVANCE,ID],perPage:12){pageInfo{hasNextPage} edges{role node{\(Self.personFields)}}}
          staff(sort:[RELEVANCE,ID],perPage:12){pageInfo{hasNextPage} edges{role node{\(Self.personFields)}}}
          relations{edges{relationType(version:3) node{\(Self.mediaFields)}}}
        }}
        """,variables:["id":id])
        guard let media = result.Media, media.id == id else { throw APIError.message("未找到对应书籍") }
        return media
    }
    func bookPeople(id:Int,staff:Bool,page:Int) async throws -> BookDetails.People {
        struct Container: Decodable { var characters: BookDetails.People?; var staff: BookDetails.People? }
        struct Result: Decodable { var Media: Container? }
        let field = staff ? "staff" : "characters"
        let sort = staff ? "[RELEVANCE,ID]" : "[ROLE,RELEVANCE,ID]"
        let result:Result = try await perform("query($id:Int!,$page:Int!){Media(id:$id,type:MANGA){\(field)(sort:\(sort),page:$page,perPage:12){pageInfo{hasNextPage} edges{role node{\(Self.personFields)}}}}}",variables:["id":id,"page":page])
        guard let value = staff ? result.Media?.staff : result.Media?.characters else { throw APIError.message("人物资料加载失败") }
        return value
    }
    func personWorks(id:Int,staff:Bool,page:Int) async throws -> APIPage {
        struct Connection: Decodable { struct PageInfo: Decodable { var hasNextPage:Bool }; var nodes:[Media]; var pageInfo:PageInfo }
        struct Person: Decodable { var media:Connection?; var staffMedia:Connection? }
        struct Result: Decodable { var Character:Person?; var Staff:Person? }
        let root = staff ? "Staff" : "Character", field = staff ? "staffMedia" : "media"
        let result:Result = try await perform("query($id:Int!,$page:Int!){\(root)(id:$id){\(field)(page:$page,perPage:12,sort:[START_DATE_DESC]){pageInfo{hasNextPage} nodes{\(Self.mediaFields)}}}}",variables:["id":id,"page":page])
        guard let value = staff ? result.Staff?.staffMedia : result.Character?.media else { throw APIError.message("参与作品加载失败") }
        return APIPage(media:value.nodes,hasNextPage:value.pageInfo.hasNextPage)
    }

    func viewer(token: String) async throws -> Viewer {
        struct Result: Decodable { var Viewer: Viewer }
        let result: Result = try await perform("query { Viewer { id name avatar { large } } }", token: token)
        return result.Viewer
    }

    func library(userID: Int, kind: MediaKind, token: String) async throws -> [ListEntry] {
        struct Result: Decodable {
            struct Collection: Decodable {
                struct ListGroup: Decodable { var entries: [ListEntry]? }
                var lists: [ListGroup]?
                var hasNextChunk: Bool?
            }
            var MediaListCollection: Collection?
        }
        var entries: [ListEntry] = []
        var chunk = 1
        while true {
            try Task.checkCancellation()
            let result: Result = try await perform("""
            query Library($userId: Int!, $type: MediaType!, $chunk: Int!) {
              MediaListCollection(userId: $userId, type: $type, chunk: $chunk, perChunk: 500) {
                hasNextChunk
                lists { entries { id status progress score(format: POINT_100) media { \(Self.mediaFields) } } }
              }
            }
            """, variables: ["userId": userID, "type": kind.rawValue, "chunk": chunk], token: token)
            entries += (result.MediaListCollection?.lists ?? []).flatMap { $0.entries ?? [] }
            guard result.MediaListCollection?.hasNextChunk == true else { break }
            chunk += 1
        }
        var seen = Set<Int>()
        return entries.filter { seen.insert($0.id).inserted }
            .sorted { $0.media.title.display.localizedStandardCompare($1.media.title.display) == .orderedAscending }
    }

    func entry(mediaID: Int, token: String) async throws -> EntryValue? {
        // MediaList returns a GraphQL 404 for absent entries. Query through Media instead.
        struct MediaResult: Decodable {
            struct Value: Decodable { var mediaListEntry: EntryValue? }
            var Media: Value?
        }
        let result: MediaResult = try await perform("""
        query Entry($id: Int!) {
          Media(id: $id) { mediaListEntry { id status progress score(format: POINT_100) } }
        }
        """, variables: ["id": mediaID], token: token)
        return result.Media?.mediaListEntry
    }

    func save(mediaID: Int, status: ListStatus, progress: Int, score: Double, token: String) async throws -> EntryValue {
        struct Result: Decodable { var SaveMediaListEntry: EntryValue }
        let result: Result = try await perform("""
        mutation Save($id: Int!, $status: MediaListStatus!, $progress: Int!, $score: Int!) {
          SaveMediaListEntry(mediaId: $id, status: $status, progress: $progress, scoreRaw: $score) {
            id status progress score(format: POINT_100)
          }
        }
        """, variables: ["id": mediaID, "status": status.rawValue, "progress": progress, "score": Int(score)], token: token)
        return result.SaveMediaListEntry
    }
}
