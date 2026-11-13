import SwiftUI
import CryptoKit
import ImageIO

// NSCache shares prepared images between loaders; each view owns its displayed image.
final class DecodedArtworkCache: @unchecked Sendable {
    private let storage = NSCache<NSString,UIImage>()
    init() { storage.totalCostLimit = 64 * 1_048_576 }
    func image(for address:String) -> UIImage? { storage.object(forKey:address as NSString) }
    func store(_ image:UIImage,for address:String,cost:Int) { storage.setObject(image,forKey:address as NSString,cost:cost) }
    func remove(_ address:String) {
        for size in [0,256,512,1024,2048,4096,8192] { storage.removeObject(forKey:"\(address)|\(size)" as NSString) }
    }
    func clear() { storage.removeAllObjects() }
}

/// CPU decoding has a bounded pool separate from cache metadata and disk coordination.
private enum ArtworkDecoder {
    static let queue:OperationQueue = {
        let queue = OperationQueue(); queue.name = "AniShelf.ImageDecode"
        queue.maxConcurrentOperationCount = 4; queue.qualityOfService = .userInitiated
        return queue
    }()
    static func decode(_ data:Data,pixels:Int) async throws -> UIImage {
        try await withCheckedThrowingContinuation { continuation in
            queue.addOperation {
                autoreleasepool {
                    #if canImport(UIKit)
                    let image:UIImage?
                    if pixels > 0, let source = CGImageSourceCreateWithData(data as CFData,[kCGImageSourceShouldCache:false] as CFDictionary),
                       let thumbnail = CGImageSourceCreateThumbnailAtIndex(source,0,[kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceCreateThumbnailWithTransform:true,kCGImageSourceThumbnailMaxPixelSize:pixels,kCGImageSourceShouldCacheImmediately:true] as CFDictionary) {
                        image = UIImage(cgImage:thumbnail)
                    } else { image = UIImage(data:data)?.preparingForDisplay() }
                    #else
                    let image = UIImage(data:data)?.preparingForDisplay()
                    #endif
                    if let image { continuation.resume(returning:image) }
                    else { continuation.resume(throwing:URLError(.cannotDecodeContentData)) }
                }
            }
        }
    }
}

enum ArtworkRetention { case standard, preferred }

actor PosterCache {
    static let shared = PosterCache()
    nonisolated static func pixelBucket(_ pixels:Int) -> Int {
        pixels <= 0 ? 0 : [256,512,1024,2048,4096,8192].first(where:{ $0 >= pixels }) ?? 8192
    }
    static let limitKey = "artwork.cacheLimitMB"
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        return URLSession(configuration:configuration)
    }()
    private var pending: [String:Task<Data,Error>] = [:]
    private var decoding: [String:Task<UIImage,Error>] = [:]
    private var lastDiskTouch:[URL:Date] = [:]
    nonisolated let decoded = DecodedArtworkCache()
    private let directory = URL.cachesDirectory.appending(path:"AniShelf/Posters")
    // App-managed artwork survives the system's purgeable Caches cleanup.
    private let preferredDirectory = URL.applicationSupportDirectory.appending(path:"AniShelf/PreferredArtwork")
    private var preferredKeys = Set<String>()
    private var generation = UUID()
    private var addressVersions: [String:UUID] = [:]
    private var removals: [String:UUID] = [:]
    private var diskEntries: [URL:(size:Int,date:Date)]?
    private var diskBytes = 0
    private struct Ownership: Codable {
        var addresses: [String:Set<String>]
        var invalidated: [String:Date]
    }
    private var owners: [String:Set<String>] = [:]
    private var invalidated: [String:Date] = [:]
    private var ownersLoaded = false
    private var ownerFile: URL { preferredDirectory.deletingLastPathComponent().appending(path:"artwork-owners.json") }
    private var legacyOwnerFile: URL { directory.deletingLastPathComponent().appending(path:"artwork-owners.json") }
    private func preparePreferredDirectory() throws {
        try FileManager.default.createDirectory(at:preferredDirectory,withIntermediateDirectories:true)
        var folder = preferredDirectory
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try folder.setResourceValues(values)
    }
    private func key(for address:String) -> String {
        SHA256.hash(data:Data(address.utf8)).map { String(format:"%02x",$0) }.joined()
    }
    private func file(for key:String) -> URL {
        (preferredKeys.contains(key) ? preferredDirectory : directory).appending(path:key)
    }
    private func register(_ address:String,retention:ArtworkRetention) throws {
        loadDiskIndex()
        let key = key(for:address)
        guard retention == .preferred else { return }
        preferredKeys.insert(key)
        let old = directory.appending(path:key), target = preferredDirectory.appending(path:key)
        if FileManager.default.fileExists(atPath:old.path) {
            try preparePreferredDirectory()
            if FileManager.default.fileExists(atPath:target.path) { try FileManager.default.removeItem(at:old) }
            else { try FileManager.default.moveItem(at:old,to:target) }
            let entry = diskEntries?[old]
            forgetFile(old)
            if let entry { rememberFile(target,size:entry.size,date:entry.date) }
        }
    }
    private func touch(_ address:String) {
        let file = file(for:key(for:address)), now = Date()
        guard let entry = diskEntries?[file] else { return }
        // Keep eviction recency exact in memory; throttle filesystem metadata writes.
        if now.timeIntervalSince(lastDiskTouch[file] ?? .distantPast) >= 60 {
            try? FileManager.default.setAttributes([.modificationDate:now],ofItemAtPath:file.path)
            lastDiskTouch[file] = now
        }
        rememberFile(file,size:entry.size,date:now)
    }
    private func loadOwners() {
        guard !ownersLoaded else { return }; ownersLoaded = true
        if let data = (try? Data(contentsOf:ownerFile)) ?? (try? Data(contentsOf:legacyOwnerFile)) {
            if let saved = try? JSONDecoder().decode(Ownership.self,from:data) { owners = saved.addresses; invalidated = saved.invalidated }
            else if let saved = try? JSONDecoder().decode([String:Set<String>].self,from:data) { owners = saved }
        }
    }
    private func saveOwners() throws {
        try FileManager.default.createDirectory(at:ownerFile.deletingLastPathComponent(),withIntermediateDirectories:true)
        try JSONEncoder().encode(Ownership(addresses:owners,invalidated:invalidated)).write(to:ownerFile,options:.atomic)
    }
    private var limit: Int { max(0, UserDefaults.standard.object(forKey:Self.limitKey) as? Int ?? 512) * 1_048_576 }
    func data(for address:String,owner:String? = nil,retention:ArtworkRetention = .standard) async throws -> Data {
        loadOwners()
        if let owner, owners[owner]?.contains(address) != true {
            owners[owner,default:[]].insert(address)
            do { try saveOwners() }
            catch { await DiagnosticLog.shared.record("warning",component:"artwork-cache",message:"图片缓存索引写入失败：" + error.localizedDescription) }
        }
        do { try register(address,retention:retention); try trim() }
        catch { await DiagnosticLog.shared.record("warning",component:"artwork-cache",message:"图片缓存整理失败：" + error.localizedDescription) }
        guard let url = URL(string:address), url.scheme == "https" else { throw URLError(.badURL) }
        let key = key(for:address)
        let file = file(for:key)
        if let owner, let reset = invalidated[owner],
           let created = try? file.resourceValues(forKeys:[.creationDateKey]).creationDate, created < reset {
            try? FileManager.default.removeItem(at:file)
            forgetFile(file)
        }
        if let data = try? Data(contentsOf:file), UIImage(data:data) != nil {
            rememberFile(file,size:data.count,date:diskEntries?[file]?.date ?? Date())
            touch(address)
            return data
        }
        // A partial or obsolete disk entry must not make this URL fail forever.
        if FileManager.default.fileExists(atPath:file.path) {
            try? FileManager.default.removeItem(at:file)
            forgetFile(file)
        }
        if let task = pending[address] { return try await task.value }
        let revision = generation
        let version = UUID(); addressVersions[address] = version
        let session = self.session
        let task = Task<Data,Error> {
            // All artwork uses this bounded cache, without a second URLCache copy.
            let request = URLRequest(url:url,cachePolicy:.reloadIgnoringLocalCacheData)
            for attempt in 0..<3 {
                do {
                    let (data,response) = try await session.data(for:request)
                    guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
                    if (response.statusCode == 429 || (500..<600).contains(response.statusCode)), attempt < 2 {
                        try await Task.sleep(for:.seconds(attempt + 1))
                        continue
                    }
                    guard (200..<300).contains(response.statusCode), UIImage(data:data) != nil else { throw URLError(.cannotDecodeContentData) }
                    return data
                } catch {
                    try Task.checkCancellation()
                    let transient = (error as? URLError).map {
                        [.timedOut, .networkConnectionLost, .notConnectedToInternet,
                         .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed].contains($0.code)
                    } ?? false
                    guard transient, attempt < 2 else { throw error }
                    try await Task.sleep(for:.seconds(attempt + 1))
                }
            }
            throw URLError(.badServerResponse)
        }
        pending[address] = task
        defer { if generation == revision && addressVersions[address] == version { pending[address] = nil } }
        let data = try await task.value
        guard !task.isCancelled, generation == revision, addressVersions[address] == version else { throw CancellationError() }
        if !task.isCancelled, generation == revision, addressVersions[address] == version, limit > 0, data.count <= limit {
            do {
                // A second consumer may promote the URL while its download is pending.
                let file = self.file(for:key)
                if preferredKeys.contains(key) { try preparePreferredDirectory() }
                else { try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true) }
                try data.write(to:file,options:.atomic)
                rememberFile(file,size:data.count,date:Date())
                try trim()
            } catch {
                await DiagnosticLog.shared.record("warning",component:"artwork-cache",message:"图片缓存写入失败：" + error.localizedDescription)
            }
        }
        return data
    }
    /// Decode and prepare bitmap storage on the cache actor, away from SwiftUI.
    func image(for address:String,owner:String? = nil,retention:ArtworkRetention = .standard,maxPixelSize:Int = 0) async throws -> UIImage {
        let pixels = Self.pixelBucket(maxPixelSize)
        let cacheKey = "\(address)|\(pixels)"
        loadOwners()
        if let owner, owners[owner]?.contains(address) != true {
            owners[owner,default:[]].insert(address)
            do { try saveOwners() }
            catch { await DiagnosticLog.shared.record("warning",component:"artwork-cache",message:"图片缓存索引写入失败：" + error.localizedDescription) }
        }
        do { try register(address,retention:retention) }
        catch { await DiagnosticLog.shared.record("warning",component:"artwork-cache",message:"图片缓存升级失败：" + error.localizedDescription) }
        if let image = decoded.image(for:cacheKey) { touch(address); return image }
        let revision = generation, removal = removals[address]
        let bytes = try await data(for:address,owner:owner,retention:retention)
        guard generation == revision, removals[address] == removal else { throw CancellationError() }
        if let image = decoded.image(for:cacheKey) { return image }
        let task:Task<UIImage,Error>
        let ownsTask:Bool
        if let existing = decoding[cacheKey] { task = existing; ownsTask = false }
        else {
            task = Task { try await ArtworkDecoder.decode(bytes,pixels:pixels) }
            decoding[cacheKey] = task; ownsTask = true
        }
        defer { if ownsTask, generation == revision, removals[address] == removal { decoding[cacheKey] = nil } }
        let prepared = try await task.value
        try Task.checkCancellation()
        guard generation == revision, removals[address] == removal else { throw CancellationError() }
        if limit > 0 { decoded.store(prepared,for:cacheKey,cost:prepared.cgImage.map { $0.bytesPerRow * $0.height } ?? bytes.count) }
        return prepared
    }
    func remove(_ addresses:[String],owners identities:Set<String> = []) throws {
        loadOwners()
        let registered = identities.flatMap { owners[$0] ?? [] }
        for id in identities { owners[id] = nil; invalidated[id] = Date() }
        try saveOwners()
        for address in Set(addresses + registered) where !address.isEmpty {
            addressVersions[address] = UUID(); removals[address] = UUID()
            decoded.remove(address)
            for key in Array(decoding.keys) where key.hasPrefix(address + "|") { decoding.removeValue(forKey:key)?.cancel() }
            pending.removeValue(forKey:address)?.cancel()
            let key = key(for:address)
            for folder in [directory,preferredDirectory] {
                let file = folder.appending(path:key)
                if FileManager.default.fileExists(atPath:file.path) { try FileManager.default.removeItem(at:file) }
                forgetFile(file)
            }
            preferredKeys.remove(key)
        }
    }
    func usage() -> Int { loadDiskIndex(); return diskBytes }
    func setLimit(megabytes:Int) throws {
        UserDefaults.standard.set(max(0,megabytes),forKey:Self.limitKey)
        if megabytes <= 0 { decoded.clear() }
        try trim()
    }
    func clear() throws {
        generation = UUID()
        decoded.clear(); addressVersions.removeAll(); removals.removeAll()
        decoding.values.forEach { $0.cancel() }; decoding.removeAll(); lastDiskTouch.removeAll()
        pending.values.forEach { $0.cancel() }; pending.removeAll()
        owners = [:]; invalidated = [:]; ownersLoaded = true
        if FileManager.default.fileExists(atPath:ownerFile.path) { try FileManager.default.removeItem(at:ownerFile) }
        for path in [directory,preferredDirectory,legacyOwnerFile] {
            if FileManager.default.fileExists(atPath:path.path) { try FileManager.default.removeItem(at:path) }
        }
        preferredKeys.removeAll()
        diskEntries = nil; diskBytes = 0
    }
    private func entries() -> [(url:URL,size:Int,date:Date)] {
        let files = [directory,preferredDirectory].flatMap { folder in
            ((try? FileManager.default.contentsOfDirectory(atPath:folder.path)) ?? []).map { folder.appending(path:$0) }
        }
        return files.compactMap { file in
            guard let values = try? file.resourceValues(forKeys:[.fileSizeKey,.contentModificationDateKey]) else { return nil }
            return (file,values.fileSize ?? 0,values.contentModificationDate ?? .distantPast)
        }
    }
    private func loadDiskIndex() {
        guard diskEntries == nil else { return }
        let files = entries()
        preferredKeys.formUnion((try? FileManager.default.contentsOfDirectory(atPath:preferredDirectory.path)) ?? [])
        diskEntries = Dictionary(uniqueKeysWithValues:files.map { ($0.url,(size:$0.size,date:$0.date)) })
        diskBytes = files.reduce(0) { $0 + $1.size }
    }
    private func forgetFile(_ file:URL) {
        if let old = diskEntries?.removeValue(forKey:file) { diskBytes -= old.size }
    }
    private func rememberFile(_ file:URL,size:Int,date:Date) {
        loadDiskIndex()
        forgetFile(file)
        diskEntries?[file] = (size,date); diskBytes += size
    }
    private func trim() throws {
        loadDiskIndex()
        let budget = limit
        guard diskBytes > budget else { return }
        let files = (diskEntries ?? [:]).sorted {
            let leftPreferred = preferredKeys.contains($0.key.lastPathComponent)
            let rightPreferred = preferredKeys.contains($1.key.lastPathComponent)
            if leftPreferred != rightPreferred { return !leftPreferred }
            return $0.value.date < $1.value.date
        }
        for file in files {
            guard diskBytes > budget else { break }
            // iOS may purge cache files independently of this process.
            if FileManager.default.fileExists(atPath:file.key.path) { try FileManager.default.removeItem(at:file.key) }
            forgetFile(file.key)
        }
    }
}

// A dense color backing keeps the lettering independent of the poster beneath
// the glass. Apply glass to the backing only, preserving the exact ink color.
private struct CoverBadge: View {
    let text: String
    let fill: Color
    let ink: Color
    var body: some View {
        Text(text).font(.caption.bold()).lineLimit(1)
            .foregroundStyle(ink)
            .padding(.horizontal,8).padding(.vertical,6)
            .background {
                RoundedRectangle(cornerRadius:9)
                    .fill(fill.opacity(0.94))
                    .glassEffect(.clear.tint(fill.opacity(0.35)),in:.rect(cornerRadius:9))
            }
    }
}

struct BookBadge: View {
    var isNovel = false
    @Environment(\.colorScheme) private var colorScheme
    private var fill: Color {
        if colorScheme == .dark {
            return isNovel ? Color(red:0.08,green:0.27,blue:0.16) : Color(red:0.32,green:0.16,blue:0.03)
        }
        return isNovel ? Color(red:0.66,green:0.88,blue:0.65) : Color(red:1.0,green:0.76,blue:0.36)
    }
    private var ink: Color {
        if colorScheme == .dark {
            return isNovel ? Color(red:0.80,green:1.0,blue:0.81) : Color(red:1.0,green:0.88,blue:0.63)
        }
        return isNovel ? Color(red:0.06,green:0.23,blue:0.10) : Color(red:0.29,green:0.13,blue:0.01)
    }
    var body: some View {
        CoverBadge(text:isNovel ? "文" : "漫",fill:fill,ink:ink)
            .padding(7)
            .accessibilityLabel(isNovel ? "小说" : "漫画")
    }
}

enum StatusAppearance {
    case active, completed, planned, paused, dropped, repeating, rated

    init(_ status: String) {
        switch status {
        case "进行中", "观看中", "阅读中", "在看", "在读", "连载中", "播出中": self = .active
        case "已完成", "已观看", "已完结", "完成": self = .completed
        case "已暂停", "搁置", "待确认": self = .paused
        case "已放弃", "放弃": self = .dropped
        case "重温中", "重温": self = .repeating
        case "已评分", "评分": self = .rated
        default: self = .planned
        }
    }
    private var hue: Double {
        switch self {
        case .active: 0.60
        case .completed: 0.39
        case .planned: 0.61
        case .paused: 0.10
        case .dropped: 0.00
        case .repeating: 0.76
        case .rated: 0.50
        }
    }
    func ink(dark: Bool) -> Color {
        Color(hue:hue,saturation:self == .planned ? 0 : (dark ? 0.30 : 0.85),brightness:dark ? 1 : 0.40)
    }
    func fill(dark: Bool) -> Color {
        Color(hue:hue,saturation:self == .planned ? 0 : (dark ? 0.55 : 0.10),brightness:dark ? 0.22 : 0.98)
    }
    func menuDot(dark: Bool) -> Color {
        // Solid menu dots share the badge hues, with a brighter, softer tone.
        Color(hue:hue,saturation:self == .planned ? 0 : (dark ? 0.30 : 0.62),
              brightness:dark ? 1 : (self == .planned ? 0.62 : 0.85))
    }
}

// Original-rendering images retain each status color in native menus.
struct StatusMenuLabel: View {
    let status: String
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        Label {
            Text(status)
        } icon: {
            Image(uiImage:(UIImage(systemName:"circle.fill") ?? UIImage())
                .withTintColor(UIColor(StatusAppearance(status).menuDot(dark:scheme == .dark)),renderingMode:.alwaysOriginal))
                .renderingMode(.original)
        }
    }
}

// Both badge locations share the same opaque surface so poster artwork cannot
// shift the status color. Only the shape and spacing vary by location.
private struct StatusBadgeStyle: ViewModifier {
    let status: String
    let cornerRadius: CGFloat
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let appearance = StatusAppearance(status)
        let dark = scheme == .dark
        content
            .foregroundStyle(appearance.ink(dark:dark))
            .background(appearance.fill(dark:dark),in:.rect(cornerRadius:cornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius:cornerRadius)
                    .strokeBorder(appearance.ink(dark:dark).opacity(0.18),lineWidth:0.5)
            }
    }
}

struct CoverStatusBadge: View {
    let status: String
    var isBook = false
    private var label: String {
        switch status {
        case "进行中", "观看中", "阅读中": isBook ? "在读" : "在看"
        case "已完成", "已观看", "已完结": "完成"
        case "计划中": "计划"
        case "已暂停": "搁置"
        case "已放弃": "放弃"
        case "重温中": "重温"
        case "已评分": "评分"
        default: String(status.prefix(2))
        }
    }
    var body: some View {
        Text(label).font(.caption.bold()).lineLimit(1)
            .padding(.horizontal,8).padding(.vertical,6)
            .modifier(StatusBadgeStyle(status:status,cornerRadius:9))
            .padding(7)
            .accessibilityLabel(status)
    }
}
struct Poster: View {
    let work: Work
    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?
    @State private var loadedAddress: String?
    private var displayedImage: UIImage? {
        loadedAddress == work.image ? image : nil
    }
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color(.tertiarySystemFill)
                if let image = displayedImage { Image(uiImage:image).resizable().scaledToFill() }
                else { Image(systemName:work.kind == .manga ? "book.closed" : "film").font(.largeTitle).foregroundStyle(.tertiary) }
            }.frame(width:geometry.size.width,height:geometry.size.height).clipped()
            .task(id:"\(work.image)|\(PosterCache.pixelBucket(Int(max(geometry.size.width,geometry.size.height) * displayScale)))") {
                guard !work.image.isEmpty else { return }
                do {
                    let cached = try await PosterCache.shared.image(for:work.image,owner:work.id,retention:.preferred,maxPixelSize:PosterCache.pixelBucket(Int(max(geometry.size.width,geometry.size.height) * displayScale)))
                    try Task.checkCancellation()
                    var transaction = Transaction(); transaction.disablesAnimations = true
                    withTransaction(transaction) { image = cached; loadedAddress = work.image }
                } catch {
                    guard !Task.isCancelled else { return }
                    DiagnosticLog.shared.record("warning",component:"artwork",message:"封面加载失败（\(work.id)）：" + error.localizedDescription)
                }
            }
        }
        .clipShape(.rect(cornerRadius:14))
        .overlay { RoundedRectangle(cornerRadius:14).strokeBorder(.white.opacity(0.12),lineWidth:0.5) }
        .overlay(alignment:.bottomTrailing) { if work.isNovel || work.isComic { BookBadge(isNovel:work.isNovel) } }
        .accessibilityHidden(true)

    }
}

enum ArtworkTransition {
    static let topBlurRadius: CGFloat = 32
    static let bottomHeight: CGFloat = 140
    static var fadeStops: [Gradient.Stop] {
        (0...16).map { index in
            let t = Double(index) / 16
            let smooth = t * t * (3 - 2 * t)
            return .init(color:.white.opacity(1 - smooth),location:t)
        }
    }
}

/// The banner keeps its own crop; only blurred artwork fills the space above it.
struct TopExtendedArtwork: View {
    let image: UIImage
    let extensionHeight: CGFloat
    private let transitionHeight: CGFloat = 40

    var body: some View {
        GeometryReader { proxy in
            let bannerHeight = max(1,proxy.size.height - extensionHeight)
            ZStack(alignment:.bottom) {
                Image(uiImage:image).resizable().scaledToFill()
                    .frame(width:proxy.size.width,height:proxy.size.height)
                    .clipped().blur(radius:ArtworkTransition.topBlurRadius,opaque:true)
                ZStack(alignment:.top) {
                    Image(uiImage:image).resizable().scaledToFill()
                        .frame(width:proxy.size.width,height:bannerHeight).clipped()
                    ForEach(1...3,id:\.self) { step in
                        Image(uiImage:image).resizable().scaledToFill()
                            .frame(width:proxy.size.width,height:bannerHeight).clipped()
                            .blur(radius:CGFloat(step) * 8,opaque:true)
                            .mask {
                                LinearGradient(stops:ArtworkTransition.fadeStops,startPoint:.top,endPoint:.bottom)
                                    .frame(height:transitionHeight * CGFloat(4 - step) / 3)
                                    .frame(maxHeight:.infinity,alignment:.top)
                            }
                    }
                }
                .frame(width:proxy.size.width,height:bannerHeight)
                .mask {
                    VStack(spacing:0) {
                        LinearGradient(stops:ArtworkTransition.fadeStops,startPoint:.bottom,endPoint:.top)
                            .frame(height:min(20,bannerHeight))
                        Color.white
                    }
                }
            }
            .frame(width:proxy.size.width,height:proxy.size.height).clipped()
        }
    }
}

/// Blur is masked after filtering so it cannot spread above the bottom band.
struct ProgressiveArtwork: View {
    let image: UIImage
    var strength: CGFloat = 12
    var body: some View {
        GeometryReader { proxy in
            ZStack {
                artwork(proxy.size)
                ForEach(1...3,id:\.self) { step in
                    artwork(proxy.size).blur(radius:strength * CGFloat(step) / 3)
                        .mask {
                            LinearGradient(stops:[.init(color:.clear,location:Double(step-1)*0.16+0.12),.init(color:.white,location:Double(step)*0.16+0.34)],startPoint:.top,endPoint:.bottom)
                                .frame(height:min(ArtworkTransition.bottomHeight,proxy.size.height))
                                .frame(maxHeight:.infinity,alignment:.bottom)
                        }
                }
            }.clipped()
        }
    }
    private func artwork(_ size:CGSize) -> some View {
        Image(uiImage:image).resizable().scaledToFill().frame(width:size.width,height:size.height).clipped()
    }
}

extension ArtworkColor {
    var color: Color { Color(red:red,green:green,blue:blue) }
}

struct ArtworkThemeBackground: View {
    let theme: ArtworkTheme
    var body: some View {
        ZStack {
            LinearGradient(colors:[theme.canvas.color,theme.bottom.color],startPoint:.top,endPoint:.bottom)
            RadialGradient(colors:[theme.accent.color.opacity(0.08),.clear],
                           center:.topTrailing,startRadius:0,endRadius:560)
        }.ignoresSafeArea().allowsHitTesting(false).accessibilityHidden(true)
    }
}

extension ArtworkPalette {
    func color(dark:Bool,intensity:Double = 1) -> Color {
        let (r,g,b) = components(dark:dark,intensity:intensity)
        return Color(red:r,green:g,blue:b)
    }
}
struct ArtworkAmbientBackground: View {
    let address:String
    var intensity:Double = 1
    var cacheOwner:String?
    @Environment(\.colorScheme) private var scheme
    @State private var palette = ArtworkPalette.neutral
    var body: some View {
        LinearGradient(colors:[palette.color(dark:scheme == .dark,intensity:intensity),Color(.systemGroupedBackground)],startPoint:.topLeading,endPoint:.bottomTrailing)
            .ignoresSafeArea()
            .animation(.easeInOut(duration:0.5),value:palette)
            .task(id:address) {
                palette = .neutral
                guard !address.isEmpty, let data = try? await PosterCache.shared.data(for:address,owner:cacheOwner,retention:.preferred) else { return }
                let sampled = await Task.detached(priority:.utility) { ArtworkPalette.extract(data) }.value
                guard !Task.isCancelled else { return }; palette = sampled
            }
    }
}

struct StatusBadge: View {
    let text: String
    var body: some View {
        Text(text).font(.caption).lineLimit(1)
            .padding(.horizontal,7).padding(.vertical,3)
            .modifier(StatusBadgeStyle(status:text,cornerRadius:100))
    }
}
