import Foundation

struct GalleryImage: Codable, Sendable, Identifiable, Hashable {
    var url: String
    var caption: String
    var id: String { url }
}
struct MediaSeason: Codable, Sendable, Identifiable, Hashable {
    var number: Int
    var title: String
    var episodeCount: Int? = nil
    var overview: String? = nil
    var id: Int { number }
}
struct MediaEpisode: Identifiable, Hashable {
    var number: Int
    var title: String
    var image: String
    var overview: String
    var season: Int = 1
    var id: String { "\(season):\(number)" }
}
struct MediaArtwork: Codable, Sendable {
    var images: [GalleryImage] = []
    var seasons: [MediaSeason] = []
}

extension CatalogAPI {
    static func imageURL(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "" }
        return raw.hasPrefix("https://") ? raw : "https://" + raw.replacingOccurrences(of:"http://",with:"").trimmingCharacters(in:CharacterSet(charactersIn:"/"))
    }
    static func tmdbWork(_ x:[String:Any], kind:WorkKind) -> Work? {
        guard let id = x["id"] as? Int else { return nil }
        return Work(source:.tmdb,remoteID:String(id),kind:kind,title:x["title"] as? String ?? x["name"] as? String ?? "",original:x["original_title"] as? String ?? x["original_name"] as? String ?? "",overview:x["overview"] as? String ?? "",image:(x["poster_path"] as? String).map { "https://image.tmdb.org/t/p/w500\($0)" } ?? "",year:String((x["release_date"] as? String ?? x["first_air_date"] as? String ?? "").prefix(4)),rating:x["vote_average"] as? Double,url:"https://www.themoviedb.org/\(kind.rawValue)/\(id)",tmdbID:id)
    }
    func tmdbDetails(id:Int,kind:WorkKind) async throws -> Work {
        guard kind != .manga, id > 0 else { throw APIError.message("无效的 TMDB 作品编号") }
        let token = credential("tmdb.token")
        guard !token.isEmpty else { throw APIError.message("请在设置中连接 TMDB，以获取背景图和剧集资料。") }
        let data = try await request("https://api.themoviedb.org/3/\(kind.rawValue)/\(id)?language=zh-CN",headers:["Authorization":"Bearer \(token)"]) as? [String:Any] ?? [:]
        guard let work = Self.tmdbWork(data,kind:kind), work.remoteID == String(id) else { throw APIError.message("TMDB 未返回对应作品") }
        return work
    }
    func artwork(_ work: Work) async throws -> MediaArtwork {
        try Task.checkCancellation()
        let revision = artworkGenerations[work.id,default:UUID()]
        artworkGenerations[work.id] = revision
        if let cached = await ArtworkMetadataCache.shared.value(for:work.id),
           !(work.source == .tmdb && work.kind == .tv && cached.seasons.contains(where:{ $0.overview == nil })) {
            guard artworkGenerations[work.id] == revision else { throw CancellationError() }
            return cached
        }
        guard artworkGenerations[work.id] == revision else { throw CancellationError() }
        if let pending = artworkRequests[work.id] {
            let value = try await pending.value
            try Task.checkCancellation()
            guard artworkGenerations[work.id] == revision, !pending.isCancelled else { throw CancellationError() }
            return value
        }
        let task = Task { try await self.fetchArtwork(work) }
        artworkRequests[work.id] = task
        defer { if artworkGenerations[work.id] == revision { artworkRequests[work.id] = nil } }
        let value = try await task.value
        guard artworkGenerations[work.id] == revision, !task.isCancelled else { throw CancellationError() }
        if artworkGenerations[work.id] == revision, !task.isCancelled {
            await ArtworkMetadataCache.shared.store(value,for:work.id)
        }
        try Task.checkCancellation()
        guard artworkGenerations[work.id] == revision else { throw CancellationError() }
        return value
    }
    func invalidateArtwork(_ ids:Set<String>) async {
        for id in ids { artworkGenerations[id] = UUID(); artworkRequests.removeValue(forKey:id)?.cancel() }
        await ArtworkMetadataCache.shared.remove(ids)
    }
    private func fetchArtwork(_ work: Work) async throws -> MediaArtwork {
        if work.source == .trakt, let id = work.tmdbID, !credential("tmdb.token").isEmpty {
            var tmdb = work; tmdb.source = .tmdb; tmdb.remoteID = String(id)
            do { return try await artwork(tmdb) } catch { /* Keep Trakt artwork as fallback. */ }
        }
        if work.source == .tmdb {
            let data = try await request("https://api.themoviedb.org/3/\(work.kind.rawValue)/\(work.remoteID)?language=zh-CN&append_to_response=images&include_image_language=zh,en,null",headers:["Authorization":"Bearer \(credential("tmdb.token"))"]) as? [String:Any] ?? [:]
            return Self.tmdbArtwork(data)
        }
        if work.source == .trakt {
            let type = work.kind == .movie ? "movies" : "shows"
            let data = try await request("https://api.trakt.tv/\(type)/\(work.remoteID)?extended=full",headers:traktHeaders()) as? [String:Any] ?? [:]
            let images = data["images"] as? [String:[String]] ?? [:]
            var artwork = MediaArtwork(images:Array((images["fanart"] ?? []).prefix(12)).map { GalleryImage(url:Self.imageURL($0),caption:"背景剧照") })
            if work.kind == .tv {
                let seasons = try await request("https://api.trakt.tv/shows/\(work.remoteID)/seasons?extended=full",headers:traktHeaders()) as? [[String:Any]] ?? []
                artwork.seasons = seasons.compactMap { row in
                    guard let number = row["number"] as? Int else { return nil }
                    return MediaSeason(number:number,title:number == 0 ? "特别篇" : "第 \(number) 季",episodeCount:row["episode_count"] as? Int,overview:row["overview"] as? String ?? "")
                }.sorted { $0.number < $1.number }
            }
            return artwork
        }
        if let backdrop = work.backdrop, !backdrop.isEmpty { return MediaArtwork(images:[GalleryImage(url:backdrop,caption:"背景海报")]) }
        return MediaArtwork()
    }
    static func tmdbArtwork(_ data:[String:Any]) -> MediaArtwork {
        let images = data["images"] as? [String:Any] ?? [:]
        let paths = [data["backdrop_path"] as? String].compactMap { $0 } + (images["backdrops"] as? [[String:Any]] ?? []).compactMap { $0["file_path"] as? String }
        var seen = Set<String>()
        let gallery = Array(paths.filter { !$0.isEmpty && seen.insert($0).inserted }.prefix(16)).map { GalleryImage(url:"https://image.tmdb.org/t/p/w1280\($0)",caption:"背景剧照") }
        let seasons = (data["seasons"] as? [[String:Any]] ?? []).compactMap { row -> MediaSeason? in
            guard let number = row["season_number"] as? Int else { return nil }
            return MediaSeason(number:number,title:row["name"] as? String ?? "第 \(number) 季",episodeCount:row["episode_count"] as? Int,overview:row["overview"] as? String ?? "")
        }.sorted { $0.number < $1.number }
        return MediaArtwork(images:gallery,seasons:seasons)
    }
    func episodes(_ work:Work, season:Int) async throws -> [MediaEpisode] {
        guard work.kind == .tv else { return [] }
        if work.source == .trakt, let id = work.tmdbID, !credential("tmdb.token").isEmpty {
            var tmdb = work; tmdb.source = .tmdb; tmdb.remoteID = String(id)
            do { return try await episodes(tmdb,season:season) } catch { /* Fall back to the source's episode images. */ }
        }
        if work.source == .tmdb {
            let data = try await request("https://api.themoviedb.org/3/tv/\(work.remoteID)/season/\(season)?language=zh-CN",headers:["Authorization":"Bearer \(credential("tmdb.token"))"]) as? [String:Any] ?? [:]
            return Self.tmdbEpisodes(data)
        }
        if work.source == .trakt {
            let rows = try await request("https://api.trakt.tv/shows/\(work.remoteID)/seasons/\(season)?extended=full&translations=zh",headers:traktHeaders()) as? [[String:Any]] ?? []
            return rows.compactMap { row -> MediaEpisode? in
                guard let number = row["number"] as? Int else { return nil }
                let images = row["images"] as? [String:[String]] ?? [:]
                let translations = row["translations"] as? [[String:Any]] ?? []
                let translation = translations.first { $0["country"] as? String == "cn" } ?? translations.first
                return MediaEpisode(number:number,title:translation?["title"] as? String ?? row["title"] as? String ?? "第 \(number) 集",image:Self.imageURL(images["screenshot"]?.first ?? images["thumb"]?.first),overview:translation?["overview"] as? String ?? row["overview"] as? String ?? "")
            }.sorted { $0.number < $1.number }
        }
        return []
    }
    static func tmdbEpisodes(_ data:[String:Any]) -> [MediaEpisode] {
        (data["episodes"] as? [[String:Any]] ?? []).compactMap { row in
            guard let number = row["episode_number"] as? Int else { return nil }
            return MediaEpisode(number:number,title:row["name"] as? String ?? "第 \(number) 集",image:(row["still_path"] as? String).map { "https://image.tmdb.org/t/p/w780\($0)" } ?? "",overview:row["overview"] as? String ?? "")
        }.sorted { $0.number < $1.number }
    }
}

import CoreGraphics
import ImageIO

/// Material-inspired population/hue scoring, followed by perceptual tonal roles.
/// This uses OKLCH rather than Material's HCT; image brightness is retained separately.
struct ArtworkPalette: Equatable, Sendable {
    var red: Double
    var green: Double
    var blue: Double
    var imageLuminance: Double = 0.5
    var darkCoverage: Double = 0
    static let neutral = ArtworkPalette(red:0.5,green:0.5,blue:0.5)
    var seed: ArtworkColor { ArtworkColor(red:red,green:green,blue:blue) }

    static func extract(_ data:Data) -> ArtworkPalette {
        guard let source = CGImageSourceCreateWithData(data as CFData,nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source,0,[kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceThumbnailMaxPixelSize:64,kCGImageSourceCreateThumbnailWithTransform:true] as CFDictionary) else { return .neutral }
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating:0,count:width * height * 4)
        let rendered = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let space = CGColorSpace(name:CGColorSpace.sRGB),
                  let context = CGContext(data:buffer.baseAddress,width:width,height:height,bitsPerComponent:8,bytesPerRow:width * 4,space:space,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.draw(image,in:CGRect(x:0,y:0,width:width,height:height)); return true
        }
        guard rendered else { return .neutral }
        var bins: [Int:(weight:Double,r:Double,g:Double,b:Double)] = [:]
        var population = 0.0, luminance = 0.0, dark = 0.0
        for offset in stride(from:0,to:pixels.count,by:4) {
            let alpha = Double(pixels[offset+3]) / 255
            guard alpha > 0.6 else { continue }
            let r = min(1,Double(pixels[offset]) / 255 / alpha), g = min(1,Double(pixels[offset+1]) / 255 / alpha), b = min(1,Double(pixels[offset+2]) / 255 / alpha)
            let y = ArtworkColor(red:r,green:g,blue:b).luminance
            population += alpha; luminance += y * alpha
            if y < 0.18 { dark += alpha }
            let key = (Int(r*15)<<8) | (Int(g*15)<<4) | Int(b*15)
            let bin = bins[key] ?? (0,0,0,0)
            bins[key] = (bin.weight+alpha,bin.r+r*alpha,bin.g+g*alpha,bin.b+b*alpha)
        }
        guard population > 0 else { return .neutral }
        let candidates = bins.sorted { $0.key < $1.key }.map { entry -> (color:ArtworkColor,weight:Double) in
            let b = entry.value
            return (ArtworkColor(red:b.r/b.weight,green:b.g/b.weight,blue:b.b/b.weight),b.weight)
        }
        var hues = [Double](repeating:0,count:36)
        for item in candidates where item.color.chroma > 0.025 {
            hues[item.color.hueBin] += item.weight / population
        }
        var winner: ArtworkColor?, best = -Double.infinity
        for item in candidates where item.color.chroma > 0.025 {
            let h = item.color.hueBin
            let proportion = hues[(h+35)%36] + hues[h] + hues[(h+1)%36]
            // Tiny highlights must not dictate the entire canvas.
            guard proportion >= 0.025, item.weight / population >= 0.005 else { continue }
            let score = proportion * 0.75 + min(item.color.chroma,0.25) * 0.8
            if score > best { best = score; winner = item.color }
        }
        // Monochrome artwork keeps its own neutral instead of acquiring a blue tint.
        let color = winner ?? candidates.max(by:{ $0.weight < $1.weight })!.color
        return ArtworkPalette(red:color.red,green:color.green,blue:color.blue,
                              imageLuminance:luminance/population,darkCoverage:dark/population)
    }

    func usesDarkAppearance(systemDark:Bool) -> Bool {
        systemDark || imageLuminance < 0.18 || darkCoverage >= 0.62
    }
    func theme(systemDark:Bool,increasedContrast:Bool = false) -> ArtworkTheme {
        ArtworkTheme(palette:self,dark:usesDarkAppearance(systemDark:systemDark),increasedContrast:increasedContrast)
    }
    // Other surfaces retain their host's appearance; detail explicitly resolves its own theme.
    func components(dark:Bool,intensity:Double = 1) -> (Double,Double,Double) {
        let color = seed.tonal(lightness:dark ? 0.26 : 0.91,chroma:min(seed.chroma,0.10) * min(1.4,max(0,intensity)))
        return (color.red,color.green,color.blue)
    }
}

struct ArtworkColor: Equatable, Sendable {
    var red: Double
    var green: Double
    var blue: Double
    private static func linear(_ v:Double) -> Double { v <= 0.04045 ? v/12.92 : pow((v+0.055)/1.055,2.4) }
    private static func encoded(_ v:Double) -> Double { v <= 0.0031308 ? v*12.92 : 1.055*pow(v,1/2.4)-0.055 }
    var luminance: Double { 0.2126*Self.linear(red) + 0.7152*Self.linear(green) + 0.0722*Self.linear(blue) }
    func contrast(with other:Self) -> Double { (max(luminance,other.luminance)+0.05)/(min(luminance,other.luminance)+0.05) }
    private var lab: (Double,Double,Double) {
        let r = Self.linear(red), g = Self.linear(green), b = Self.linear(blue)
        let l = cbrt(0.4122214708*r + 0.5363325363*g + 0.0514459929*b)
        let m = cbrt(0.2119034982*r + 0.6806995451*g + 0.1073969566*b)
        let s = cbrt(0.0883024619*r + 0.2817188376*g + 0.6299787005*b)
        return (0.2104542553*l + 0.793617785*m - 0.0040720468*s,
                1.9779984951*l - 2.428592205*m + 0.4505937099*s,
                0.0259040371*l + 0.7827717662*m - 0.808675766*s)
    }
    var chroma: Double { let v = lab; return hypot(v.1,v.2) }
    var hueBin: Int { let v = lab; return Int((atan2(v.2,v.1)*180 / .pi + 360).truncatingRemainder(dividingBy:360)/10) }
    func tonal(lightness:Double,chroma:Double) -> Self {
        let v = lab, hue = atan2(v.2,v.1)
        func rgb(_ c:Double) -> Self {
            let a = cos(hue)*c, b = sin(hue)*c
            let l = pow(lightness + 0.3963377774*a + 0.2158037573*b,3)
            let m = pow(lightness - 0.1055613458*a - 0.0638541728*b,3)
            let s = pow(lightness - 0.0894841775*a - 1.291485548*b,3)
            return Self(red:Self.encoded(4.0767416621*l - 3.3077115913*m + 0.2309699292*s),
                        green:Self.encoded(-1.2684380046*l + 2.6097574011*m - 0.3413193965*s),
                        blue:Self.encoded(-0.0041960863*l - 0.7034186147*m + 1.707614701*s))
        }
        // Reduce chroma to fit sRGB, preserving hue and perceptual lightness.
        var low = 0.0, high = max(0,chroma)
        for _ in 0..<16 {
            let mid = (low+high)/2, color = rgb(mid)
            if min(color.red,color.green,color.blue) >= 0 && max(color.red,color.green,color.blue) <= 1 { low = mid } else { high = mid }
        }
        let color = rgb(low)
        return Self(red:min(1,max(0,color.red)),green:min(1,max(0,color.green)),blue:min(1,max(0,color.blue)))
    }
}

struct ArtworkTheme: Equatable, Sendable {
    let dark: Bool
    let canvas: ArtworkColor
    let bottom: ArtworkColor
    let card: ArtworkColor
    let raised: ArtworkColor
    let primary: ArtworkColor
    let secondary: ArtworkColor
    let accent: ArtworkColor
    init(palette:ArtworkPalette,dark:Bool,increasedContrast:Bool = false) {
        self.dark = dark
        let seed = palette.seed
        let chroma = seed.chroma < 0.025 ? 0 : min(0.13,max(0.065,seed.chroma*0.8))
        let surfaceChroma = dark ? chroma : chroma * 0.4
        canvas = seed.tonal(lightness:dark ? 0.27 : 0.95,chroma:surfaceChroma)
        bottom = seed.tonal(lightness:dark ? 0.21 : 0.97,chroma:surfaceChroma*0.75)
        card = seed.tonal(lightness:dark ? 0.32 : 0.985,chroma:surfaceChroma*0.55)
        raised = seed.tonal(lightness:dark ? 0.37 : 0.96,chroma:surfaceChroma*0.70)
        let surfaces = [canvas,bottom,card,raised]
        func ink(lightness:Double,chroma:Double,ratio:Double) -> ArtworkColor {
            var tone = lightness
            for _ in 0..<101 {
                let color = seed.tonal(lightness:tone,chroma:chroma)
                if surfaces.allSatisfy({ color.contrast(with:$0) >= ratio }) { return color }
                tone = min(1,max(0,tone + (dark ? 0.01 : -0.01)))
            }
            return seed.tonal(lightness:dark ? 1 : 0,chroma:0)
        }
        primary = ink(lightness:dark ? 0.97 : 0.19,chroma:chroma == 0 ? 0 : 0.012,ratio:7)
        secondary = ink(lightness:dark ? 0.83 : 0.39,chroma:chroma == 0 ? 0 : 0.025,ratio:increasedContrast ? 7 : 4.5)
        accent = ink(lightness:dark ? 0.85 : 0.38,chroma:chroma == 0 ? 0 : max(chroma,0.12),ratio:increasedContrast ? 7 : 4.5)
    }
}

/// Visible episode cards plus a bounded look-ahead on either side.
enum EpisodeWindow {
    static func range(offset:Double,viewport:Double,count:Int,cardWidth:Double = 220,spacing:Double = 14,padding:Int = 3) -> Range<Int> {
        guard count > 0, viewport > 0, viewport.isFinite, offset.isFinite, cardWidth > 0, spacing >= 0 else { return 0..<0 }
        let stride = cardWidth + spacing
        let first = min(count - 1,max(0,Int(floor(max(0,offset) / stride))))
        let last = min(count,Int(ceil((max(0,offset) + viewport) / stride)))
        return max(0,first - max(0,padding))..<min(count,max(first + 1,last) + max(0,padding))
    }
}

extension CatalogAPI {
    /// Fetch by the original platform identity, never by a cached TMDB association.
    func details(_ work:Work) async throws -> Work {
        let id = work.remoteID
        switch work.source {
        case .tmdb: return try await tmdbDetails(id:Int(id) ?? 0,kind:work.kind)
        case .anilist:
            guard let number = Int(id) else { throw APIError.message("AniList 编号无效") }
            let root = try await request("https://graphql.anilist.co",method:"POST",body:["query":"query($id:Int!){Media(id:$id){\(AniListAPI.mediaFields)}}","variables":["id":number]]) as? [String:Any] ?? [:]
            guard let value = (root["data"] as? [String:Any])?["Media"] as? [String:Any] else { throw APIError.message("未找到 AniList 作品") }
            let media = try JSONDecoder().decode(Media.self,from:JSONSerialization.data(withJSONObject:value))
            guard media.id == number else { throw APIError.message("AniList 返回的条目编号与请求不一致") }
            return Work(source:.anilist,remoteID:id,kind:work.kind,title:media.title.display,original:media.title.native ?? "",overview:media.description ?? "",image:media.coverURL?.absoluteString ?? "",year:media.seasonYear.map(String.init) ?? "",rating:media.averageScore.map { Double($0)/10 },url:media.siteUrl ?? "",backdrop:media.bannerImage,format:media.format,volumeCount:media.volumes,chapterCount:media.chapters)
        case .trakt:
            let type = work.kind == .movie ? "movies" : "shows"
            let value = try await request("https://api.trakt.tv/\(type)/\(id)?extended=full",headers:traktHeaders()) as? [String:Any] ?? [:]
            guard let fresh = Self.traktWork(value,kind:work.kind) else { throw APIError.message("未找到 Trakt 作品") }
            return try await localized(fresh)
        case .mal:
            let type = work.kind == .manga ? "manga" : "anime"
            let fields = "mean,synopsis,start_date,alternative_titles,media_type" + (work.kind == .manga ? ",num_volumes,num_chapters" : "")
            let value = try await request("https://api.myanimelist.net/v2/\(type)/\(id)?fields=\(fields)",headers:["X-MAL-CLIENT-ID":credential("mal.clientID")]) as? [String:Any] ?? [:]
            guard value["id"] as? Int == Int(id), let title = value["title"] as? String else { throw APIError.message("未找到 MyAnimeList 作品") }
            return Work(source:.mal,remoteID:id,kind:work.kind,title:title,original:(value["alternative_titles"] as? [String:Any])?["ja"] as? String ?? "",overview:value["synopsis"] as? String ?? "",image:(value["main_picture"] as? [String:String])?["large"] ?? "",year:String((value["start_date"] as? String ?? "").prefix(4)),rating:value["mean"] as? Double,url:"https://myanimelist.net/\(type)/\(id)",format:work.kind == .manga ? Work.normalizedBookFormat(value["media_type"] as? String) : value["media_type"] as? String,volumeCount:value["num_volumes"] as? Int,chapterCount:value["num_chapters"] as? Int)
        case .bangumi:
            let token = credential("bangumi.token")
            let value = try await request("https://api.bgm.tv/v0/subjects/\(id)",headers:token.isEmpty ? [:] : ["Authorization":"Bearer \(token)"]) as? [String:Any] ?? [:]
            guard value["id"] as? Int == Int(id), let name = value["name"] as? String else { throw APIError.message("未找到 Bangumi 作品") }
            return Work(source:.bangumi,remoteID:id,kind:work.kind,title:(value["name_cn"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? name,original:name,overview:value["summary"] as? String ?? "",image:(value["images"] as? [String:String])?["large"] ?? "",year:String((value["date"] as? String ?? "").prefix(4)),rating:(value["rating"] as? [String:Any])?["score"] as? Double,url:"https://bgm.tv/subject/\(id)",format:Work.bangumiBookFormat(value["platform"],kind:work.kind),bookSeries:work.kind == .manga ? value["series"] as? Bool : nil,volumeCount:value["volumes"] as? Int,chapterCount:work.kind == .manga ? value["eps"] as? Int : nil)
        }
    }
}

extension CatalogAPI {
    func platformRatingDetails(_ work:Work) async throws -> Work {
        if work.source == .trakt {
            let type = work.kind == .movie ? "movies" : "shows"
            let value = try await request("https://api.trakt.tv/\(type)/\(work.remoteID)?extended=full",headers:traktHeaders()) as? [String:Any] ?? [:]
            guard let fresh = Self.traktWork(value,kind:work.kind), fresh.id == work.id else { throw APIError.message("未返回对应平台条目的评分") }
            return fresh
        }
        let fresh = try await details(work)
        guard fresh.id == work.id else { throw APIError.message("返回的评分与关联条目不一致") }
        return fresh
    }
}

/// Metadata and image bytes have independent lifetimes. Persist the addresses so
/// reopening a detail does not need a network round trip before showing its hero.
final class ArtworkMetadataSnapshot: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String:(artwork:MediaArtwork,saved:Date)] = [:]
    func value(for id:String) -> MediaArtwork? {
        lock.lock(); defer { lock.unlock() }
        guard let entry = values[id], Date().timeIntervalSince(entry.saved) < 24 * 60 * 60 else { values[id] = nil; return nil }
        return entry.artwork
    }
    func store(_ value:MediaArtwork?,for id:String) {
        lock.lock(); defer { lock.unlock() }
        if values.count >= 512, values[id] == nil { values.removeAll(keepingCapacity:true) }
        values[id] = value.map { ($0,Date()) }
    }
}
actor ArtworkMetadataCache {
    static let shared = ArtworkMetadataCache()
    nonisolated let snapshot = ArtworkMetadataSnapshot()
    private let directory: URL
    private struct Entry: Codable, Sendable { var saved:Date; var artwork:MediaArtwork }
    private var memory: [String:Entry] = [:]
    private let lifetime:TimeInterval = 24 * 60 * 60
    init(directory:URL = URL.cachesDirectory.appending(path:"AniShelf/ArtworkMetadata")) { self.directory = directory }
    private func file(_ id:String) -> URL {
        directory.appendingPathComponent(Data(id.utf8).base64EncodedString().replacingOccurrences(of:"/",with:"_"))
    }
    func value(for id:String) -> MediaArtwork? {
        if let entry = memory[id], Date().timeIntervalSince(entry.saved) < lifetime { return entry.artwork }
        guard let data = try? Data(contentsOf:file(id)), let entry = try? JSONDecoder().decode(Entry.self,from:data), Date().timeIntervalSince(entry.saved) < lifetime else { memory[id] = nil; return nil }
        if memory.count >= 512 { memory.removeAll(keepingCapacity:true) }
        memory[id] = entry
        snapshot.store(entry.artwork,for:id)
        return entry.artwork
    }
    func store(_ value:MediaArtwork,for id:String) {
        let entry = Entry(saved:Date(),artwork:value)
        if memory.count >= 512 { memory.removeAll(keepingCapacity:true) }
        memory[id] = entry
        snapshot.store(value,for:id)
        do {
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            try JSONEncoder().encode(entry).write(to:file(id),options:.atomic)
        } catch {
            Task { @MainActor in DiagnosticLog.shared.record("warning",component:"artwork-metadata",message:error.localizedDescription) }
        }
    }
    func remove(_ ids:Set<String>) {
        for id in ids { snapshot.store(nil,for:id); memory[id] = nil; try? FileManager.default.removeItem(at:file(id)) }
    }
}

struct ScreenPerson: Identifiable, Sendable {
    let id:Int
    var name:String
    var role:String
    var image:String
}
struct ScreenCredits: Sendable {
    var cast:[ScreenPerson] = []
    var crew:[ScreenPerson] = []
    var facts:[String:String] = [:]
}
struct ScreenBiography: Sendable {
    var text:String
    var works:[Work]
}
extension CatalogAPI {
    func screenCredits(_ work:Work) async throws -> ScreenCredits {
        guard work.kind != .manga, let id = work.source == .tmdb ? Int(work.remoteID) : work.tmdbID else { return ScreenCredits() }
        let credits = work.kind == .tv ? "aggregate_credits" : "credits"
        let data = try await request("https://api.themoviedb.org/3/\(work.kind.rawValue)/\(id)?language=zh-CN&append_to_response=\(credits)",headers:["Authorization":"Bearer \(credential("tmdb.token"))"]) as? [String:Any] ?? [:]
        return Self.screenCredits(data,creditKey:credits)
    }
    static func screenCredits(_ data:[String:Any],creditKey:String) -> ScreenCredits {
        let credits = data[creditKey] as? [String:Any] ?? [:]
        func person(_ row:[String:Any],role:String) -> ScreenPerson? {
            guard let id = row["id"] as? Int, let name = row["name"] as? String, !name.isEmpty else { return nil }
            return ScreenPerson(id:id,name:name,role:role,image:(row["profile_path"] as? String).map { "https://image.tmdb.org/t/p/w185\($0)" } ?? "")
        }
        var seen = Set<Int>()
        let cast = (credits["cast"] as? [[String:Any]] ?? []).compactMap { row -> ScreenPerson? in
            let roles = (row["roles"] as? [[String:Any]] ?? []).compactMap { $0["character"] as? String }
            guard let value = person(row,role:roles.isEmpty ? row["character"] as? String ?? "" : roles.joined(separator:" / ")),seen.insert(value.id).inserted else { return nil }
            return value
        }
        let jobs = ["Director":"导演","Writer":"编剧","Screenplay":"编剧","Creator":"主创","Executive Producer":"执行制片","Producer":"制片","Original Music Composer":"配乐","Original Story":"原作","Novel":"原著","Characters":"角色原案"]
        var crew = (data["created_by"] as? [[String:Any]] ?? []).compactMap { person($0,role:"主创") }
        for row in credits["crew"] as? [[String:Any]] ?? [] {
            let roles = (row["jobs"] as? [[String:Any]] ?? []).compactMap { $0["job"] as? String } + [row["job"] as? String].compactMap { $0 }
            let relevant = Array(Set(roles.compactMap { jobs[$0] })).sorted()
            guard !relevant.isEmpty, let value = person(row,role:relevant.joined(separator:" / ")) else { continue }
            if let index = crew.firstIndex(where:{ $0.id == value.id }) {
                if !crew[index].role.contains(value.role) { crew[index].role += " / " + value.role }
            } else { crew.append(value) }
        }
        var facts:[String:String] = [:]
        for (key,label) in [("genres","类型"),("production_companies","制作公司"),("networks","播出平台")] {
            let names = (data[key] as? [[String:Any]] ?? []).compactMap { $0["name"] as? String }.filter { !$0.isEmpty }
            if !names.isEmpty { facts[label] = names.joined(separator:" · ") }
        }
        if let date = data["first_air_date"] as? String, !date.isEmpty { facts["首播"] = date }
        return ScreenCredits(cast:cast,crew:crew,facts:facts)
    }
    func screenBiography(id:Int) async throws -> ScreenBiography {
        let headers = ["Authorization":"Bearer \(credential("tmdb.token"))"]
        let data = try await request("https://api.themoviedb.org/3/person/\(id)?language=zh-CN&append_to_response=combined_credits",headers:headers) as? [String:Any] ?? [:]
        var biography = data["biography"] as? String ?? ""
        if biography.isEmpty {
            let original = try await request("https://api.themoviedb.org/3/person/\(id)?language=en-US",headers:headers) as? [String:Any] ?? [:]
            biography = original["biography"] as? String ?? ""
        }
        let credits = data["combined_credits"] as? [String:Any] ?? [:]
        let rows = (credits["cast"] as? [[String:Any]] ?? []) + (credits["crew"] as? [[String:Any]] ?? [])
        var seen = Set<String>()
        let works = rows.sorted { ($0["popularity"] as? Double ?? 0) > ($1["popularity"] as? Double ?? 0) }.compactMap { row -> Work? in
            guard let type = row["media_type"] as? String, type == "movie" || type == "tv",
                  let work = Self.tmdbWork(row,kind:type == "movie" ? .movie : .tv), seen.insert(work.id).inserted else { return nil }
            return work
        }
        return ScreenBiography(text:biography,works:Array(works.prefix(24)))
    }
}
extension Intelligence {
    func translatedCredits(_ credits:ScreenCredits,work:Work) async throws -> ScreenCredits {
        var fields = credits.facts
        let people = credits.cast + credits.crew
        for (i,person) in people.enumerated() { fields["\(i).name"] = person.name; fields["\(i).role"] = person.role }
        let texts = try await translateMetadata(fields,work:work)
        var value = credits
        for key in value.facts.keys { value.facts[key] = texts[key] ?? value.facts[key] }
        for i in value.cast.indices { value.cast[i].name = texts["\(i).name"] ?? value.cast[i].name; value.cast[i].role = texts["\(i).role"] ?? value.cast[i].role }
        for i in value.crew.indices { let n = i + value.cast.count; value.crew[i].name = texts["\(n).name"] ?? value.crew[i].name; value.crew[i].role = texts["\(n).role"] ?? value.crew[i].role }
        return value
    }
}
