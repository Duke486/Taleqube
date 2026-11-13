import Foundation
import Observation
import Security
import CryptoKit

enum Catalog: String, Codable, CaseIterable, Identifiable, Sendable {
    case tmdb, trakt, anilist, mal, bangumi
    var id: String { rawValue }
    var title: String { switch self { case .tmdb: "TMDB"; case .trakt: "Trakt"; case .anilist: "AniList"; case .mal: "MyAnimeList"; case .bangumi: "Bangumi" } }
}
/// Maps a Bangumi subject's local progress cursor to stable remote episode IDs.
/// `sort` can be a series-wide broadcast number; `ep` is subject-local when supplied.
enum BangumiEpisodeNumbering {
    static func orderedIDs(_ rows:[[String:Any]]) throws -> [Int] {
        var values: [(id:Int,ep:Double?,sort:Double?)] = []
        var ids = Set<Int>()
        for row in rows {
            guard let id = row["id"] as? Int, id > 0, ids.insert(id).inserted,
                  row["type"] == nil || row["type"] as? Int == 0 else {
                throw APIError.message("Bangumi 正片章节身份无效或重复，进度未写入")
            }
            values.append((id,(row["ep"] as? NSNumber)?.doubleValue,(row["sort"] as? NSNumber)?.doubleValue))
        }
        let local = values.compactMap(\.ep)
        if !values.isEmpty, local.count == values.count,
           local.allSatisfy({ $0.isFinite && $0 > 0 && $0.rounded() == $0 }),
           Set(local) == Set((1...values.count).map(Double.init)) {
            return values.sorted { $0.ep! < $1.ep! }.map(\.id)
        }
        // Older records may omit ep, use zero, or retain broadcast numbering.
        // Rank the complete regular-episode table
        // by its broadcast order, without treating the broadcast number as a count.
        let order = values.compactMap(\.sort)
        guard order.count == values.count, order.allSatisfy({ $0.isFinite && $0 >= 0 }), Set(order).count == values.count else {
            throw APIError.message("Bangumi 章节排序缺失或重复，进度未写入")
        }
        return values.sorted { $0.sort! < $1.sort! }.map(\.id)
    }
}
enum WorkKind: String, Codable, CaseIterable, Identifiable, Sendable, Sendable {
    case movie, tv, manga
    var id: String { rawValue }
    var title: String { switch self { case .movie: "电影"; case .tv: "剧集"; case .manga: "书籍" } }
}
struct Work: Codable, Identifiable, Hashable {
    var source: Catalog
    var remoteID: String
    var kind: WorkKind
    var title: String
    var original: String = ""
    var overview: String = ""
    var image: String = ""
    var year: String = ""
    var rating: Double?
    var url: String = ""
    var tmdbID: Int?
    var backdrop: String?
    var format: String?
    var episodeCount: Int?
    var bookSeries: Bool?
    var volumeCount: Int?
    var chapterCount: Int?
    var isNovel: Bool { kind == .manga && Self.normalizedBookFormat(format) == "NOVEL" }
    var isComic: Bool { kind == .manga && ["MANGA","ONE_SHOT","MANHWA","MANHUA","DOUJINSHI","OEL"].contains(Self.normalizedBookFormat(format) ?? "") }
    var bookMatchType: String? {
        guard kind == .manga else { return nil }
        return isComic ? "MANGA" : Self.normalizedBookFormat(format)
    }
    var typeTitle: String {
        guard kind == .manga else { return kind.title }
        if isNovel { return "小说" }
        if isComic { return "漫画" }
        return ["ARTBOOK":"画集","PICTURE_BOOK":"绘本","PHOTO_BOOK":"写真","GUIDEBOOK":"公式书"][format ?? ""] ?? "书籍"
    }
    func matchesBookType(of other:Work) -> Bool {
        guard kind == other.kind else { return false }
        if kind == .manga, let a = bookSeries, let b = other.bookSeries, a != b { return false }
        guard let a = bookMatchType, let b = other.bookMatchType else { return true }
        return a == b
    }
    static func normalizedBookFormat(_ value:String?) -> String? {
        guard let value = value?.trimmingCharacters(in:.whitespacesAndNewlines).uppercased(), !value.isEmpty, value != "UNKNOWN" else { return nil }
        return value == "LIGHT_NOVEL" ? "NOVEL" : value
    }
    static func bangumiBookFormat(_ value:Any?, kind:WorkKind) -> String? {
        guard kind == .manga, let platform = value as? String else { return nil }
        return ["漫画":"MANGA","小说":"NOVEL","画集":"ARTBOOK","绘本":"PICTURE_BOOK","写真":"PHOTO_BOOK","公式书":"GUIDEBOOK","其他":"OTHER"][platform.trimmingCharacters(in:.whitespacesAndNewlines)]
    }
    var id: String { "\(source.rawValue):\(kind.rawValue):\(remoteID)" }
}
enum SyncField: String, Codable, Hashable { case rating, status, progress }
struct SyncStep: Codable, Equatable, Identifiable {
    var id = UUID()
    var date = Date()
    var method: String
    var path: String
    var requestBody: String?
    var status: Int?
    var error: String?
}
struct SyncAttempt: Codable, Equatable, Identifiable {
    var id = UUID()
    var date = Date()
    var contents: String
    var steps: [SyncStep] = []
    var error: String?
}
struct TrackingRecord: Codable, Equatable, Identifiable {
    var work: Work
    var score: Double? = nil
    var scoreCleared: Bool? = nil
    var locallySubmitted: Bool? = nil
    var progressSubmitted: Bool? = nil
    var progress = 0
    var addedAt: Date?
    var modifiedAt: Date?
    var syncFields: Set<SyncField>?
    var syncSeason: Int?
    var ratingOrigin: String?
    var watchedCount: Int?
    var libraryException: String?
    var sourceRecords: [String:SourceProgress]?
    var retiredAssociationIDs: Set<String>?
    var viewingUnits: [ViewingUnit]?
    var platformLinks: [PlatformAssociation]?
    var archivedUnits: [ViewingUnit]?
    var retainedSeasonTracking: [ViewingUnit]?
    var episodeHistory: [EpisodeAddress]?
    var syncMappedEpisodes: [Int]?
    var syncWatchedEpisodes: [Int]?
    var season = 1
    var volumes = 0
    var status = "进行中"
    var links: [String: Work] = [:]
    var noEntryPlatforms: Set<String>? = nil
    // Retained for decoding legacy archives; new writes use typed progressMappings.
    var mappedProgress: [String:[Int]] = [:]
    var progressMappings: [String:ProgressMapping]?
    var confirmedProgress: Set<String> = []
    var progressDisabled: Set<String> = []
    var id: String { work.id }
    var hasSubmittedTracking: Bool {
        if let locallySubmitted { return locallySubmitted }
        if work.kind == .tv { return (viewingUnits ?? []).contains { $0.isTrackingMarked } }
        return addedAt != nil && (sourceRecords?.isEmpty ?? true)
    }
    var hasMissingEpisodeMapping: Bool {
        guard work.kind == .tv else { return false }
        var prepared = self
        prepared.prepareUnits()
        return (prepared.platformLinks ?? []).contains {
            ![Catalog.tmdb,.trakt].contains($0.target.source) && ($0.mapping?.matchedEpisodeCount ?? 0) == 0
        }
    }
    func hasPartialEpisodeMapping(_ platform:Catalog) -> Bool {
        guard work.kind == .tv, ![Catalog.tmdb,.trakt].contains(platform) else { return false }
        var prepared = self
        prepared.prepareUnits()
        let associations = (prepared.platformLinks ?? []).filter { $0.target.source == platform }
        return associations.allSatisfy { ($0.mapping?.matchedEpisodeCount ?? 0) > 0 }
            && associations.contains { $0.mapping?.complete == false }
    }
    var matchingPlatforms: [Catalog] { Catalog.allCases.filter { work.kind != .manga || ![Catalog.tmdb,.trakt].contains($0) } }
    func hasNoEntry(_ platform:Catalog) -> Bool { noEntryPlatforms?.contains(platform.rawValue) == true }
    func shouldAttemptMatching(_ platform:Catalog, explicitRetry:Bool = false) -> Bool {
        matchingPlatforms.contains(platform) && (!hasNoEntry(platform) || explicitRetry)
    }
    func needsMatching(_ platform:Catalog) -> Bool {
        guard matchingPlatforms.contains(platform) else { return false }
        if hasNoEntry(platform) { return false }
        return work.source != platform && links[platform.rawValue] == nil &&
            !(platformLinks ?? []).contains { $0.target.source == platform } &&
            !(viewingUnits ?? []).contains { $0.links[platform.rawValue] != nil }
    }
    mutating func setNoEntry(_ platform:Catalog) {
        guard matchingPlatforms.contains(platform) else { return }
        noEntryPlatforms = (noEntryPlatforms ?? []).union([platform.rawValue])
        let removedIDs = Set((platformLinks ?? []).filter { $0.target.source == platform }.map(\.id))
            .union(links[platform.rawValue].map { [$0.id] } ?? [])
            .union((sourceRecords ?? [:]).values.filter { $0.work.source == platform }.map(\.id))
        retiredAssociationIDs = (retiredAssociationIDs ?? []).union(removedIDs)
        links[platform.rawValue] = nil
        platformLinks?.removeAll { $0.target.source == platform }
        for index in viewingUnits?.indices ?? 0..<0 { viewingUnits?[index].links[platform.rawValue] = nil }
        confirmedProgress.remove(platform.rawValue)
        progressMappings?[platform.rawValue] = nil
        mappedProgress[platform.rawValue] = nil
    }
    func isPlatformEnabled(_ platform:Catalog) -> Bool {
        guard !hasNoEntry(platform) else { return false }
        if work.kind == .tv, let platformLinks, ![Catalog.tmdb,.trakt].contains(platform) {
            return platformLinks.contains { $0.target.source == platform }
        }
        return (links[platform.rawValue] != nil || work.source == platform || viewingUnits?.contains(where:{ $0.links[platform.rawValue] != nil }) == true)
    }
    mutating func associate(_ target:Work) {
        noEntryPlatforms?.remove(target.source.rawValue)
        links[target.source.rawValue] = target
        confirmedProgress.remove(target.source.rawValue)
        mappedProgress.removeValue(forKey:target.source.rawValue)
        progressMappings?.removeValue(forKey:target.source.rawValue)
    }
}
struct ProgressMapping: Codable, Equatable {
    var localSeason: Int
    var targetSeason: Int
    var episodeOffset: Int
}
extension TrackingRecord {
    func payload(for target:Work) throws -> TrackingRecord {
        var result = self
        if result.progressDisabled.contains(target.source.rawValue) { return result }
        if target.id != work.id {
            guard confirmedProgress.contains(target.source.rawValue) else { result.progressDisabled.insert(target.source.rawValue); return result }
            if work.kind == .tv {
                guard let mapping = progressMappings?[target.source.rawValue], mapping.localSeason == season else {
                    throw APIError.message("请重新核对 \(target.source.title) 的季度与集数对应关系")
                }
                result.season = mapping.targetSeason
                result.progress = progress + mapping.episodeOffset
                guard result.progress > 0 else { throw APIError.message("映射后的集数必须大于 0") }
            }
        }
        if target.source == .trakt && target.kind == .tv && result.progress <= 0 {
            throw APIError.message("同步 Trakt 剧集前，请选择实际观看的集数")
        }
        return result
    }
}

/// Storage and platform adapters retain their fixed ten-point unit. UI input is always percent.
enum PercentRating {
    static func storedValue(_ text:String) -> Double? {
        guard let value = Double(text), value.isFinite, value > 0, value <= 100 else { return nil }
        return value / 10
    }
    static func displayValue(_ stored:Double) -> Double { stored * 10 }
}

struct Delivery: Codable, Equatable, Identifiable {
    var id = UUID()
    var record: TrackingRecord
    var target: Work
    var unitID: String? = nil
    var associationID: String? = nil
    var fields: Set<SyncField>?
    var attempts: [SyncAttempt]?
    var errorDetail: String?
    var syncIdentity: String?
    var syncSignature: String?
    var state = "等待同步"
    var isPending: Bool { !["已同步","已跳过"].contains(state) }
    var isError: Bool { isPending && !["等待同步","同步中"].contains(state) }
    static func planned(record:TrackingRecord, target:Work, association:PlatformAssociation, fields:Set<SyncField>, payload:() throws -> TrackingRecord) -> Delivery {
        do {
            if fields.contains(.progress), association.mapping?.matchedEpisodeCount ?? 0 == 0 { throw ProgressSyncSkipped() }
            var value = try payload(); value.syncFields = fields
            return Delivery(record:value,target:target,associationID:association.id,fields:fields)
        } catch is ProgressSyncSkipped {
            return Delivery(record:record,target:target,associationID:association.id,fields:fields,attempts:[SyncAttempt(contents:ProgressSyncSkipped().localizedDescription)],state:"已跳过")
        } catch {
            return Delivery(record:record,target:target,associationID:association.id,fields:fields,errorDetail:error.localizedDescription,state:"失败")
        }
    }
    var contents: String {
        if state == "已跳过" { return ProgressSyncSkipped().localizedDescription }
        let fields = fields ?? record.syncFields ?? [.rating,.status,.progress]
        var items: [String] = []
        if fields.contains(.rating) {
            if let score = record.score {
                let sent = target.source == .anilist ? (score*10).rounded() : target.source == .tmdb ? max(0.5,(score*2).rounded()/2) : max(1,score.rounded())
                items.append("评分：\((score * 10).formatted()) / 100 → \(sent.formatted()) / \(target.source == .anilist ? 100 : 10)（\(record.ratingOrigin ?? "作品评分")）")
            } else if record.scoreCleared == true { items.append("清除评分") }
        }
        if fields.contains(.status) { items.append("状态：" + record.status) }
        if fields.contains(.progress) {
            if let history = record.episodeHistory {
                items.append("第 \(record.syncSeason ?? record.season) 季已看：" + (history.isEmpty ? "无（归零）" : history.map { "S\($0.season)E\($0.number)" }.joined(separator:"、")))
            } else { items.append("进度：\(record.progress) \(target.kind == .manga ? "话，\(record.volumes) 卷" : "集")") }
        }
        return items.joined(separator:"\n")
    }
    var date = Date()
}
struct Backup: Codable {
    var recordsRevision = UUID()
    var associationsRevision = UUID()
    var displayRevision = UUID()
    enum CodingKeys:String,CodingKey {
        case bookFormats, acknowledgedDeliveryErrors, version, records, deliveries, translations, handledHistory, localizations, associations, history, recommendations
    }
    var bookFormats: [String:String]? { didSet { displayRevision = UUID() } }
    var acknowledgedDeliveryErrors: [String:String]?
    var version = 1
    var records: [String: TrackingRecord] = [:] { didSet { recordsRevision = UUID() } }
    var deliveries: [Delivery] = []
    var translations: [String:[String]] = [:]
    var handledHistory: Set<String> = []
    var localizations: LocalizationArchive? { didSet { displayRevision = UUID() } }
    var associations: [String:AssociationState]? { didSet { associationsRevision = UUID() } }
    var history: [ArchivedHistory]?
    var recommendations: [String:[Work]]?
}
/// OAuth credentials have one authoritative Keychain item per account. A process death
/// can leave either complete version, never a new access token with an old refresh token.
final class CredentialVault: @unchecked Sendable {
    private static let groups = ["trakt":["trakt.clientID","trakt.token","trakt.refresh"],
                                 "mal":["mal.clientID","mal.token","mal.refresh"]]
    private let lock = NSRecursiveLock()
    private let readItem:(String) throws -> String
    private let writeItem:(String,String) throws -> Void
    private let changed:(String) -> Void
    init(read:@escaping (String) throws -> String,write:@escaping (String,String) throws -> Void,
         changed:@escaping (String) -> Void = { _ in }) {
        readItem = read; writeItem = write; self.changed = changed
    }
    private func group(_ name:String) -> String? {
        Self.groups.first { $0.value.contains(name) }?.key
    }
    private func readGroup(_ service:String) throws -> [String:String] {
        let names = Self.groups[service]!
        let stored = try readItem("oauth-group.v1." + service)
        if !stored.isEmpty {
            guard let data = stored.data(using:.utf8),
                  let values = try? JSONDecoder().decode([String:String].self,from:data),
                  Set(values.keys) == Set(names) else { throw APIError.message("账号凭据组损坏，已停止读写") }
            return values
        }
        return try Dictionary(uniqueKeysWithValues:names.map { ($0,try readItem($0)) })
    }
    func read(_ names:[String]) throws -> [String:String] {
        lock.lock(); defer { lock.unlock() }
        var values:[String:String] = [:], groups:[String:[String:String]] = [:]
        for name in names {
            if let service = group(name) {
                if groups[service] == nil { groups[service] = try readGroup(service) }
                values[name] = groups[service]![name]!
            } else { values[name] = try readItem(name) }
        }
        return values
    }
    func write(_ changes:[String:String]) throws {
        lock.lock(); defer { lock.unlock() }
        for (service,updates) in Dictionary(grouping:changes.keys,by:{ group($0) ?? $0 }).sorted(by:{ $0.key < $1.key }) {
            if Self.groups[service] != nil {
                var values = try readGroup(service)
                let modified = updates.filter { values[$0] != changes[$0] }.sorted()
                guard !modified.isEmpty else { continue }
                for name in updates { values[name] = changes[name] }
                let data = try JSONEncoder().encode(values)
                try writeItem("oauth-group.v1." + service,String(decoding:data,as:UTF8.self))
                // The complete group is authoritative even if cleanup is interrupted.
                for name in Self.groups[service]! { try? writeItem(name,"") }
                for name in modified { changed(name) }
            } else {
                for name in updates.sorted() {
                    guard try readItem(name) != changes[name]! else { continue }
                    try writeItem(name,changes[name]!)
                    changed(name)
                }
            }
        }
    }
    func write(_ changes:[String:String],ifUnchanged expected:[String:String]) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard try read(Array(expected.keys)) == expected else { return false }
        try write(changes)
        return true
    }
}

enum Credentials {
    static let didChange = Notification.Name("AniShelf.credentialsChanged")
    private static let vault = CredentialVault(read:readItem,write:writeItem,changed:{ name in
        NotificationCenter.default.post(name:didChange,object:name)
    })
    static func read(_ name:String) -> String { (try? readChecked(name)) ?? "" }
    static func readChecked(_ name:String) throws -> String { try readValuesChecked([name])[name]! }
    static func readValuesChecked(_ names:[String]) throws -> [String:String] { try vault.read(names) }
    static func write(_ name:String,_ value:String) throws { try writeValues([name:value]) }
    static func writeValues(_ values:[String:String]) throws { try vault.write(values) }
    static func writeValues(_ values:[String:String],ifUnchanged expected:[String:String]) throws -> Bool {
        try vault.write(values,ifUnchanged:expected)
    }
    private static func readItem(_ name:String) throws -> String {
        let q: [String: Any] = [kSecClass as String:kSecClassGenericPassword, kSecAttrService as String:"app.anishelf.connections", kSecAttrAccount as String:name, kSecReturnData as String:true]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &item)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess, let data = item as? Data, let value = String(data:data,encoding:.utf8) else { throw APIError.message("无法读取凭据（\(status)）") }
        return value
    }
    private static func writeItem(_ name: String, _ value: String) throws {
        let q: [String: Any] = [kSecClass as String:kSecClassGenericPassword, kSecAttrService as String:"app.anishelf.connections", kSecAttrAccount as String:name]
        if value.isEmpty {
            let status = SecItemDelete(q as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw APIError.message("无法删除凭据（\(status)）") }
            return
        }
        let a: [String: Any] = [kSecValueData as String:Data(value.utf8), kSecAttrAccessible as String:kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        var status = SecItemUpdate(q as CFDictionary, a as CFDictionary)
        if status == errSecItemNotFound { status = SecItemAdd(q.merging(a) { _, n in n } as CFDictionary, nil) }
        if status == errSecMissingEntitlement {
            throw APIError.message("当前安装缺少钥匙串签名权限（-34018），请安装正式签名的 AniShelf 后重试。")
        }
        guard status == errSecSuccess else { throw APIError.message("无法保存凭据（\(status)）") }
    }
    static let names = ["openai.key", "deepseek.key", "tmdb.token", "tmdb.session", "trakt.clientID", "trakt.token", "trakt.refresh", "anilist.token", "mal.clientID", "mal.token", "mal.refresh", "bangumi.token"]
}
enum AccountState: Equatable {
    case disconnected, checking, connected(String), expired, unavailable
    var title:String {
        switch self {
        case .disconnected: "未登录"
        case .checking: "正在检查"
        case .connected(let name): name.isEmpty ? "连接正常" : "已登录：" + name
        case .expired: "登录已失效，请重新登录"
        case .unavailable: "暂时无法验证，稍后重试"
        }
    }
}

@MainActor @Observable final class AccountHealth {
    static let shared = AccountHealth()
    private(set) var states:[Catalog:AccountState] = [:]
    @ObservationIgnored private var checked:[Catalog:Date] = [:]
    @ObservationIgnored private var signatures:[Catalog:[String:String]] = [:]
    @ObservationIgnored private var checking = Set<Catalog>()
    var expiredPlatforms:[Catalog] { Catalog.allCases.filter { states[$0] == .expired } }
    func invalidate(_ source:Catalog,token:String,read:(String) -> String = Credentials.read) {
        guard !token.isEmpty, read(source.rawValue + ".token") == token else { return }
        states[source] = .expired; checked[source] = nil
    }
    func check(_ source:Catalog,force:Bool = false,api suppliedAPI:CatalogAPI? = nil,
               recover:((Catalog) async throws -> Void)? = nil) async {
        guard !checking.contains(source) else { return }
        let api = suppliedAPI ?? .shared
        func snapshot() throws -> [String:String] {
            try Dictionary(uniqueKeysWithValues:Credentials.names.filter { $0.hasPrefix(source.rawValue + ".") }.map { ($0,try api.credentialChecked($0)) })
        }
        var signature:[String:String]
        do { signature = try snapshot() }
        catch { states[source] = .unavailable; checked[source] = nil; return }
        guard signature[source.rawValue + ".token"]?.isEmpty == false else {
            states[source] = .disconnected; signatures[source] = signature; return
        }
        if !force, signatures[source] == signature, let date = checked[source], Date().timeIntervalSince(date) < (states[source] == .unavailable ? 60 : 900) { return }
        checking.insert(source); states[source] = .checking
        defer {
            checking.remove(source)
            do {
                if try snapshot() != signature { states[source] = nil; checked[source] = nil }
            } catch { states[source] = .unavailable; checked[source] = nil }
        }
        do {
            let name:String
            do { name = try await api.accountName(source) }
            catch {
                guard Self.isUnauthorized(error), [.trakt,.mal].contains(source),
                      signature[source.rawValue + ".refresh"]?.isEmpty == false,
                      try snapshot() == signature, let recover else { throw error }
                do { try await recover(source) }
                catch let failure as HTTPFailure where failure.status == 400 { throw APIError.unauthorized }
                signature = try snapshot()
                name = try await api.accountName(source)
            }
            guard try snapshot() == signature else { return }
            states[source] = .connected(name)
        } catch {
            do { guard try snapshot() == signature else { return } }
            catch { states[source] = .unavailable; checked[source] = nil; return }
            if Task.isCancelled { states[source] = nil; checked[source] = nil; return }
            states[source] = Self.isUnauthorized(error) ? .expired : .unavailable
        }
        signatures[source] = signature; checked[source] = Date()
    }
    static func isUnauthorized(_ error:Error) -> Bool {
        if case APIError.unauthorized = error { return true }
        return (error as? HTTPFailure)?.status == 401
    }
}

struct HTTPFailure: LocalizedError {
    var status: Int
    var reason: String
    var errorDescription: String? { reason }
}

private struct ParsedJSON: @unchecked Sendable {
    let object: Any
    init(data:Data) throws { object = try JSONSerialization.jsonObject(with:data) }
}
@MainActor final class CatalogAPI {
    static let shared = CatalogAPI()
    var artworkRequests: [String:Task<MediaArtwork,Error>] = [:]
    var artworkGenerations: [String:UUID] = [:]
    let session: URLSession
    let credential: (String) -> String
    let credentialChecked:(String) throws -> String
    let diagnostics: DiagnosticLog
    init(session: URLSession = .shared, credential: ((String) -> String)? = nil,
         credentialChecked:((String) throws -> String)? = nil, diagnostics:DiagnosticLog? = nil) {
        self.session = session; self.credential = credential ?? Credentials.read
        self.credentialChecked = credentialChecked ?? credential.map { reader in { reader($0) } } ?? Credentials.readChecked
        self.diagnostics = diagnostics ?? .shared
    }
    func request(_ address: String, method: String = "GET", headers: [String:String] = [:], body: [String:Any]? = nil, form: [String:String]? = nil, timeout:TimeInterval = 30) async throws -> Any {
        try await response(address,method:method,headers:headers,body:body,form:form,timeout:timeout).0
    }
    private func response(_ address: String, method: String = "GET", headers: [String:String] = [:], body: [String:Any]? = nil, form: [String:String]? = nil, timeout:TimeInterval = 30, report: ((Int) -> Void)? = nil, retryAuthentication:Bool = true) async throws -> (Any, Int) {
        try Task.checkCancellation()
        guard let url = URL(string:address) else { throw APIError.message("地址无效") }
        var r = URLRequest(url:url,cachePolicy:.reloadIgnoringLocalCacheData); r.httpMethod = method; r.timeoutInterval = timeout
        r.setValue("AniShelf/2.0 (personal tracking client)", forHTTPHeaderField:"User-Agent")
        for (k,v) in headers { r.setValue(v, forHTTPHeaderField:k) }
        if let body { r.httpBody = try JSONSerialization.data(withJSONObject:body); r.setValue("application/json", forHTTPHeaderField:"Content-Type") }
        if let form {
            var c = URLComponents(); c.queryItems = form.sorted { $0.key < $1.key }.map { URLQueryItem(name:$0.key,value:$0.value) }
            r.httpBody = c.percentEncodedQuery?.data(using:.utf8); r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField:"Content-Type")
        }
        let d: Data; let response: URLResponse
        do {
            let permits = url.host == "api.deepseek.com" ? RequestPermits.deepSeek : nil
            if let permits { try await permits.acquire() }
            defer { permits?.release() }
            try Task.checkCancellation()
            (d,response) = try await session.data(for:r)
        }
        catch { if !Task.isCancelled { diagnostics.record(component:"network",message:"网络请求失败，错误代码 \((error as NSError).code)",url:url,method:method) }; throw error }
        guard let h = response as? HTTPURLResponse else { throw APIError.message("没有收到响应") }
        report?(h.statusCode)
        if h.statusCode == 401, let authorization = headers["Authorization"], authorization.hasPrefix("Bearer ") {
            let sources:[String:Catalog] = ["api.trakt.tv":.trakt,"api.myanimelist.net":.mal,"api.bgm.tv":.bangumi,"api.themoviedb.org":.tmdb,"graphql.anilist.co":.anilist]
            if let source = sources[url.host ?? ""] {
                let failedToken = String(authorization.dropFirst(7))
                let requestedSession = URLComponents(url:url,resolvingAgainstBaseURL:false)?.queryItems?.first(where:{ $0.name == "session_id" })?.value ?? body?["session_id"] as? String
                if source != .tmdb || requestedSession == nil || requestedSession == credential("tmdb.session") {
                    AccountHealth.shared.invalidate(source,token:failedToken,read:credential)
                }
                #if os(iOS)
                if retryAuthentication, self === CatalogAPI.shared, [.trakt,.mal].contains(source), !credential(source.rawValue + ".refresh").isEmpty {
                    if credential(source.rawValue + ".token") == failedToken { try await PlatformLogin.shared.refresh(source) }
                    let current = credential(source.rawValue + ".token")
                    if !current.isEmpty, current != failedToken {
                        var refreshed = headers; refreshed["Authorization"] = "Bearer " + current
                        return try await self.response(address,method:method,headers:refreshed,body:body,form:form,timeout:timeout,report:report,retryAuthentication:false)
                    }
                }
                #endif
            }
        }
        guard (200..<300).contains(h.statusCode) else {
            let payload = (try? JSONSerialization.jsonObject(with:d)) as? [String:Any]
            let remoteMessage = (payload?["status_message"] as? String) ?? (payload?["description"] as? String) ?? (payload?["message"] as? String) ?? (payload?["error"] as? [String:Any])?["message"] as? String ?? ""
            // Never log prompts, request bodies, credentials, or raw response data.
            let fields = (body?.keys.sorted() ?? []).joined(separator:",")
            var reason = DiagnosticLog.redacted(remoteMessage)
            for key in Credentials.names { let secret = credential(key); if !secret.isEmpty { reason = reason.replacingOccurrences(of:secret,with:"[REDACTED]") } }
            diagnostics.record(component:url.host ?? "api",message:"HTTP \(h.statusCode); fields=\(fields); \(reason)",url:url,method:method,status:h.statusCode)
            let summary = h.statusCode == 401 ? "登录已过期，请重新连接" : "请求失败（\(h.statusCode)）"
            throw HTTPFailure(status:h.statusCode,reason:reason.isEmpty ? summary : summary + "：" + reason)
        }
        let pageCount = Int(h.value(forHTTPHeaderField: "X-Pagination-Page-Count") ?? "1") ?? 1
        if d.isEmpty { return ([:] as [String:Any],pageCount) }
        let result = try await Task.detached(priority:.userInitiated) { try ParsedJSON(data:d) }.value.object
        if let errors = (result as? [String:Any])?["errors"] { diagnostics.record(component:url.host ?? "api",message:"GraphQL 返回错误",url:url,method:method,status:h.statusCode); throw APIError.message("服务返回错误：\(errors)") }
        return (result,pageCount)
    }
    func search(_ source: Catalog, kind: WorkKind, query: String, page: Int = 1, filters: AniListFilters = AniListFilters(), provider:ProviderFilters = ProviderFilters()) async throws -> [Work] {
        let q = query.addingPercentEncoding(withAllowedCharacters:.urlQueryAllowed.subtracting(CharacterSet(charactersIn:"&+#?"))) ?? ""
        let token = credential("\(source.rawValue).token")
        switch source {
        case .tmdb:
            guard kind != .manga else { return [] }
            guard !token.isEmpty else { throw APIError.message("请在连接设置中填写 TMDB 读取令牌") }
            let route = query.isEmpty ? "\(kind.rawValue)/popular" : "search/\(kind.rawValue)"
            let root = try await request("https://api.themoviedb.org/3/\(route)?language=zh-CN&query=\(q)&page=\(page)&include_adult=true", headers:["Authorization":"Bearer \(token)"]) as? [String:Any] ?? [:]
            return (root["results"] as? [[String:Any]] ?? []).map { x in
                Work(source:source, remoteID:"\(x["id"] ?? "")", kind:kind, title:x["title"] as? String ?? x["name"] as? String ?? "", original:x["original_title"] as? String ?? x["original_name"] as? String ?? "", overview:x["overview"] as? String ?? "", image:(x["poster_path"] as? String).map { "https://image.tmdb.org/t/p/w500\($0)" } ?? "", year:String((x["release_date"] as? String ?? x["first_air_date"] as? String ?? "").prefix(4)), rating:x["vote_average"] as? Double, url:"https://www.themoviedb.org/\(kind.rawValue)/\(x["id"] ?? "")")
            }
        case .anilist:
            return try await anilistPage(kind:kind,query:query,page:page,filters:filters).works
        case .mal:
            guard kind != .movie else { return [] }
            let client = credential("mal.clientID")
            guard !client.isEmpty else { throw APIError.message("请填写 MyAnimeList Client ID") }
            let type = kind == .manga ? "manga" : "anime"
            let seasonal = kind != .manga && provider.year > 0 && !provider.season.isEmpty && query.isEmpty
            let route = seasonal ? "anime/season/\(provider.year)/\(provider.season.lowercased())?sort=\(provider.sort == "bypopularity" ? "anime_num_list_users" : "anime_score")" : query.isEmpty ? "\(type)/ranking?ranking_type=\(provider.sort.isEmpty ? "all" : provider.sort)" : "\(type)?q=\(q)"
            let fields = kind == .manga ? "mean,synopsis,start_date,media_type,num_volumes,num_chapters" : "mean,synopsis,start_date,num_episodes,media_type"
            let root = try await request("https://api.myanimelist.net/v2/\(route)&limit=20&offset=\((page-1)*20)&fields=\(fields)&nsfw=true",headers:["X-MAL-CLIENT-ID":client]) as? [String:Any] ?? [:]
            return (root["data"] as? [[String:Any]] ?? []).compactMap { row in
                guard let x = row["node"] as? [String:Any] else { return nil }
                return Work(source:source,remoteID:"\(x["id"] ?? "")",kind:kind,title:x["title"] as? String ?? "",overview:x["synopsis"] as? String ?? "",image:(x["main_picture"] as? [String:String])?["large"] ?? "",year:String((x["start_date"] as? String ?? "").prefix(4)),rating:x["mean"] as? Double,url:"https://myanimelist.net/\(type)/\(x["id"] ?? "")",format:kind == .manga ? Work.normalizedBookFormat(x["media_type"] as? String) : x["media_type"] as? String,episodeCount:x["num_episodes"] as? Int,volumeCount:x["num_volumes"] as? Int,chapterCount:x["num_chapters"] as? Int)
            }
        case .bangumi:
            let headers = token.isEmpty ? [:] : ["Authorization":"Bearer \(token)"]
            let types = kind == .manga ? [1] : provider.animationOnly ? [2] : [2,6]
            var conditions:[String:Any] = ["type":types]
            if provider.year > 0 {
                let month = ["WINTER":1,"SPRING":4,"SUMMER":7,"FALL":10][provider.season] ?? 1
                let nextMonth = provider.season.isEmpty ? 1 : month == 10 ? 1 : month+3
                let nextYear = provider.season.isEmpty || month == 10 ? provider.year+1 : provider.year
                conditions["air_date"] = [String(format:">=%04d-%02d-01",provider.year,month),String(format:"<%04d-%02d-01",nextYear,nextMonth)]
            }
            if !provider.genre.isEmpty { conditions["tag"] = [provider.genre] }
            if provider.minimumScore > 0 { conditions["rating"] = [">=\(provider.minimumScore)"] }
            let root = try await request("https://api.bgm.tv/v0/search/subjects?limit=20&offset=\((page-1)*20)",method:"POST",headers:headers,body:["keyword":query.trimmingCharacters(in:.whitespacesAndNewlines),"sort":provider.sort.isEmpty ? "match" : provider.sort,"filter":conditions]) as? [String:Any] ?? [:]
            return (root["data"] as? [[String:Any]] ?? []).map { x in Work(source:source,remoteID:"\(x["id"] ?? "")",kind:kind,title:(x["name_cn"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? x["name"] as? String ?? "",original:x["name"] as? String ?? "",overview:x["summary"] as? String ?? "",image:(x["images"] as? [String:String])?["large"] ?? "",year:String((x["date"] as? String ?? "").prefix(4)),rating:(x["rating"] as? [String:Any])?["score"] as? Double,url:"https://bgm.tv/subject/\(x["id"] ?? "")",format:Work.bangumiBookFormat(x["platform"],kind:kind),episodeCount:kind == .manga ? nil : x["eps"] as? Int,bookSeries:kind == .manga ? x["series"] as? Bool : nil,volumeCount:x["volumes"] as? Int,chapterCount:kind == .manga ? x["eps"] as? Int : nil) }
        case .trakt:
            guard kind != .manga else { return [] }
            let type = kind == .tv ? "show" : "movie"
            let route = query.isEmpty ? "\(type == "show" ? "shows" : "movies")/\(provider.sort.isEmpty ? "popular" : provider.sort)" : "search/\(type)"
            var parameters = URLComponents()
            if provider.year > 0 { parameters.queryItems = [URLQueryItem(name:"years",value:String(provider.year))] }
            if !provider.genre.isEmpty { parameters.queryItems = (parameters.queryItems ?? []) + [URLQueryItem(name:"genres",value:provider.genre)] }
            let extra = parameters.percentEncodedQuery.map { "&" + $0 } ?? ""
            let rows = try await request("https://api.trakt.tv/\(route)?query=\(q)&page=\(page)&limit=30&extended=full\(extra)",headers:traktHeaders()) as? [[String:Any]] ?? []
            return rows.compactMap { Self.traktWork($0[type] as? [String:Any] ?? $0, kind: kind) }
        }
    }
    func tmdbPage(kind:WorkKind,query:String,page:Int,filters:TMDBFilters) async throws -> (works:[Work],hasNext:Bool) {
        let token = credential("tmdb.token")
        guard !token.isEmpty else { throw APIError.message("请在设置中填写 TMDB 读取令牌") }
        let searching = !query.isEmpty
        var parts = URLComponents(string:"https://api.themoviedb.org/3/\(searching ? "search" : "discover")/\(kind.rawValue)")!
        parts.queryItems = [URLQueryItem(name:"language",value:"zh-CN"),URLQueryItem(name:"page",value:String(page)),URLQueryItem(name:"include_adult",value:"true")]
        if searching {
            parts.queryItems?.append(URLQueryItem(name:"query",value:query))
            if filters.year > 0 { parts.queryItems?.append(URLQueryItem(name:kind == .movie ? "primary_release_year" : "first_air_date_year",value:String(filters.year))) }
        } else { parts.queryItems? += filters.parameters(kind:kind) }
        let root = try await request(parts.url!.absoluteString,headers:["Authorization":"Bearer \(token)"]) as? [String:Any] ?? [:]
        let works = (root["results"] as? [[String:Any]] ?? []).map { x in
            Work(source:.tmdb,remoteID:"\(x["id"] ?? "")",kind:kind,title:x["title"] as? String ?? x["name"] as? String ?? "",original:x["original_title"] as? String ?? x["original_name"] as? String ?? "",overview:x["overview"] as? String ?? "",image:(x["poster_path"] as? String).map { "https://image.tmdb.org/t/p/w500\($0)" } ?? "",year:String((x["release_date"] as? String ?? x["first_air_date"] as? String ?? "").prefix(4)),rating:x["vote_average"] as? Double,url:"https://www.themoviedb.org/\(kind.rawValue)/\(x["id"] ?? "")",backdrop:(x["backdrop_path"] as? String).map { "https://image.tmdb.org/t/p/w1280\($0)" })
        }
        return (works,page < min(root["total_pages"] as? Int ?? 1,500))
    }
    func accountName(_ source:Catalog) async throws -> String {
        let token = credential(source.rawValue + ".token")
        guard !token.isEmpty else { throw APIError.unauthorized }
        if source == .anilist { return try await AniListAPI(session:session).viewer(token:token).name }
        if source == .bangumi { return try await bangumiViewer(token:token) }
        var headers = ["Authorization":"Bearer " + token]
        let address:String
        switch source {
        case .trakt:
            headers["trakt-api-key"] = credential("trakt.clientID"); headers["trakt-api-version"] = "2"
            address = "https://api.trakt.tv/users/settings"
        case .mal: address = "https://api.myanimelist.net/v2/users/@me"
        case .tmdb:
            let session = credential("tmdb.session")
            address = session.isEmpty ? "https://api.themoviedb.org/3/authentication" : "https://api.themoviedb.org/3/account?session_id=" + (session.addingPercentEncoding(withAllowedCharacters:.urlQueryAllowed.subtracting(CharacterSet(charactersIn:"&+#?"))) ?? "")
        default: throw APIError.message("不支持的账号")
        }
        let root = try await response(address,headers:headers,retryAuthentication:false).0 as? [String:Any] ?? [:]
        if source == .tmdb, credential("tmdb.session").isEmpty {
            guard root["success"] as? Bool == true else { throw APIError.message("TMDB 未确认读取令牌") }
            return "读取令牌有效 · 评分账号未登录"
        }
        let user = source == .trakt ? root["user"] as? [String:Any] ?? [:] : root
        guard let name = user["username"] as? String ?? user["name"] as? String, !name.isEmpty else { throw APIError.message("平台未返回账号信息") }
        return name
    }
    func bangumiViewer(token:String) async throws -> String {
        guard !token.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { throw APIError.message("请填写 Bangumi 访问令牌") }
        let viewer = try await request("https://api.bgm.tv/v0/me",headers:["Authorization":"Bearer \(token)"]) as? [String:Any] ?? [:]
        guard let name = viewer["nickname"] as? String ?? viewer["username"] as? String else { throw APIError.message("Bangumi 未返回账号信息") }
        return name
    }
    func anilistPage(kind:WorkKind, query:String, page:Int, filters:AniListFilters) async throws -> (works:[Work], hasNext:Bool) {
        var options = filters
        if kind == .movie { options.format = "MOVIE" }
        let p = try await AniListAPI(session:session).browse(kind:kind == .manga ? .manga : .anime,search:query,sort:filters.sort,page:page,filters:options,excludedFormat:kind == .tv && !filters.allAnime ? "MOVIE" : nil)
        let works = p.media.map { m in Work(source:.anilist,remoteID:String(m.id),kind:filters.allAnime && m.format == "MOVIE" ? .movie : kind,title:m.title.display,original:m.title.native ?? "",overview:m.description ?? "",image:m.coverURL?.absoluteString ?? "",year:m.seasonYear.map(String.init) ?? "",rating:m.averageScore.map { Double($0)/10 },url:m.siteUrl ?? "",backdrop:m.bannerImage,format:m.format,episodeCount:m.episodes,volumeCount:m.volumes,chapterCount:m.chapters) }
        return (works,p.hasNextPage)
    }
    static func traktWork(_ x: [String:Any], kind: WorkKind) -> Work? {
        guard let ids = x["ids"] as? [String:Any], let id = ids["trakt"] as? Int else { return nil }
        let images = x["images"] as? [String:[String]] ?? [:]
        let raw = images["poster"]?.first ?? images["thumb"]?.first ?? ""
        let image = raw.isEmpty ? "" : raw.hasPrefix("https://") ? raw : "https://" + raw.replacingOccurrences(of: "http://", with: "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return Work(source:.trakt, remoteID:String(id), kind:kind, title:x["title"] as? String ?? "未命名作品", original:x["title"] as? String ?? "", overview:x["overview"] as? String ?? "", image:image, year:(x["year"] as? Int).map(String.init) ?? "", rating:x["rating"] as? Double, url:"https://trakt.tv/\(kind == .tv ? "shows" : "movies")/\(ids["slug"] as? String ?? String(id))", tmdbID:ids["tmdb"] as? Int)
    }
    func traktHeaders() -> [String:String] {
        var headers = ["trakt-api-key":credential("trakt.clientID"),"trakt-api-version":"2"]
        let token = credential("trakt.token")
        if !token.isEmpty { headers["Authorization"] = "Bearer \(token)" }
        return headers
    }
    func traktPages(_ route: String) async throws -> [[String:Any]] {
        var rows: [[String:Any]] = []
        var page = 1
        repeat {
            try Task.checkCancellation()
            let (body,last) = try await response("https://api.trakt.tv/\(route)?page=\(page)&limit=100&extended=full,progress", headers:traktHeaders())
            rows += body as? [[String:Any]] ?? []
            if page >= last { break }
            page += 1
        } while true
        return rows
    }
    func history() async throws -> [(Work,Int,Int,String)] {
        let rows = try await request("https://api.trakt.tv/sync/history?limit=40&page=1&extended=full",headers:traktHeaders()) as? [[String:Any]] ?? []
        return rows.compactMap { row in
            let kind: WorkKind = row["show"] != nil ? .tv : .movie
            guard let x = row[kind == .tv ? "show" : "movie"] as? [String:Any], let work = Self.traktWork(x, kind:kind) else { return nil }
            let e = row["episode"] as? [String:Any] ?? [:]
            return (work,e["number"] as? Int ?? 1,e["season"] as? Int ?? 1,"\(row["id"] ?? "")")
        }
    }
    static func applyingChinese(_ rows: [[String:Any]], to work: Work) -> Work {
        var result = work
        let chinese = rows.filter { ($0["language"] as? String ?? "zh") == "zh" }
        let row = chinese.first { ($0["country"] as? String)?.lowercased() == "cn" } ?? chinese.first
        if let title = row?["title"] as? String, !title.isEmpty { result.title = title }
        if let overview = row?["overview"] as? String, !overview.isEmpty { result.overview = overview }
        return result
    }
    func localized(_ work: Work) async throws -> Work {
        guard work.source == .trakt else { return work }
        let route = work.kind == .movie ? "movies" : "shows"
        let rows = try await request("https://api.trakt.tv/\(route)/\(work.remoteID)/translations/zh",headers:traktHeaders()) as? [[String:Any]] ?? []
        return Self.applyingChinese(rows,to:work)
    }
    func remoteLibrary(_ source: Catalog) async throws -> [TrackingRecord] {
        if source == .anilist {
            let token = credential("anilist.token")
            let viewer = try await AniListAPI.shared.viewer(token:token)
            var records: [TrackingRecord] = []
            for kind in MediaKind.allCases {
                let entries = try await AniListAPI.shared.library(userID:viewer.id,kind:kind,token:token)
                records += entries.map { entry in
                    let m = entry.media
                    let work = Work(source:.anilist,remoteID:String(m.id),kind:kind == .manga ? .manga : m.format == "MOVIE" ? .movie : .tv,title:m.title.display,original:m.title.native ?? "",overview:m.description ?? "",image:m.coverURL?.absoluteString ?? "",year:m.seasonYear.map(String.init) ?? "",rating:m.averageScore.map { Double($0)/10 },url:m.siteUrl ?? "",format:m.format,episodeCount:m.episodes,volumeCount:m.volumes,chapterCount:m.chapters)
                    return TrackingRecord(work:work,score:entry.score.flatMap { $0 > 0 ? $0/10 : nil },progress:entry.progress,status:entry.status.title)
                }
            }
            return records
        }
        var records: [String:TrackingRecord] = [:]
        for type in ["movies","shows"] {
            let kind: WorkKind = type == "movies" ? .movie : .tv
            let key = type == "movies" ? "movie" : "show"
            for row in try await traktPages("sync/watched/\(type)") {
                guard let x = row[key] as? [String:Any], let work = Self.traktWork(x,kind:kind) else { continue }
                var record = TrackingRecord(work:work,status:kind == .movie ? "已完成" : "已观看")
                let seasons = row["seasons"] as? [[String:Any]] ?? []
                record.watchedCount = seasons.reduce(0) { $0 + (($1["episodes"] as? [[String:Any]])?.count ?? 0) }
                // Aggregate watched counts are not a season/episode cursor.
                record.progressDisabled.insert("trakt")
                records[work.id] = record
            }
            for row in try await traktPages("sync/ratings/\(type)") {
                guard let x = row[key] as? [String:Any], let work = Self.traktWork(x,kind:kind) else { continue }
                var record = records[work.id] ?? TrackingRecord(work:work,status:"已评分")
                record.score = (row["rating"] as? NSNumber)?.doubleValue
                record.progressDisabled.insert("trakt")
                records[work.id] = record
            }
        }
        return records.values.sorted { $0.work.title.localizedStandardCompare($1.work.title) == .orderedAscending }
    }
    func deleteSource(_ work:Work) async throws {
        let token = credential("\(work.source.rawValue).token")
        guard !token.isEmpty else { throw APIError.message("请先连接 \(work.source.title)") }
        guard let id = Int(work.remoteID), id > 0 else { throw APIError.message("作品编号无效") }
        switch work.source {
        case .anilist:
            try await AniListAPI(session:session).deleteListEntry(mediaID:id,token:token)
        case .trakt:
            let type = work.kind == .movie ? "movies" : "shows"
            for category in ["watchlist","collection","ratings","history"] {
                do {
                    _ = try await request("https://api.trakt.tv/sync/\(category)/remove",method:"POST",headers:traktHeaders(),body:[type:[["ids":["trakt":id]]]])
                } catch { throw APIError.message("Trakt 删除在 \(category) 步骤失败：\(error.localizedDescription)。重试会继续清理此作品。") }
            }
        case .mal:
            _ = try await request("https://api.myanimelist.net/v2/\(work.kind == .manga ? "manga" : "anime")/\(id)/my_list_status",method:"DELETE",headers:["Authorization":"Bearer \(token)"])
        case .tmdb:
            let userSession = credential("tmdb.session")
            guard !userSession.isEmpty else { throw APIError.message("请先登录 TMDB 账号") }
            var components = URLComponents(string:"https://api.themoviedb.org/3/\(work.kind.rawValue)/\(id)/rating")!
            components.queryItems = [URLQueryItem(name:"session_id",value:userSession)]
            _ = try await request(components.url!.absoluteString,method:"DELETE",headers:["Authorization":"Bearer \(token)"])
        case .bangumi:
            throw APIError.message("Bangumi 暂未开放条目取消收藏接口，请在 Bangumi 移除后重试")
        }
    }
    func save(_ record: TrackingRecord, to w: Work, report: ((SyncStep) -> Void)? = nil) async throws {
        let token = credential("\(w.source.rawValue).token")
        guard !token.isEmpty else { throw APIError.message("请先连接 \(w.source.title)") }
        let fields = record.syncFields ?? [.rating,.status,.progress]
        let rating = fields.contains(.rating)
        let progress = fields.contains(.progress) && !record.progressDisabled.contains(w.source.rawValue)
        let status = fields.contains(.status)
        let score = rating ? record.score.map { Int($0.rounded()) } : nil
        let clear = rating && record.scoreCleared == true
        var responsePageCount = 1
        func send(_ address:String, method:String = "POST", headers:[String:String] = [:], body:[String:Any]? = nil, form:[String:String]? = nil) async throws -> Any {
            let values = body ?? form?.mapValues { $0 as Any }
            let encoded = values.flatMap { try? JSONSerialization.data(withJSONObject:$0,options:[.sortedKeys,.prettyPrinted]) }
            var step = SyncStep(method:method,path:URL(string:address)?.path ?? "",requestBody:encoded.map { String(decoding:$0,as:UTF8.self) })
            do {
                let result = try await response(address,method:method,headers:headers,body:body,form:form,report:{ step.status = $0 })
                responsePageCount = result.1
                report?(step); return result.0
            } catch {
                step.status = (error as? HTTPFailure)?.status
                step.error = DiagnosticLog.redacted(error.localizedDescription)
                report?(step); throw error
            }
        }
        switch w.source {
        case .anilist:
            guard let id = Int(w.remoteID) else { throw APIError.message("作品编号无效") }
            var variables: [String:Any] = ["id":id]
            var args = "mediaId:$id", declarations = "$id:Int!"
            if status {
                variables["status"] = ["计划中":"PLANNING","进行中":"CURRENT","已完成":"COMPLETED","已暂停":"PAUSED","已放弃":"DROPPED","重温中":"REPEATING"][record.status] ?? "CURRENT"
                args += ",status:$status"; declarations += ",$status:MediaListStatus"
            }
            if rating, let value = record.score { variables["score"] = Int((value*10).rounded()) }
            if clear { variables["score"] = 0 }
            if variables["score"] != nil { args += ",scoreRaw:$score"; declarations += ",$score:Int" }
            if progress { variables["progress"] = record.progress; args += ",progress:$progress"; declarations += ",$progress:Int"
                if w.kind == .manga { variables["volumes"] = record.volumes; args += ",progressVolumes:$volumes"; declarations += ",$volumes:Int" }
            }
            guard variables.count > 1 else { return }
            _ = try await send("https://graphql.anilist.co",headers:["Authorization":"Bearer \(token)"],body:["query":"mutation(\(declarations)){SaveMediaListEntry(\(args)){id}}","variables":variables])
        case .mal:
            var form: [String:String] = [:]
            if status { form["status"] = ["计划中":w.kind == .manga ? "plan_to_read" : "plan_to_watch","进行中":w.kind == .manga ? "reading" : "watching","已完成":"completed","已暂停":"on_hold","已放弃":"dropped","重温中":w.kind == .manga ? "reading" : "watching"][record.status] ?? "completed" }
            if let score { form["score"] = String(max(1,score)) }; if clear { form["score"] = "0" }
            if progress { form[w.kind == .manga ? "num_chapters_read" : "num_watched_episodes"] = String(record.progress); if w.kind == .manga { form["num_volumes_read"] = String(record.volumes) } }
            guard !form.isEmpty else { return }
            _ = try await send("https://api.myanimelist.net/v2/\(w.kind == .manga ? "manga" : "anime")/\(w.remoteID)/my_list_status",method:"PATCH",headers:["Authorization":"Bearer \(token)"],form:form)
        case .bangumi:
            let headers = ["Authorization":"Bearer \(token)"]
            var episodeChanges: [([Int],Int)] = []
            if w.kind == .tv && progress {
                var rows: [[String:Any]] = [], total: Int?
                while total == nil || rows.count < total! {
                    try Task.checkCancellation()
                    let page = try await send("https://api.bgm.tv/v0/users/-/collections/\(w.remoteID)/episodes?episode_type=0&limit=100&offset=\(rows.count)",method:"GET",headers:headers) as? [String:Any] ?? [:]
                    guard let batch = page["data"] as? [[String:Any]], let size = page["total"] as? Int,
                          size >= 0, total == nil || total == size,
                          rows.count + batch.count <= size, !batch.isEmpty || rows.count == size else {
                        throw APIError.message("Bangumi 正片章节列表不完整，进度未写入")
                    }
                    total = size; rows += batch
                }
                let episodes = try rows.map { row -> [String:Any] in
                    guard let episode = row["episode"] as? [String:Any],
                          episode["subject_id"] == nil || String(describing:episode["subject_id"]!) == w.remoteID,
                          let state = row["type"] as? Int, (0...3).contains(state) else {
                        throw APIError.message("Bangumi 返回的章节或收藏状态无效，进度未写入")
                    }
                    return episode
                }
                let ordered = try BangumiEpisodeNumbering.orderedIDs(episodes)
                guard record.progress >= 0, record.progress <= ordered.count else {
                    throw APIError.message("Bangumi 输入进度超出当前条目正片集数，进度未写入")
                }
                let watched = Set(zip(rows,episodes).filter { $0.0["type"] as? Int == 2 }.compactMap { $0.1["id"] as? Int })
                let managed: Set<Int>, wanted: Set<Int>
                if let mapped = record.syncMappedEpisodes, let completed = record.syncWatchedEpisodes {
                    guard Set(completed).isSubset(of:Set(mapped)), mapped.allSatisfy({ $0 > 0 && $0 <= ordered.count }) else {
                        throw APIError.message("Bangumi 集对应超出当前条目正片集数，进度未写入")
                    }
                    managed = Set(mapped.map { ordered[$0 - 1] })
                    wanted = Set(completed.map { ordered[$0 - 1] })
                } else {
                    managed = Set(ordered); wanted = Set(ordered.prefix(record.progress))
                }
                episodeChanges = [(wanted.subtracting(watched).sorted(),2),(watched.intersection(managed).subtracting(wanted).sorted(),0)]
            }
            var body: [String:Any] = [:]
            if status { body["type"] = ["计划中":1,"已完成":2,"进行中":3,"已暂停":4,"已放弃":5,"重温中":3][record.status] ?? 3 }
            if let score { body["rate"] = max(1,score) }; if clear { body["rate"] = 0 }
            if w.kind == .manga && progress { body["ep_status"] = record.progress; body["vol_status"] = record.volumes }
            if !body.isEmpty { _ = try await send("https://api.bgm.tv/v0/users/-/collections/\(w.remoteID)",method:"POST",headers:headers,body:body) }
            for (ids,type) in episodeChanges {
                for start in stride(from:0,to:ids.count,by:100) {
                    _ = try await send("https://api.bgm.tv/v0/users/-/collections/\(w.remoteID)/episodes",method:"PATCH",headers:headers,body:["episode_id":Array(ids.dropFirst(start).prefix(100)),"type":type])
                }
            }
        case .trakt:
            let type = w.kind == .movie ? "movies" : "shows"
            if clear { _ = try await send("https://api.trakt.tv/sync/ratings/remove",headers:traktHeaders(),body:[type:[["ids":["trakt":Int(w.remoteID) ?? 0]]]]) }
            if let score { _ = try await send("https://api.trakt.tv/sync/ratings",headers:traktHeaders(),body:[type:[["ids":["trakt":Int(w.remoteID) ?? 0],"rating":max(1,score)]]]) }
            if progress {
                var history: [[String:Any]] = []
                var page = 1
                repeat {
                    let rows = try await send("https://api.trakt.tv/sync/history/\(type)/\(w.remoteID)?page=\(page)&limit=100",method:"GET",headers:traktHeaders()) as? [[String:Any]] ?? []
                    history += rows; page += 1
                } while page <= responsePageCount
                if w.kind == .tv, let episodes = record.episodeHistory {
                    let wanted = Set(episodes)
                    let missing = episodes.filter { ep in !history.contains { row in
                        let value = row["episode"] as? [String:Any]; return value?["season"] as? Int == ep.season && value?["number"] as? Int == ep.number
                    } }
                    if let scope = record.syncSeason {
                        let removals = history.compactMap { row -> Int? in
                            guard let ep = row["episode"] as? [String:Any], ep["season"] as? Int == scope, let number = ep["number"] as? Int,
                                  !wanted.contains(EpisodeAddress(season:scope,number:number)) else { return nil }
                            return row["id"] as? Int
                        }
                        if !removals.isEmpty { _ = try await send("https://api.trakt.tv/sync/history/remove",headers:traktHeaders(),body:["ids":removals]) }
                    }
                    if !missing.isEmpty {
                        let grouped = Dictionary(grouping:missing,by:\.season)
                        let seasons: [[String:Any]] = grouped.keys.sorted().map { number in ["number":number,"episodes":(grouped[number] ?? []).map { ["number":$0.number] }] }
                        _ = try await send("https://api.trakt.tv/sync/history",headers:traktHeaders(),body:[type:[["ids":["trakt":Int(w.remoteID) ?? 0],"seasons":seasons]]])
                    }
                } else if w.kind == .movie, history.isEmpty, record.status == "已完成" {
                    _ = try await send("https://api.trakt.tv/sync/history",headers:traktHeaders(),body:[type:[["ids":["trakt":Int(w.remoteID) ?? 0]]]])
                }
            }
        case .tmdb:
            guard rating, record.score != nil || clear else { return }
            let userSession = credential("tmdb.session")
            guard !userSession.isEmpty else { throw APIError.message("请在设置中登录 TMDB 账号以同步评分") }
            var url = URLComponents(string:"https://api.themoviedb.org/3/\(w.kind.rawValue)/\(w.remoteID)/rating")!
            url.queryItems = [URLQueryItem(name:"session_id",value:userSession)]
            _ = try await send(url.url!.absoluteString,method:clear ? "DELETE" : "POST",headers:["Authorization":"Bearer \(token)"],body:clear ? nil : ["value":max(0.5,((record.score ?? 0)*2).rounded()/2)])
        }
    }

}

/// Atomic writes retain the last readable generation. Unreadable files are never
/// treated as an empty store; recovery preserves the damaged bytes for inspection.

/// Owns commit order and the last durable generation, including conflict/recovery checks.
private final class BackupWriter: @unchecked Sendable {
    let queue = DispatchQueue(label:"AniShelf.Persistence",qos:.userInitiated)
    var expected:Data?
    var committed = Backup()
    var database:LibraryDatabase?
    func requiredDatabase() throws -> LibraryDatabase {
        guard let database else { throw APIError.message("资料库尚未完成迁移") }; return database
    }
    var cloudEditBase:Backup?
    func perform<T>(_ work:@escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with:Result(catching:work)) }
        }
    }
    func commit(_ snapshot:Backup,to file:URL) throws {
        let value:Backup
        if let base = cloudEditBase {
            value = try CloudProjection.rebase(snapshot,from:base,onto:committed)
        } else { value = snapshot }
        let db = try requiredDatabase()
        let next = try db.transaction { () throws -> String in
            let generation = try db.state("library.generation") ?? "0"
            guard Data(generation.utf8) == expected else { throw APIError.message("资料库已被其他窗口修改，请重新打开后保存") }
            let before = try db.query("SELECT total_changes()")[0][0]
            try db.saveBackup(value,previous:committed)
            if try db.state("cloud.librarySeeded") == nil {
                try db.captureCloudFields(CloudProjection.fields(value),namespace:"library")
                try db.setState("cloud.librarySeeded","1")
            } else {
                let changes = try CloudProjection.changedFields(value,previous:committed)
                try db.captureCloudChanges(changes.values,removed:changes.removed,namespace:"library")
            }
            guard try db.query("SELECT total_changes()")[0][0] != before else { return generation }
            let next = String((Int64(generation) ?? 0)+1)
            try db.setState("library.generation",next)
            return next
        }
        expected = Data(next.utf8); committed = value
        if cloudEditBase != nil { cloudEditBase = snapshot }
    }
}

struct LibrarySnapshot: Codable, Equatable {
    var credential: String
    var records: [TrackingRecord]
}
struct ArchivedHistory: Codable, Equatable {
    var work:Work
    var episode:Int
    var season:Int
    var event:String
}
struct ApplicationArchive: Codable, @unchecked Sendable {
    var version = 2
    var backup:Backup
    var snapshots:[String:LibrarySnapshot]
    var history:[ArchivedHistory]
    var recommendations:[String:[Work]]
    var preferences:[String:String]
    var credentials:[String:String]
    var diagnostics:Data
    var cloudJournal:ArchivedCloudJournal? = nil
}
/// Decoding the content graph happens before constructing the UI store.
struct PreparedTrackingLibrary: @unchecked Sendable {
    let database:LibraryDatabase
    let backup:Backup
    let snapshots:[String:LibrarySnapshot]
    let generation:Data
    @MainActor static func load(directory:URL,diagnostics:DiagnosticLog) async throws -> PreparedTrackingLibrary {
        try diagnostics.checkStorage()
        let database = try await Task.detached(priority:.userInitiated) { try LibraryDatabase(directory:directory) }.value
        try LibraryImportRecovery.recover(directory:directory,database:database,diagnostics:diagnostics)
        return try await Task.detached(priority:.userInitiated) {
            return PreparedTrackingLibrary(database:database,backup:try database.loadBackup() ?? Backup(),snapshots:try database.loadSnapshots(),generation:Data((try database.state("library.generation") ?? "0").utf8))
        }.value
    }
}
enum CloudChangeTrigger { case immediate, afterAssociationQuietPeriod }

@MainActor @Observable final class TrackingStore {
    @ObservationIgnored var cloudChange:((CloudChangeTrigger) -> Void)?
    @ObservationIgnored private var cloudApplying = false
    @ObservationIgnored var cloudPreferences:UserDefaults = .standard
    @ObservationIgnored var cloudReadCredentials:([String]) throws -> [String:String] = { names in
        var values = try Credentials.readValuesChecked(names)
        #if os(iOS)
        if names.contains("anilist.token"), let token = try TokenVault.readChecked() { values["anilist.token"] = token }
        #endif
        return values
    }
    @ObservationIgnored var cloudWriteCredentials:([String:String]) throws -> Void = Credentials.writeValues
    var backup = Backup() { didSet {
        backupRevision = UUID()
        if oldValue.recordsRevision != backup.recordsRevision { libraryIdentityIndex = nil }
        if oldValue.associationsRevision != backup.associationsRevision { associationIdentityIndex = nil }
    } }
    @ObservationIgnored private var backupRevision = UUID()
    @ObservationIgnored var libraryIdentityIndex: [String:String]?
    @ObservationIgnored private var associationIdentityIndex: [String:String]?
    private func cachedAssociation(for work:Work) -> AssociationState? {
        if let direct = backup.associations?[work.id] { return direct }
        if associationIdentityIndex == nil {
            var index: [String:String] = [:]
            for key in (backup.associations ?? [:]).keys.sorted() {
                for target in backup.associations?[key]?.links.values ?? Dictionary<String,Work>().values
                    where target.source == LibraryIdentity.primarySource(for:target.kind) && index[target.id] == nil {
                    index[target.id] = key
                }
            }
            associationIdentityIndex = index
        }
        return associationIdentityIndex?[work.id].flatMap { backup.associations?[$0] }
    }
    func indexedLibraryRecord(_ id:String) -> TrackingRecord? {
        if let direct = backup.records[id] { return direct }
        if libraryIdentityIndex == nil {
            var index: [String:String] = [:]
            for key in backup.records.keys.sorted() {
                for identity in backup.records[key]!.relatedWorkIDs where index[identity] == nil { index[identity] = key }
            }
            libraryIdentityIndex = index
        }
        return libraryIdentityIndex?[id].flatMap { backup.records[$0] }
    }
    var results: [Work] = []
    var recent: [(Work,Int,Int,String)] = []
    var library: [String: [TrackingRecord]] = [:] { didSet { platformRecordIndex = nil; platformLibraryRevision = UUID() } }
    private var platformLibraryRevision = UUID()
    @ObservationIgnored private var platformRecordIndex: [String:TrackingRecord]?
    func platformRecord(for id:String) -> TrackingRecord? {
        // Read the observable source even on a cache hit so shelves subscribe to updates.
        let snapshots = library
        if platformRecordIndex == nil {
            var index: [String:TrackingRecord] = [:]
            for records in snapshots.values { for record in records { index[record.id] = record } }
            platformRecordIndex = index
        }
        return platformRecordIndex?[id]
    }
    var libraryErrors: [String:String] = [:]
    var loadingLibrarySources = Set<Catalog>()
    var loadingLibrary:Bool { !loadingLibrarySources.isEmpty }
    @ObservationIgnored private var libraryRequests:[String:SharedAIRequest<Bool>] = [:]
    var searchSource: Catalog = .tmdb
    var browseFilters = AniListFilters()
    var hasMoreDiscoveries = false
    var loadingMore = false
    private var discoveryPage = 1
    var homeRecommendations: [Work] = []
    var recommendations: [String:[Work]] = [:]
    var searchTerms: [String] = []
    var searchNotices: [String] = []
    var translatingTitles = false
    var resolvingBookFormats = false
    private var pendingTitles: [String:Work] = [:]
    private var pendingOverviews: [String:SharedAIRequest<String>] = [:]
    private var attemptedTitles: Set<String> = []
    private var platformChecked: Set<String> = []
    private var bookFormatChecked: Set<String> = []
    private var titleBatchTask: Task<Void,Never>?
    private var searchTask: Task<SearchResult,Error>?
    var metadataErrors: [String:String] = [:]
    private var localizing: Set<String> = []
    private var libraryCredentials: [String:String] = [:]
    private var snapshots: [String:LibrarySnapshot] = [:]
    private let ai: Intelligence
    private let mediaSearch: MediaSearch
    private let api: CatalogAPI
    private var latestTitleIdentity: [String:String] = [:]
    private var metadataRevisions: [String:UUID] = [:]
    private func fingerprint(_ token:String) -> String { SHA256.hash(data:Data(token.utf8)).map { String(format:"%02x",$0) }.joined() }
    var busy = false
    var message: String?
    var kind: WorkKind = .tv
    var query = ""
    var pendingArchiveURL: URL?
    var selected: Work?
    var searchFocusRequest = UUID()
    var refreshRequest = UUID()
    var keyboardRefreshRequest = UUID()
    var refreshSource: Catalog?
    var platformDiscovery: Set<Catalog> = []
    var browsingRequests: Set<UUID> = []
    var browseCache: [String: (works:[Work], terms:[String], notices:[String], more:Bool, page:Int)] = [:]
    var wantsSearchFocus = false
    private var generation = UUID()
    private var dataRevision = UUID()
    private var historyGeneration = UUID()
    private var historyCredential:String?
    private var queuedSyncIDs = Set<UUID>()
    private var syncing = false
    private var deletingRemote = false
    private let file: URL
    private var storageError: Error?
    var startupFailure: String? { storageError?.localizedDescription }
    @ObservationIgnored private let persistence = BackupWriter()
    private var committedBackup:Backup {
        get { persistence.queue.sync { persistence.committed } }
        set { persistence.queue.sync { persistence.committed = newValue } }
    }
    private var expectedBackupData:Data? {
        get { persistence.queue.sync { persistence.expected } }
        set { persistence.queue.sync { persistence.expected = newValue } }
    }
    init(directory:URL = URL.applicationSupportDirectory.appending(path:"AniShelf"), api:CatalogAPI? = nil, intelligence:Intelligence? = nil, mediaSearch:MediaSearch? = nil, prepared:PreparedTrackingLibrary? = nil) {
        file = directory.appending(path:LibraryDatabase.filename)
        self.api = api ?? .shared; self.ai = intelligence ?? .shared; self.mediaSearch = mediaSearch ?? .shared
        do {
            if let prepared {
                persistence.database = prepared.database
                backup = prepared.backup; snapshots = prepared.snapshots
                expectedBackupData = prepared.generation
            } else {
                try self.api.diagnostics.checkStorage()
                let database = try LibraryDatabase(directory:directory)
                try LibraryImportRecovery.recover(directory:directory,database:database,diagnostics:self.api.diagnostics)
                persistence.database = database
                if let loaded = try database.loadBackup() { backup = loaded }
                expectedBackupData = Data((try database.state("library.generation") ?? "0").utf8)
                snapshots = try database.loadSnapshots()
            }
            for source in ["anilist","trakt"] {
                do {
                    let token = try self.api.credentialChecked("\(source).token")
                    if !token.isEmpty, snapshots[source]?.credential == fingerprint(token) {
                        library[source] = snapshots[source]?.records; libraryCredentials[source] = token
                    }
                } catch { libraryErrors[source] = error.localizedDescription }
            }
        } catch { storageError = error; message = "资料库读取失败，原始数据已保留：\(error.localizedDescription)" }
        committedBackup = backup
        recent = backup.history?.map { ($0.work,$0.episode,$0.season,$0.event) } ?? []
        historyCredential = try? self.api.credentialChecked("trakt.token")
        recommendations = backup.recommendations ?? [:]
        homeRecommendations = recommendations["anilist"] ?? []
    }
    @discardableResult private func persistSnapshots() -> Bool {
        do {
            _ = try persistence.queue.sync { try persistence.requiredDatabase().saveSnapshots(snapshots) }
            return true
        } catch { message = "平台片单缓存保存失败：\(error.localizedDescription)"; return false }
    }
    @discardableResult private func persistSnapshotsAsync() async -> Bool {
        let snapshot = snapshots, writer = persistence
        let outcome:Result<Void,Error> = await withCheckedContinuation { continuation in
            persistence.queue.async {
                continuation.resume(returning:Result { _ = try writer.requiredDatabase().saveSnapshots(snapshot) })
            }
        }
        if case .failure(let error) = outcome { message = "平台片单缓存保存失败：" + error.localizedDescription; return false }
        return true
    }
    @discardableResult func persist() -> Bool {
        prepareBackup()
        if cloudApplying, storageError == nil {
            persistLater(rollbackOnFailure:true)
            return true
        }
        do { try writeBackup(backup); return true }
        catch {
            backup = committedBackup
            recent = backup.history?.map { ($0.work,$0.episode,$0.season,$0.event) } ?? []
            recommendations = backup.recommendations ?? [:]; homeRecommendations = recommendations["anilist"] ?? []
            message = "保存失败：\(error.localizedDescription)"
            return false
        }
    }
    func exportApplicationData(credentials:[String:String], defaults:UserDefaults = .standard) throws -> Data {
        try LibraryArchive.encode(applicationSnapshot(credentials:credentials,defaults:defaults))
    }
    func exportApplicationDataAsync(credentials:[String:String], password:String = "", defaults:UserDefaults = .standard) async throws -> Data {
        let snapshot = try applicationSnapshot(credentials:credentials,defaults:defaults)
        return try await Task.detached(priority:.userInitiated) { try LibraryArchive.encode(snapshot,password:password) }.value
    }
    private func applicationSnapshot(credentials:[String:String],defaults:UserDefaults) throws -> ApplicationArchive {
        if let storageError { throw storageError }
        if backup.fillMissingLibraryDates() { try writeBackup(backup) }
        var preferences = ["anilist.clientID":defaults.string(forKey:"anilist.clientID") ?? "",
                           "workspace.destination":String(defaults.integer(forKey:"workspace.destination")),
                           "artwork.cacheLimitMB":String(defaults.object(forKey:"artwork.cacheLimitMB") as? Int ?? 512)]
        for key in LibraryImportRecovery.layoutKeys {
            if let value = defaults.object(forKey:key) as? NSNumber { preferences[key] = value.stringValue }
        }
        if let config = defaults.data(forKey:"cloud.configuration") {
            preferences["cloud.configuration"] = config.base64EncodedString()
        }
        if let events = defaults.stringArray(forKey:"cloud.events") {
            preferences["cloud.events"] = try JSONEncoder().encode(events).base64EncodedString()
        }
        if let date = defaults.object(forKey:"cloud.lastSuccess") as? Date {
            preferences["cloud.lastSuccess"] = String(date.timeIntervalSince1970)
        }
        if let library = try persistence.requiredDatabase().state("cloud.encryptedLibrary") {
            preferences["cloud.encryptedLibrary"] = library
        }
        var payload = backup
        payload.history = recent.map { ArchivedHistory(work:$0.0,episode:$0.1,season:$0.2,event:$0.3) }
        payload.recommendations = recommendations
        let archive = ApplicationArchive(backup:payload,snapshots:snapshots,
            history:recent.map { ArchivedHistory(work:$0.0,episode:$0.1,season:$0.2,event:$0.3) },
            recommendations:recommendations,preferences:preferences,credentials:credentials,diagnostics:try api.diagnostics.archiveData(),cloudJournal:try ArchivedCloudJournal.capture(persistence.requiredDatabase()))
        return archive
    }
    func importApplicationDataAsync(_ data:Data,password:String = "",defaults:UserDefaults = .standard,
                                    readCredential:(String) throws -> String = Credentials.readChecked,
                                    writeCredential:([String:String]) throws -> Void = Credentials.writeValues) async throws {
        let prepared = try await Task.detached(priority:.userInitiated) { try LibraryArchive.prepare(data,password:password) }.value
        try importApplicationData(data,defaults:defaults,readCredential:readCredential,writeCredential:writeCredential,prepared:prepared)
    }
    func importApplicationData(_ data:Data, password:String = "", defaults:UserDefaults = .standard, readCredential:(String) throws -> String = Credentials.readChecked, writeCredential:([String:String]) throws -> Void = Credentials.writeValues, prepared:PreparedApplicationImport? = nil) throws {
        guard !syncing else { throw APIError.message("请等待当前同步完成后再导入") }
        let input = try prepared ?? LibraryArchive.prepare(data,password:password)
        let archive = input.archive
        guard archive.backup.version == 1, archive.backup.records.allSatisfy({ $0.key == $0.value.id }) else { throw APIError.message("备份作品标识不匹配") }
        try api.diagnostics.validateArchive(archive.diagnostics)
        var importedBackup = archive.backup
        for id in Array(importedBackup.records.keys) { importedBackup.records[id]?.prepareUnits() }
        importedBackup.fillMissingLibraryDates()
        importedBackup.history = archive.history; importedBackup.recommendations = archive.recommendations
        if let storageError { throw storageError }
        let db = try persistence.requiredDatabase()
        let credentialNames = Credentials.names + LibraryImportRecovery.cloudCredentialNames.filter { archive.credentials[$0]?.isEmpty == false || ($0 != "cloud.libraryKey" && archive.preferences["cloud.configuration"] != nil) }
        let previousCredentials = Dictionary(uniqueKeysWithValues:try credentialNames.map { ($0,try readCredential($0)) })
        if let library = archive.preferences["cloud.encryptedLibrary"] {
            guard UUID(uuidString:library) != nil, archive.credentials["cloud.libraryKey"]?.isEmpty == false else {
                throw APIError.message("备份中的云同步密钥无效")
            }
            if let current = try db.state("cloud.encryptedLibrary"), current != library {
                throw APIError.message("备份属于另一个云资料库，请先重置本机再导入")
            }
        }
        let oldDiagnostics = try api.diagnostics.archiveData()
        let oldCommitted = committedBackup, oldExpected = expectedBackupData
        let importDirectory = file.deletingLastPathComponent()
        let importID = try LibraryImportRecovery.prepare(directory:importDirectory,credentials:previousCredentials,diagnostics:oldDiagnostics,preferences:archive.preferences,write:writeCredential)
        do {
            // Credentials are changed before the database commit; failures restore both sides.
            try writeCredential(Dictionary(uniqueKeysWithValues:credentialNames.map { ($0,archive.credentials[$0] ?? "") }))
            try api.diagnostics.restoreArchive(archive.diagnostics)
            try persistence.queue.sync {
                try db.transaction {
                    let generation = try db.state("library.generation") ?? "0"
                    guard Data(generation.utf8) == oldExpected else { throw APIError.message("资料库已被其他窗口修改，请重新打开后导入") }
                    try db.saveBackup(importedBackup,previous:oldCommitted)
                    try db.saveSnapshots(archive.snapshots)
                    if let journal = archive.cloudJournal {
                        try journal.restore(db)
                        try db.removeRetiredDrafts()
                    }
                    if let library = archive.preferences["cloud.encryptedLibrary"] {
                        try db.setState("cloud.encryptedLibrary",library)
                    }
                    try db.setState("import.committed",importID)
                    try db.setState("library.generation",String((Int64(generation) ?? 0)+1))
                }
                persistence.committed = importedBackup
                persistence.expected = Data(String((Int64(String(decoding:oldExpected ?? Data(),as:UTF8.self)) ?? 0)+1).utf8)
            }
        } catch {
            do { try LibraryImportRecovery.recover(directory:importDirectory,database:db,diagnostics:api.diagnostics,defaults:defaults,read:readCredential,write:writeCredential) }
            catch { storageError = APIError.message("导入恢复未完成：" + error.localizedDescription); throw storageError! }
            throw error
        }
        dataRevision = UUID()
        titleBatchTask?.cancel(); titleBatchTask = nil; pendingTitles = [:]
        pendingOverviews.values.forEach { $0.cancel() }; pendingOverviews = [:]
        generation = UUID(); historyGeneration = UUID(); searchTask?.cancel()
        backup = importedBackup; snapshots = archive.snapshots
        recent = archive.history.map { ($0.work,$0.episode,$0.season,$0.event) }
        recommendations = archive.recommendations; homeRecommendations = recommendations["anilist"] ?? []
        library = [:]; libraryCredentials = [:]
        for (source,snapshot) in snapshots {
            let token = archive.credentials["\(source).token"] ?? ""
            if !token.isEmpty, snapshot.credential == fingerprint(token) { library[source] = snapshot.records; libraryCredentials[source] = token }
        }
        for key in ["workspace.destination","artwork.cacheLimitMB"] {
            if let value = archive.preferences[key], let number = Int(value) {
                defaults.set(key == "artwork.cacheLimitMB" ? min(4096,max(0,number)) : number,forKey:key)
            }
        }
        defaults.set(archive.preferences["anilist.clientID"] ?? "",forKey:"anilist.clientID")
        do { try LibraryImportRecovery.recover(directory:importDirectory,database:db,diagnostics:api.diagnostics,defaults:defaults,read:readCredential,write:writeCredential) }
        catch { storageError = error; throw error }
        selected = nil; attemptedTitles = []; platformChecked = []; latestTitleIdentity = [:]
        historyCredential = archive.credentials["trakt.token"] ?? ""
    }
    private func writeBackup(_ value:Backup) throws {
        if let storageError { throw storageError }
        try persistence.queue.sync { try persistence.commit(value,to:file) }
    }
    /// Enqueue before yielding so later commits cannot overtake this snapshot.
    @discardableResult func persistAsync() async -> Bool {
        prepareBackup()
        if let storageError {
            backup = committedBackup
            message = "保存失败：" + storageError.localizedDescription
            return false
        }
        let snapshot = backup, revision = backupRevision, destination = file, writer = persistence
        let outcome:Result<Void,Error> = await withCheckedContinuation { continuation in
            writer.queue.async {
                continuation.resume(returning:Result { try writer.commit(snapshot,to:destination) })
            }
        }
        if case .failure(let error) = outcome {
            if revision == backupRevision {
                backup = committedBackup
                recent = backup.history?.map { ($0.work,$0.episode,$0.season,$0.event) } ?? []
                recommendations = backup.recommendations ?? [:]; homeRecommendations = recommendations["anilist"] ?? []
            }
            message = "保存失败：" + error.localizedDescription
            return false
        }
        return true
    }
    private func persistLater(rollbackOnFailure:Bool = false) {
        prepareBackup()
        guard storageError == nil else { return }
        let snapshot = backup, revision = backupRevision, destination = file, writer = persistence
        writer.queue.async { [weak self] in
            do { try writer.commit(snapshot,to:destination) }
            catch {
                let detail = error.localizedDescription, durable = writer.committed
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if rollbackOnFailure && self.backupRevision == revision {
                        self.backup = durable
                        self.recent = durable.history?.map { ($0.work,$0.episode,$0.season,$0.event) } ?? []
                    }
                    self.message = "保存失败：" + detail
                }
            }
        }
    }
    private func prepareBackup() {
        for id in Array(backup.records.keys) {
            guard var record = backup.records[id] else { continue }
            let status = record.status
            record.refreshOverallStatus()
            if record.status != status { backup.records[id] = record }
        }
        backup.fillMissingLibraryDates()
        backup.history = recent.map { ArchivedHistory(work:$0.0,episode:$0.1,season:$0.2,event:$0.3) }
        backup.recommendations = recommendations
    }
    func record(_ w: Work) -> TrackingRecord {
        if var record = libraryRecord(for:w) { record.prepareUnits(); return record }
        var record = platformRecord(for:w.id) ?? TrackingRecord(work:w)
        if w.source == .trakt { record.progressDisabled.insert("trakt") }
        let cached = cachedAssociation(for:w)
        if let association = cached {
            record.noEntryPlatforms = association.noEntryPlatforms
            record.links = association.links; record.confirmedProgress = association.confirmedProgress; record.progressMappings = association.progressMappings
            if let units = association.unitAssociations {
                record.applyUnitAssociations(units)
                if association.platformLinks == nil { record.platformLinks = nil }
            }
            if let links = association.platformLinks { record.platformLinks = links }
            record.retiredAssociationIDs = association.retiredAssociationIDs
        }
        record.prepareUnits()
        return record
    }
    func search() async {
        searchTask?.cancel()
        let g = UUID(); generation = g; busy = true; results = []; searchTerms = []; searchNotices = []; discoveryPage = 1; hasMoreDiscoveries = false
        let source = kind == .manga ? Catalog.anilist : searchSource
        let requestedKind = kind; let requestedQuery = query; let filters = browseFilters
        if source == .anilist && requestedQuery.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty {
            defer { if generation == g { busy = false } }
            do { let page = try await api.anilistPage(kind:requestedKind,query:"",page:1,filters:filters); guard generation == g else { return }; results = page.works; hasMoreDiscoveries = page.hasNext }
            catch { if generation == g { searchNotices = [error.localizedDescription] } }
            return
        }
        let task = Task { [weak self, mediaSearch] in
            try await mediaSearch.search(source,kind:requestedKind,query:requestedQuery,filters:filters) { partial in
                guard let self, self.generation == g else { return }
                self.results = partial.works; self.searchTerms = partial.terms
            }
        }
        searchTask = task
        defer { if generation == g { busy = false; searchTask = nil } }
        do {
            let result = try await task.value
            guard generation == g else { return }
            results = result.works; searchTerms = result.terms; searchNotices = result.notices
        } catch is CancellationError { }
        catch { if generation == g { searchNotices = [error.localizedDescription] } }
    }
    func loadMoreDiscoveries() async {
        guard !loadingMore, !busy, hasMoreDiscoveries else { return }
        loadingMore = true; defer { loadingMore = false }
        let g = generation; let next = discoveryPage + 1
        do {
            let page = try await api.anilistPage(kind:kind,query:query,page:next,filters:browseFilters)
            guard generation == g else { return }
            results = MediaLanguage.merge(results,page.works); hasMoreDiscoveries = page.hasNext; discoveryPage = next
        } catch { searchNotices = [error.localizedDescription] }
    }
    @ObservationIgnored private var homeRequest:SharedAIRequest<Bool>?
    func loadHome() async {
        let request = homeRequest ?? SharedAIRequest { [self] in await loadHomeContent(); return true }
        homeRequest = request
        defer { if request.isFinished, homeRequest === request { homeRequest = nil } }
        _ = try? await request.value()
    }
    private func loadHomeContent() async {
        let revision = dataRevision
        do {
            _ = try await AIRequestDeadline.map([Catalog.anilist,.tmdb,.trakt,.bangumi,.mal],limit:3) { source -> Bool in
                if source == .tmdb && self.api.credential("tmdb.token").isEmpty { return false }
                if source == .trakt && self.api.credential("trakt.clientID").isEmpty { return false }
                if source == .mal && self.api.credential("mal.clientID").isEmpty { return false }
                do {
                    let provider = ProviderFilters(sort:source == .bangumi ? "heat" : "",animationOnly:true)
                    let works = try await self.api.search(source,kind:.tv,query:"",filters:AniListFilters(sort:.trending),provider:provider)
                    try Task.checkCancellation()
                    guard self.dataRevision == revision else { return false }
                    self.recommendations[source.rawValue] = works
                    if source == .anilist { self.homeRecommendations = works }
                } catch {
                    try Task.checkCancellation()
                    self.api.diagnostics.record("warning",component:"home",message:source.title + " 推荐读取失败：" + error.localizedDescription)
                }
                return true
            }
            if dataRevision == revision { await persistAsync() }
        } catch { }
    }
    @ObservationIgnored private var dailyPickCache:[String:[Work]] = [:]
    @ObservationIgnored private var listCache:(key:String,records:[TrackingRecord])?
    func filteredRecords(media:String,bookFilter:BookFilter,status:String,matching:String,query:String,sort:LibrarySort) -> [TrackingRecord] {
        let key = [backup.recordsRevision.uuidString,backup.displayRevision.uuidString,platformLibraryRevision.uuidString,media,bookFilter.rawValue,status,matching,query,sort.rawValue].joined(separator:"\u{1f}")
        if let cached = listCache, cached.key == key { return cached.records }
        let rows = backup.records.values.map { (record:$0,work:display($0.work)) }.filter { item in
            let record = item.record, work = item.work
            return (matching.isEmpty || (matching == "missingEpisodes" ? record.hasMissingEpisodeMapping : matching == "any" ? record.matchingPlatforms.contains(where:record.needsMatching) : Catalog(rawValue:matching).map(record.needsMatching) == true)) &&
                (media == "书籍" ? bookFilter.includes(work) : work.kind != .manga) &&
                (status == "全部" || (status == "已评分" ? record.score != nil : record.status == status)) &&
                (query.isEmpty || work.title.localizedCaseInsensitiveContains(query) || work.original.localizedCaseInsensitiveContains(query))
        }.sorted { sort.precedes($0.record,$1.record,titleA:$0.work.title,titleB:$1.work.title) }.map(\.record)
        listCache = (key,rows)
        return rows
    }
    func dailyPicks(manga:Bool, now:Date = Date()) -> [Work] {
        let day = Calendar.current.startOfDay(for:now).timeIntervalSince1970
        func key(_ work:Work) -> String { SHA256.hash(data:Data("\(day)|\(work.id)".utf8)).map { String(format:"%02x",$0) }.joined() }
        let cacheKey = "\(day)|\(manga)|\(backup.recordsRevision)"
        if let cached = dailyPickCache[cacheKey] { return cached }
        let ranked = backup.records.values.map(\.work).filter { ($0.kind == .manga) == manga }.map { (work:$0,rank:key($0)) }
        let result = ranked.sorted { $0.rank < $1.rank }.prefix(12).map(\.work)
        if dailyPickCache.count >= 4 { dailyPickCache.removeAll() }
        dailyPickCache[cacheKey] = result
        return result
    }
    /// Includes all associated entries when removing everywhere.
    static func removalTargets(_ record:TrackingRecord) -> [Work] {
        let units = (record.viewingUnits ?? []) + (record.archivedUnits ?? []) + (record.retainedSeasonTracking ?? [])
        let all = [record.work] + Array(record.links.values) + (record.platformLinks ?? []).map(\.target)
            + units.flatMap { Array($0.links.values) } + (record.sourceRecords ?? [:]).values.map(\.work)
        var seen = Set<String>()
        return all.filter { !(record.retiredAssociationIDs ?? []).contains($0.id) && seen.insert($0.id).inserted }.sorted { $0.id < $1.id }
    }
    func deleteSourceRecord(_ record:TrackingRecord) async throws {
        guard !syncing, !deletingRemote else { throw APIError.message("请等待当前同步或删除完成") }
        deletingRemote = true; defer { deletingRemote = false }
        try await removeRemoteTarget(record.work)
    }
    private func removeRemoteTarget(_ target:Work) async throws {
        // Persist queue removal before sending any destructive request, including partial failures.
        backup.deliveries.removeAll { $0.target.id == target.id }
        guard await persistAsync() else { throw APIError.message(message ?? "无法保存同步队列") }
        dataRevision = UUID(); historyGeneration = UUID()
        try await api.deleteSource(target)
        let key = target.source.rawValue
        library[key]?.removeAll { $0.work.id == target.id }
        snapshots[key]?.records.removeAll { $0.work.id == target.id }
        recent.removeAll { $0.0.id == target.id }
        guard persistSnapshots() else { throw APIError.message(message ?? "平台片单刷新保存失败") }
        guard await persistAsync() else { throw APIError.message(message ?? "平台已删除，本地刷新保存失败") }
    }
    func removeEverywhere(_ record:TrackingRecord) async throws {
        guard !syncing, !deletingRemote else { throw APIError.message("请等待当前同步或删除完成") }
        deletingRemote = true; defer { deletingRemote = false }
        var failures:[String] = []
        for target in Self.removalTargets(record) {
            if target.source == .bangumi { continue }
            // A metadata-only TMDB connection has no personal account record to delete.
            if target.source == .tmdb && api.credential("tmdb.session").isEmpty { continue }
            do { try await removeRemoteTarget(target) }
            catch { failures.append("\(target.source.title) · \(target.title)：\(error.localizedDescription)") }
        }
        guard failures.isEmpty else { throw APIError.message("以下条目尚未移除，本地记录保留。再次选择全平台移除可重试。\n" + failures.joined(separator:"\n")) }
        message = nil
        deleteRecords([record.id])
        if let message { throw APIError.message(message) }
    }
    func deleteRecords(_ ids:Set<String>) {
        guard !syncing else { message = "请等待当前同步完成后再移除"; return }
        let original = backup
        let removed = ids.compactMap { backup.records[$0] }
        let identities = Set(removed.flatMap { $0.relatedWorkIDs })
        for id in ids { backup.records.removeValue(forKey:id) }
        for id in identities {
            backup.associations?.removeValue(forKey:id)
            localizations.titles.removeValue(forKey:id); localizations.overviews.removeValue(forKey:id)
            backup.translations.removeValue(forKey:id)
        }
        backup.deliveries.removeAll { ids.contains($0.record.id) }
        guard persist() else { backup = original; return }
        if let selected, identities.contains(selected.id) { self.selected = nil }
    }
    func updateStatus(_ ids:Set<String>,to status:String) {
        let now = Date()
        var changed = false
        for id in ids {
            guard var record = backup.records[id] else { continue }
            let previous = record
            record.status = status
            if record.work.source == .tmdb && record.work.kind == .tv {
                var units = record.viewingUnits ?? []
                var retained = record.retainedSeasonTracking ?? []
                var targets = units.indices.filter { units[$0].season > 0 && units[$0].isTrackingMarked }
                let retainedTargets = retained.indices.filter { index in
                    retained[index].season > 0 && retained[index].isTrackingMarked && !units.contains(where:{ $0.season == retained[index].season })
                }
                if targets.isEmpty && retainedTargets.isEmpty { targets = Array(units.indices.filter { units[$0].season > 0 }.prefix(1)) }
                for index in targets { units[index].setStatus(status,at:now) }
                for index in retainedTargets { retained[index].setStatus(status,at:now) }
                record.viewingUnits = units
                if record.retainedSeasonTracking != nil { record.retainedSeasonTracking = retained }
                record.refreshOverallStatus()
            }
            guard record.hasTrackingChanges(from:previous) else { continue }
            record.modifiedAt = now
            backup.records[id] = record
            changed = true
        }
        if changed, persist() { cloudChange?(.immediate) }
    }
    func setNoEntry(_ ids:Set<String>, platform:Catalog) {
        let original = backup
        message = nil
        var changedIDs = Set<String>()
        for id in ids {
            guard var record = backup.records[id], record.needsMatching(platform) else { continue }
            record.setNoEntry(platform); record.modifiedAt = Date(); backup.records[id] = record; changedIDs.insert(id)
        }
        backup.deliveries.removeAll { changedIDs.contains($0.record.id) && $0.target.source == platform && $0.isPending }
        if !persist() { backup = original }
        else if !changedIDs.isEmpty { cloudChange?(.afterAssociationQuietPeriod) }
    }
    func saveAssociations(_ draft:TrackingRecord, metadataRefresh:Bool = false, persistImmediately:Bool = true) {
        let originalBackup = backup
        message = nil
        let identities = Set([draft.id] + (libraryRecord(for:draft.work).map { [$0.id] } ?? []))
        let canonicalID = draft.links["tmdb"]?.remoteID ?? (draft.work.source == .tmdb ? draft.work.remoteID : nil)
        for retired in draft.retiredAssociationIDs ?? [] {
            if let state = backup.associations?[retired], state.links["tmdb"]?.remoteID == canonicalID {
                backup.associations?[retired] = nil
            }
        }
        backup.deliveries.removeAll { job in
            guard identities.contains(job.record.id), job.isPending else { return false }
            if let id = job.associationID {
                let old = job.record.platformLinks?.first { $0.id == id }
                let new = draft.platformLinks?.first { $0.id == id }
                return !draft.isPlatformEnabled(job.target.source) || new == nil || old?.mapping?.revision != new?.mapping?.revision || old?.scope != new?.scope || old?.season != new?.season
            }
            if let unitID = job.unitID {
                guard let unit = draft.viewingUnits?.first(where:{ $0.id == unitID }) else { return true }
                let linked = job.target.source == .trakt ? draft.links["trakt"] : unit.links[job.target.source.rawValue]
                return !draft.isPlatformEnabled(job.target.source) || linked?.id != job.target.id
            }
            return !draft.isPlatformEnabled(job.target.source) || draft.links[job.target.source.rawValue]?.id != job.target.id
        }

        if var saved = libraryRecord(for:draft.work) {
            if !metadataRefresh { saved.modifiedAt = Date() }
            saved.noEntryPlatforms = draft.noEntryPlatforms
            saved.links = draft.links; saved.confirmedProgress = draft.confirmedProgress; saved.mappedProgress = draft.mappedProgress; saved.progressMappings = draft.progressMappings
            saved.platformLinks = draft.platformLinks
            saved.retiredAssociationIDs = draft.retiredAssociationIDs
            if let units = draft.viewingUnits { saved.applyUnitAssociations(units.map(UnitAssociation.init)) }
            let oldID = saved.id
            let primary = LibraryIdentity.primarySource(for:saved.work.kind)
            if let target = saved.links[primary.rawValue],
               let canonical = try? LibraryIdentity.canonical(saved,using:target) { saved = canonical }
            if oldID != saved.id {
                backup.records.removeValue(forKey:oldID)
                for index in backup.deliveries.indices where backup.deliveries[index].record.id == oldID && backup.deliveries[index].isPending {
                    backup.deliveries[index].record.work = saved.work
                }
            }
            backup.records[saved.id] = oldID == saved.id ? saved : LibraryIdentity.mergeImport(saved,existing:backup.records[saved.id])
        } else {
            if backup.associations == nil { backup.associations = [:] }
            let state = AssociationState(links:draft.links,confirmedProgress:draft.confirmedProgress,progressMappings:draft.progressMappings,unitAssociations:draft.viewingUnits?.map(UnitAssociation.init),platformLinks:draft.platformLinks,retiredAssociationIDs:draft.retiredAssociationIDs,noEntryPlatforms:draft.noEntryPlatforms)
            let primary = LibraryIdentity.primarySource(for:draft.work.kind).rawValue
            let primaryID = draft.links[primary]?.id ?? (draft.work.source.rawValue == primary ? draft.id : nil)
            let aliases = backup.associations?.filter { primaryID != nil && $0.value.links[primary]?.id == primaryID }.map(\.key) ?? []
            for id in Set(aliases + [draft.id] + (primaryID.map { [$0] } ?? [])) { backup.associations?[id] = state }
        }
        if persistImmediately {
            if !persist() { backup = originalBackup }
            else {
                cloudChange?(.afterAssociationQuietPeriod)
                Task { await self.synchronizeSaved(draft.work) }
            }
        }
    }
    @discardableResult func saveAssociationsAsync(_ draft:TrackingRecord,metadataRefresh:Bool = false,onStaged:((TrackingRecord) -> Void)? = nil) async -> Bool {
        saveAssociations(draft,metadataRefresh:metadataRefresh,persistImmediately:false)
        onStaged?(record(draft.work))
        guard await persistAsync() else { return false }
        cloudChange?(.afterAssociationQuietPeriod)
        Task { await self.synchronizeSaved(draft.work) }
        return true
    }
    func clearWorkCache(from entry:Work, current:Work? = nil) throws -> TrackingRecord {
        guard !syncing else { throw APIError.message("请等待同步完成后再清除本作缓存") }
        message = nil
        let originalBackup = backup, originalSnapshots = snapshots
        let originalLibrary = library, originalRecent = recent, originalRecommendations = recommendations
        var completed = false
        defer {
            if !completed {
                backup = originalBackup; snapshots = originalSnapshots; library = originalLibrary
                recent = originalRecent; recommendations = originalRecommendations
                homeRecommendations = recommendations["anilist"] ?? []
            }
        }
        let saved = libraryRecord(for:current ?? entry)
        let old = saved ?? record(entry)
        let works = [entry,old.work] + Array(old.links.values) + (old.platformLinks ?? []).map(\.target) + (old.sourceRecords ?? [:]).values.map(\.work)
        let ids = old.relatedWorkIDs.union([entry.id])
        mediaSearch.forget(works)
        for id in ids {
            metadataRevisions[id] = UUID()
            backup.associations?[id] = nil; backup.translations[id] = nil; backup.bookFormats?[id] = nil
            localizations.titles[id] = nil; localizations.overviews[id] = nil
            latestTitleIdentity[id] = nil; pendingTitles[id] = nil; metadataErrors[id] = nil
            for key in Array(pendingOverviews.keys) where key.hasPrefix(id) { pendingOverviews.removeValue(forKey:key)?.cancel() }
        }
        platformChecked = platformChecked.filter { key in !ids.contains(where:key.hasPrefix) }
        attemptedTitles = attemptedTitles.filter { key in !ids.contains(where:key.hasPrefix) }
        bookFormatChecked.subtract(ids)
        backup.deliveries.removeAll { ids.contains($0.record.id) && $0.isPending }
        let seed = Work(source:entry.source,remoteID:entry.remoteID,kind:entry.kind,title:entry.title)
        var fresh = TrackingRecord(work:seed,score:old.score,scoreCleared:old.scoreCleared,progress:old.progress,addedAt:old.addedAt,modifiedAt:old.modifiedAt)
        fresh.status = old.status; fresh.season = old.season; fresh.volumes = old.volumes
        fresh.viewingUnits = []; fresh.platformLinks = []
        fresh.retainedSeasonTracking = (old.viewingUnits ?? []) + (old.retainedSeasonTracking ?? [])
        fresh.retainedSeasonTracking = fresh.retainedSeasonTracking?.map { value in
            var unit = ViewingUnit(id:"season:\(value.season)",title:"",season:value.season,scopeConfirmed:true)
            unit.score = value.score; unit.scoreCleared = value.scoreCleared
            unit.progress = value.progress; unit.watched = value.watched; unit.status = value.status
            unit.trackingMarked = value.trackingMarked; unit.trackingUpdatedAt = value.trackingUpdatedAt
            return unit
        }
        fresh.libraryException = saved == nil ? nil : "正在重新获取作品资料"
        if let saved { backup.records[saved.id] = nil; backup.records[fresh.id] = fresh }
        for source in Array(library.keys) {
            library[source] = library[source]?.map { item in
                guard ids.contains(item.id) else { return item }
                var row = item; row.work = Work(source:item.work.source,remoteID:item.work.remoteID,kind:item.work.kind,title:item.work.title)
                row.links = [:]; row.platformLinks = []; row.viewingUnits = []; row.sourceRecords = nil; row.archivedUnits = nil
                return row
            }
            if snapshots[source] != nil { snapshots[source]?.records = library[source] ?? [] }
        }
        results.removeAll { ids.contains($0.id) }
        recent.removeAll { ids.contains($0.0.id) }
        for source in Array(recommendations.keys) { recommendations[source]?.removeAll { ids.contains($0.id) } }
        homeRecommendations.removeAll { ids.contains($0.id) }
        guard persist() else { throw APIError.message(message ?? "保存失败") }
        completed = true
        persistSnapshots()
        if let message { throw APIError.message(message) }
        return fresh
    }
    func refreshWorkMetadata(_ fresh:Work, replacing old:Work) {
        if var saved = libraryRecord(for:old) {
            let id = saved.id
            saved.work = fresh; saved.setPlatformAssociation(fresh)
            if fresh.source == LibraryIdentity.primarySource(for:fresh.kind) { saved.libraryException = nil }
            backup.records[id] = nil; backup.records[fresh.id] = saved
            persist()
        }
    }
    var localizations: LocalizationArchive {
        get { backup.localizations ?? LocalizationArchive() }
        set { backup.localizations = newValue }
    }
    func titleTranslation(_ work: Work) -> LocalizedText? {
        guard let entry = localizations.titles[work.id], entry.valid(for:MediaLanguage.titleIdentity(work)) else { return nil }
        return entry
    }
    func overviewTranslation(_ work: Work) -> LocalizedText? {
        guard let entry = localizations.overviews[work.id], entry.valid(for:work.overview) else { return nil }
        return entry
    }
    func display(_ work: Work) -> Work {
        var result = work
        if result.format == nil { result.format = backup.bookFormats?[work.id] ?? platformRecord(for:work.id)?.work.format }
        if let entry = titleTranslation(work) { result.title = entry.text }
        if let entry = overviewTranslation(work) { result.overview = entry.text }
        result.title = MediaLanguage.plainText(result.title)
        result.overview = MediaLanguage.plainText(result.overview)
        return result
    }
    /// Platform shelves keep their source identity and personal progress while
    /// presenting the matched movie/series artwork and canonical title edits.
    func platformDisplay(_ work:Work) -> Work {
        var result = display(work)
        guard work.kind != .manga else { return result }
        let associated = record(work)
        guard let target = associated.links[Catalog.tmdb.rawValue] ?? (associated.work.source == .tmdb ? associated.work : nil) else { return result }
        result.title = display(target).title
        result.image = target.image
        return result
    }
    @discardableResult func setTitle(_ title:String, for work:Work, origin:String = "手动", sources:[TitleSource] = [], touchRecord:Bool = true) -> Bool {
        let value = MediaLanguage.plainText(title)
        guard !value.isEmpty, value.count <= 120 else { return false }
        latestTitleIdentity[work.id] = MediaLanguage.titleIdentity(work)
        localizations.titles[work.id] = LocalizedText(original:MediaLanguage.titleIdentity(work),text:value,origin:origin,sources:sources)
        if touchRecord, let saved = libraryRecord(for:work) { backup.records[saved.id]?.modifiedAt = Date() }
        return persist()
    }
    func researchTitle(_ work:Work) async throws {
        let dataRevision = self.dataRevision
        let revision = metadataRevisions[work.id]
        let previous = titleTranslation(work)
        let identity = MediaLanguage.titleIdentity(work)
        latestTitleIdentity[work.id] = identity
        var result = try await mediaSearch.resolve(work,refresh:true)
        try Task.checkCancellation()
        if result.chineseTitle == nil {
            let titles = try await ai.translateTitles([work])
            result.chineseTitle = titles[work.id]
            result.origin = "AI 翻译"; result.sources = []
        }
        guard self.dataRevision == dataRevision else { return }
        guard let title = result.chineseTitle else { throw APIError.message("未取得中文标题，请在标题编辑框填写译名。") }
        guard metadataRevisions[work.id] == revision, previous == titleTranslation(work), latestTitleIdentity[work.id] == identity else { return }
        setTitle(title,for:work,origin:result.origin,sources:result.sources)
    }
    func translateDescription(_ work:Work) async throws {
        let dataRevision = self.dataRevision
        try Task.checkCancellation()
        let clean = MediaLanguage.plainText(work.overview)
        guard overviewTranslation(work) == nil, !clean.isEmpty, !MediaLanguage.isChinese(clean) else { return }
        let key = work.id + work.overview
        let task: SharedAIRequest<String>
        if let pending = pendingOverviews[key] { task = pending }
        else { task = SharedAIRequest { try await self.ai.translateOverview(clean) }; pendingOverviews[key] = task }
        defer { if task.isFinished, pendingOverviews[key] === task { pendingOverviews[key] = nil } }
        let text = try await task.value()
        try Task.checkCancellation()
        guard self.dataRevision == dataRevision else { return }
        localizations.overviews[work.id] = LocalizedText(original:work.overview,text:text,origin:"AI 翻译")
        await persistAsync()
    }
    func resolveLibraryBookFormats() async {
        let dataRevision = self.dataRevision
        guard !resolvingBookFormats else { return }
        resolvingBookFormats = true
        defer { resolvingBookFormats = false }
        let unknown = backup.records.values.map(\.work).filter { $0.kind == .manga && $0.source == .anilist && display($0).format == nil }
        for start in stride(from:0,to:unknown.count,by:50) {
            guard !Task.isCancelled else { return }
            let batch = Array(unknown.dropFirst(start).prefix(50))
            do {
                let result = try await api.request("https://graphql.anilist.co",method:"POST",body:["query":"query($ids:[Int]){Page(perPage:50){media(id_in:$ids,type:MANGA){id format}}}","variables":["ids":batch.compactMap { Int($0.remoteID) }]]) as? [String:Any]
                try Task.checkCancellation()
                guard self.dataRevision == dataRevision else { return }
                let data = result?["data"] as? [String:Any]; let page = data?["Page"] as? [String:Any]
                let rows = page?["media"] as? [[String:Any]] ?? []
                for row in rows {
                    if let id = row["id"] as? Int, let format = row["format"] as? String, let work = batch.first(where:{ $0.remoteID == String(id) }) {
                        if backup.bookFormats == nil { backup.bookFormats = [:] }; backup.bookFormats?[work.id] = format
                    }
                }
                await persistAsync()
            } catch is CancellationError { return }
            catch { message = "书籍类型读取失败：" + error.localizedDescription; return }
        }
        for work in backup.records.values.map(\.work) where work.kind == .manga && [.bangumi,.mal].contains(work.source) {
            guard !Task.isCancelled else { return }
            do { try await resolveExternalBookFormat(work) }
            catch is CancellationError { return }
            catch { message = "书籍类型读取失败：" + error.localizedDescription }
        }
    }
    private func resolveExternalBookFormat(_ work:Work) async throws {
        let dataRevision = self.dataRevision
        guard work.kind == .manga, [.bangumi,.mal].contains(work.source) else { return }
        if let format = Work.normalizedBookFormat(work.format) {
            if backup.bookFormats?[work.id] != format {
                if backup.bookFormats == nil { backup.bookFormats = [:] }
                backup.bookFormats?[work.id] = format; await persistAsync()
            }
            return
        }
        guard display(work).bookMatchType == nil, bookFormatChecked.insert(work.id).inserted else { return }
        let revision = metadataRevisions[work.id]
        do {
            let fresh = try await api.details(work)
            try Task.checkCancellation()
            guard self.dataRevision == dataRevision, metadataRevisions[work.id] == revision else { return }
            if let format = fresh.format {
                if backup.bookFormats == nil { backup.bookFormats = [:] }
                backup.bookFormats?[work.id] = format; await persistAsync()
            }
        } catch { bookFormatChecked.remove(work.id); throw error }
    }
    func localize(_ work: Work) async {
        let dataRevision = self.dataRevision
        let revision = metadataRevisions[work.id]
        do { try await resolveExternalBookFormat(work) }
        catch { metadataErrors[work.id] = "书籍类型读取失败：" + error.localizedDescription }
        guard self.dataRevision == dataRevision else { return }
        if work.source == .anilist, work.kind == .manga {
            if let format = work.format, backup.bookFormats?[work.id] != format {
                if backup.bookFormats == nil { backup.bookFormats = [:] }; backup.bookFormats?[work.id] = format; await persistAsync()
            } else if display(work).format == nil, let id = Int(work.remoteID), bookFormatChecked.insert(work.id).inserted {
                do {
                    let root = try await api.request("https://graphql.anilist.co",method:"POST",body:["query":"query($id:Int!){Media(id:$id,type:MANGA){format}}","variables":["id":id]]) as? [String:Any]
                    guard self.dataRevision == dataRevision, metadataRevisions[work.id] == revision else { return }
                    let data = root?["data"] as? [String:Any]; let media = data?["Media"] as? [String:Any]
                    if let format = media?["format"] as? String {
                        if backup.bookFormats == nil { backup.bookFormats = [:] }; backup.bookFormats?[work.id] = format; await persistAsync()
                    }
                } catch { bookFormatChecked.remove(work.id) }
            }
        }
        let identity = MediaLanguage.titleIdentity(work)
        latestTitleIdentity[work.id] = identity
        let key = work.id + identity
        if work.source == .trakt, titleTranslation(work) == nil, !MediaLanguage.isChinese(work.title),
           !platformChecked.contains(key), localizing.insert(key).inserted {
            defer { localizing.remove(key) }
            metadataErrors[work.id] = nil
            do {
                let translated = try await api.localized(work)
                try Task.checkCancellation()
                guard self.dataRevision == dataRevision, metadataRevisions[work.id] == revision else { return }
                platformChecked.insert(key)
                if titleTranslation(work) == nil, latestTitleIdentity[work.id] == identity, MediaLanguage.isLocalizedTitle(translated.title) {
                    localizations.titles[work.id] = LocalizedText(original:identity,text:translated.title,origin:"Trakt")
                }
                if !work.overview.isEmpty, !MediaLanguage.isChinese(work.overview), MediaLanguage.isChinese(translated.overview) {
                    localizations.overviews[work.id] = LocalizedText(original:work.overview,text:translated.overview,origin:"Trakt")
                }
                await persistAsync()
            } catch is CancellationError { return }
            catch { metadataErrors[work.id] = error.localizedDescription }
        }
        guard self.dataRevision == dataRevision, metadataRevisions[work.id] == revision else { return }
        queueTitle(work)
    }
    func queueTitle(_ work:Work, retry:Bool = false) {
        let key = work.id + MediaLanguage.titleIdentity(work)
        latestTitleIdentity[work.id] = MediaLanguage.titleIdentity(work)
        guard ai.available, !MediaLanguage.isChinese(work.title), titleTranslation(work) == nil else { return }
        if retry { attemptedTitles.remove(key) }
        guard attemptedTitles.insert(key).inserted else { return }
        pendingTitles[work.id] = work
        guard titleBatchTask == nil else { return }
        titleBatchTask = Task { [weak self] in
            try? await Task.sleep(for:.milliseconds(400))
            guard let self else { return }
            await self.drainTitles()
        }
    }
    private func drainTitles() async {
        let dataRevision = self.dataRevision
        defer { titleBatchTask = nil; translatingTitles = false }
        translatingTitles = true
        while !pendingTitles.isEmpty {
            let batch = Array(pendingTitles.values.sorted { $0.id < $1.id }.prefix(MediaLanguage.batchSize))
            for work in batch { pendingTitles[work.id] = nil }
            let needed = batch.filter { titleTranslation($0) == nil }
            guard !needed.isEmpty else { continue }
            do {
                let revisions = metadataRevisions
                let translated = try await ai.translateTitles(needed)
                try Task.checkCancellation()
                guard self.dataRevision == dataRevision else { return }
                for work in needed where metadataRevisions[work.id] == revisions[work.id] && titleTranslation(work) == nil && latestTitleIdentity[work.id] == MediaLanguage.titleIdentity(work) {
                    if let title = translated[work.id] {
                        localizations.titles[work.id] = LocalizedText(original:MediaLanguage.titleIdentity(work),text:title,origin:"AI 翻译")
                        metadataErrors[work.id] = nil
                    } else { metadataErrors[work.id] = "未返回中文译名，可重试或手动修改。" }
                }
                await persistAsync()
            } catch {
                for work in needed { metadataErrors[work.id] = error.localizedDescription }
            }
        }
    }
    func refreshLibrary(source requestedSource: Catalog? = nil) async {
        guard !deletingRemote else { return }
        do {
            _ = try await AIRequestDeadline.map(requestedSource.map { [$0] } ?? [.anilist,.trakt],limit:2) { source -> Bool in
                try await self.refreshLibraryPlatform(source)
                return true
            }
        } catch is CancellationError { }
        catch { message = error.localizedDescription }
    }
    private func refreshLibraryPlatform(_ source:Catalog) async throws {
        let key = source.rawValue
        if let request = libraryRequests[key] {
            defer { if request.isFinished, libraryRequests[key] === request { libraryRequests[key] = nil } }
            _ = try await request.value(); return
        }
        let request = SharedAIRequest<Bool> { [self] in
            loadingLibrarySources.insert(source)
            defer { loadingLibrarySources.remove(source) }
            let revision = dataRevision
            let token:String
            do { token = try api.credentialChecked("\(key).token") }
            catch { libraryErrors[key] = error.localizedDescription; return false }
            if libraryCredentials[key] != token { library[key] = []; libraryCredentials[key] = token; snapshots[key] = nil; await persistSnapshotsAsync() }
            libraryErrors[key] = nil
            guard !token.isEmpty else { return true }
            do {
                let records = try await api.remoteLibrary(source)
                try Task.checkCancellation()
                guard dataRevision == revision, try api.credentialChecked("\(key).token") == token else { return false }
                var seen = Set<String>()
                let uniqueRecords = records.filter { seen.insert($0.id).inserted }
                library[key] = uniqueRecords
                snapshots[key] = LibrarySnapshot(credential:fingerprint(token),records:uniqueRecords)
                await persistSnapshotsAsync()
                return true
            } catch {
                try Task.checkCancellation()
                if dataRevision == revision {
                    do {
                        if try api.credentialChecked("\(key).token") == token { libraryErrors[key] = error.localizedDescription }
                    } catch { libraryErrors[key] = error.localizedDescription }
                }
                return false
            }
        }
        libraryRequests[key] = request
        defer { if request.isFinished, libraryRequests[key] === request { libraryRequests[key] = nil } }
        _ = try await request.value()
    }
    func refreshHistory() async {
        let revision = UUID(); historyGeneration = revision
        var requestToken:String?
        do {
            try Task.checkCancellation()
            let token = try api.credentialChecked("trakt.token")
            requestToken = token
            if token.isEmpty || historyCredential.map({ $0 != token }) == true { recent = [] }
            historyCredential = token
            guard !token.isEmpty else { return }
            let rows = try await api.history()
            try Task.checkCancellation()
            guard revision == historyGeneration, try api.credentialChecked("trakt.token") == token else { return }
            var seen = Set<String>()
            recent = rows.filter { seen.insert($0.0.id).inserted }
            await persistAsync()
        } catch is CancellationError { }
        catch let error as URLError where error.code == .cancelled { }
        catch {
            guard !Task.isCancelled, revision == historyGeneration else { return }
            do {
                if try requestToken == nil || api.credentialChecked("trakt.token") == requestToken {
                    message = error.localizedDescription
                }
            } catch { message = error.localizedDescription }
        }
    }
    /// Commit once, then send only the progress scopes changed during this editing session.
    /// Remote errors stay in the delivery queue and do not turn a saved edit back into a draft.
    func saveProgressChanges(_ draft:TrackingRecord, from previous:TrackingRecord, unitID:String? = nil) async -> Bool {
        var draft = draft
        if let current = libraryRecord(for:draft.work) {
            do { draft = try CloudProjection.mergeEdit(draft,base:previous,current:current) }
            catch { message = error.localizedDescription; return false }
        }
        draft.locallySubmitted = true
        draft.progressSubmitted = draft.progressSubmitted == true || draft.progressState != previous.progressState
        if let current = libraryRecord(for:draft.work) { draft.restoreAssociations(from:current) }
        guard await save(draft,unitID:unitID,preservingPendingDeliveries:true) else { return false }
        await synchronizeSaved(draft.work)
        return true
    }

    /// Only committed local values enter the outbox. Each field has its own acknowledgement.
    func synchronizeSaved(_ work:Work, force:Bool = false) async {
        guard let saved = libraryRecord(for:work), saved.hasSubmittedTracking else { return }
        var planned: [Delivery] = []
        func enqueue(_ target:Work, field:SyncField, association:PlatformAssociation? = nil, unit:ViewingUnit? = nil, payload:() throws -> TrackingRecord) {
            let account = fingerprint(api.credential(target.source.rawValue + ".token") + api.credential("tmdb.session"))
            let identity = [saved.id,target.id,unit?.id ?? "",association?.mapping?.revision.uuidString ?? "",field.rawValue,account].joined(separator:"|")
            do {
                if let association, field != .rating, association.mapping?.matchedEpisodeCount ?? 0 == 0 { throw ProgressSyncSkipped() }
                var value = try payload()
                value.syncFields = [field]
                let signature: String
                switch field {
                case .rating:
                    guard value.score != nil || value.scoreCleared == true else { return }
                    signature = "\(value.score.map(String.init(describing:)) ?? "nil")|\(value.scoreCleared == true)"
                case .status: signature = value.status
                case .progress:
                    signature = "\(value.progress)|\(value.volumes)|\(value.season)|" + (value.episodeHistory ?? []).map { "\($0.season):\($0.number)" }.sorted().joined(separator:",") + "|\(value.syncMappedEpisodes ?? [])|\(value.syncWatchedEpisodes ?? [])"
                }
                let previous = backup.deliveries.last { $0.syncIdentity == identity }
                if !force, previous?.syncSignature == signature, ["已同步","等待同步","同步中"].contains(previous?.state ?? "") { return }
                backup.deliveries.removeAll { $0.syncIdentity == identity && $0.isPending && $0.state != "同步中" }
                planned.append(Delivery(record:value,target:target,unitID:unit?.id,associationID:association?.id,fields:[field],syncIdentity:identity,syncSignature:signature))
            } catch is ProgressSyncSkipped {
                guard field == .progress, !backup.deliveries.contains(where: { $0.syncIdentity == identity && $0.state == "已跳过" }) else { return }
                planned.append(Delivery(record:saved,target:target,associationID:association?.id,fields:[field],attempts:[SyncAttempt(contents:ProgressSyncSkipped().localizedDescription)],syncIdentity:identity,state:"已跳过"))
            }
            catch {
                planned.append(Delivery(record:saved,target:target,unitID:unit?.id,associationID:association?.id,fields:[field],errorDetail:error.localizedDescription,syncIdentity:identity,state:"失败"))
            }
        }
        if saved.work.kind == .tv {
            for association in saved.platformLinks ?? [] where saved.isPlatformEnabled(association.target.source) {
                let units = (saved.viewingUnits ?? []).filter(association.includes)
                if units.contains(where: { $0.isTrackingMarked }) {
                    for field in [SyncField.progress,.status] {
                        enqueue(association.target,field:field,association:association) { try saved.associationPayload(association) }
                    }
                }
                if saved.score != nil || saved.scoreCleared == true || units.contains(where: { $0.score != nil || $0.scoreCleared }) {
                    enqueue(association.target,field:.rating,association:association) { try saved.checkedRatingPayload(for:association) }
                }
            }
            if let target = saved.links["trakt"], saved.isPlatformEnabled(.trakt) {
                for unit in saved.viewingUnits ?? [] where unit.isTrackingMarked {
                    enqueue(target,field:.progress,unit:unit) { try saved.unitPayload(unit,target:target) }
                }
            }
            for platform in [Catalog.tmdb,.trakt] where saved.isPlatformEnabled(platform) {
                if let target = saved.links[platform.rawValue], saved.score != nil || saved.scoreCleared == true { enqueue(target,field:.rating) { saved.ratingPayload() } }
            }
        } else {
            var targets = saved.links; targets[saved.work.source.rawValue] = saved.work
            for target in targets.values where saved.isPlatformEnabled(target.source) {
                if saved.score != nil || saved.scoreCleared == true { enqueue(target,field:.rating) { saved.ratingPayload() } }
                if target.source != .tmdb && saved.progressSubmitted == true {
                    for field in [SyncField.progress,.status] { enqueue(target,field:field) { try saved.payload(for:target) } }
                }
            }
        }
        guard !planned.isEmpty else { return }
        backup.deliveries.append(contentsOf:planned)
        guard await persistAsync() else { return }
        let ready = Set(planned.filter { $0.state == "等待同步" }.map(\.id))
        Task { await self.retry(recordID:saved.id,deliveryIDs:ready) }
    }
    func save(_ draft: TrackingRecord, synchronize: Bool = false, unitID: String? = nil, preservingPendingDeliveries:Bool = false) async -> Bool {
        message = nil
        guard !deletingRemote else { message = "请等待删除完成后再保存"; return false }
        guard draft.progress >= 0, draft.season >= 0, draft.volumes >= 0,
              draft.score.map({ $0.isFinite && $0 > 0 && $0 <= 10 }) ?? true else { message = "评分或进度无效"; return false }
        for unit in draft.viewingUnits ?? [] {
            guard unit.progress >= 0, unit.score.map({ $0.isFinite && $0 > 0 && $0 <= 10 }) ?? true,
                  !unit.scopeConfirmed || unit.validScope,
                  unit.total.map({ unit.progress <= $0 && (unit.watched?.max() ?? 0) <= $0 }) ?? true,
                  unit.watched?.allSatisfy({ $0 > 0 }) ?? true else { message = "请检查“\(unit.title)”的评分和集数"; return false }
        }
        var r: TrackingRecord
        do {
            let primary = LibraryIdentity.primarySource(for:draft.work.kind)
            if draft.work.source == primary { r = draft }
            else if let linked = draft.links[primary.rawValue] { r = try LibraryIdentity.canonical(draft,using:linked) }
            else if draft.libraryException != nil { r = draft }
            else { throw APIError.message("请先选择对应作品，再保存。") }
        } catch { message = error.localizedDescription; return false }
        let alreadyInLibrary = libraryRecord(for:r.work) != nil
        r.prepareUnits()
        if let unitID, r.viewingUnits?.contains(where:{ $0.id == unitID }) != true { message = "未找到所选季，请重新打开作品"; return false }
        var plannedDeliveries: [Delivery] = []
        if synchronize {
            do {
                for platform in [Catalog.tmdb,.trakt] where r.isPlatformEnabled(platform) && (r.score != nil || r.scoreCleared == true) {
                    if let target = r.links[platform.rawValue] ?? (r.work.source == platform ? r.work : nil) {
                        plannedDeliveries.append(Delivery(record:r.ratingPayload(),target:target,fields:[.rating]))
                    }
                }
                if r.work.kind == .tv {
                    for association in r.platformLinks ?? [] where r.isPlatformEnabled(association.target.source) {
                        plannedDeliveries.append(Delivery.planned(record:r,target:association.target,association:association,fields:[.rating]) { try r.checkedRatingPayload(for:association) })
                        plannedDeliveries.append(Delivery.planned(record:r,target:association.target,association:association,fields:[.progress,.status]) { try r.associationPayload(association) })
                    }
                    if let target = r.links["trakt"], r.isPlatformEnabled(.trakt) {
                        for unit in r.viewingUnits ?? [] where unitID == nil || unit.id == unitID {
                            plannedDeliveries.append(Delivery(record:try r.unitPayload(unit,target:target),target:target,unitID:unit.id))
                        }
                    }
                } else {
                    for target in r.links.values where target.source != .tmdb && r.isPlatformEnabled(target.source) {
                        var payload = try r.payload(for:target)
                        if target.source == .trakt { payload.syncFields = [.progress,.status] }
                        plannedDeliveries.append(Delivery(record:payload,target:target,fields:payload.syncFields))
                    }
                }
            } catch { message = error.localizedDescription; return false }
        }
        if let id = unitID, let unit = r.viewingUnits?.first(where:{ $0.id == id }) {
            if r.work.source != .tmdb || r.work.kind != .tv { r.status = unit.status }
            if unit.scopeConfirmed {
                r.season = unit.season
                r.progress = 0
                if let address = unit.episodeAddress(unit.contiguousProgress) { r.season = address.season; r.progress = address.number }
            }
        }
        r.refreshOverallStatus()
        let now = Date()
        r.addedAt = libraryRecord(for:r.work)?.addedAt ?? r.addedAt ?? now
        r.modifiedAt = now
        if draft.id != r.id { backup.records.removeValue(forKey:draft.id) }
        backup.records[r.id] = r
        for row in recent where row.0.id == r.id { backup.handledHistory.insert(row.3) }
        if !preservingPendingDeliveries { backup.deliveries.removeAll { $0.record.id == r.id && $0.isPending && ($0.unitID == unitID || $0.unitID == nil) } }
        backup.deliveries.append(contentsOf:plannedDeliveries)
        guard await persistAsync() else { return false }
        cloudChange?(preservingPendingDeliveries || alreadyInLibrary ? .immediate : .afterAssociationQuietPeriod)
        guard synchronize else { return true }
        await retry(recordID:r.id)
        let failed = backup.deliveries.filter { $0.record.id == r.id && $0.isPending }
        if !failed.isEmpty { message = "已保存在本机；\(failed.count) 项平台同步未完成，请在同步记录中重试。" }
        return message == nil
    }
    var deliveryErrorCount: Int {
        backup.deliveries.filter { $0.isError && backup.acknowledgedDeliveryErrors?[$0.id.uuidString] != $0.state }.count
    }
    func clearDeliveryErrorCount() {
        backup.acknowledgedDeliveryErrors = Dictionary(uniqueKeysWithValues:backup.deliveries.filter(\.isError).map { ($0.id.uuidString,$0.state) })
        persist()
    }
    func retry(recordID: String? = nil, deliveryIDs:Set<UUID>? = nil) async {
        guard !deletingRemote else { return }
        queuedSyncIDs.formUnion(backup.deliveries.filter { $0.isPending && (recordID == nil || $0.record.id == recordID || libraryRecord(for:$0.record.work)?.id == recordID) && (deliveryIDs == nil || deliveryIDs!.contains($0.id)) }.map(\.id))
        guard !syncing else { return }
        syncing = true
        defer { syncing = false; queuedSyncIDs.removeAll() }
        while let id = backup.deliveries.first(where:{ queuedSyncIDs.contains($0.id) })?.id {
            queuedSyncIDs.remove(id)
            guard var job = backup.deliveries.first(where:{ $0.id == id && $0.isPending }) else { continue }
            guard backup.deliveries.contains(where:{ $0.id == job.id }) else { continue }
            guard let current = libraryRecord(for:job.record.work) else {
                backup.deliveries.removeAll { $0.id == job.id }; await persistAsync(); continue
            }
            if let current = libraryRecord(for:job.record.work), !current.isPlatformEnabled(job.target.source) {
                backup.deliveries.removeAll { $0.id == job.id }; await persistAsync(); continue
            }
            if job.fields == [.rating] {
                let association = job.associationID.flatMap { id in current.platformLinks?.first { $0.id == id } }
                if job.associationID != nil && association == nil { backup.deliveries.removeAll { $0.id == job.id }; await persistAsync(); continue }
                if association == nil && (current.links[job.target.source.rawValue]?.id ?? (current.work.source == job.target.source ? current.id : nil)) != job.target.id {
                    backup.deliveries.removeAll { $0.id == job.id }; await persistAsync(); continue
                }
                do { job.record = try current.checkedRatingPayload(for:association) }
                catch {
                    if let index = backup.deliveries.firstIndex(where:{ $0.id == job.id }) { backup.deliveries[index].state = "失败"; backup.deliveries[index].errorDetail = error.localizedDescription }
                    await persistAsync(); continue
                }
            } else if current.work.kind == .tv && ![Catalog.trakt,.tmdb].contains(job.target.source) {
                guard let association = current.platformLinks?.first(where:{ $0.id == (job.associationID ?? job.target.id) }) else {
                    backup.deliveries.removeAll { $0.id == job.id }; await persistAsync(); continue
                }
                if association.mapping?.matchedEpisodeCount ?? 0 == 0 {
                    if let index = backup.deliveries.firstIndex(where:{ $0.id == job.id }) {
                        backup.deliveries[index].state = "已跳过"
                        backup.deliveries[index].errorDetail = nil
                        backup.deliveries[index].attempts = (backup.deliveries[index].attempts ?? []) + [SyncAttempt(contents:ProgressSyncSkipped().localizedDescription)]
                    }
                    await persistAsync(); continue
                }
                do { job.record = try current.associationPayload(association) }
                catch {
                    if let index = backup.deliveries.firstIndex(where:{ $0.id == job.id }) { backup.deliveries[index].state = "失败"; backup.deliveries[index].errorDetail = error.localizedDescription }
                    await persistAsync(); continue
                }
                if let index = backup.deliveries.firstIndex(where:{ $0.id == job.id }) {
                    backup.deliveries[index].record = job.record; backup.deliveries[index].associationID = association.id
                }
            } else if let unitID = job.unitID, let current = libraryRecord(for:job.record.work) {
                guard let unit = current.viewingUnits?.first(where:{ $0.id == unitID }),
                      (job.target.source == .trakt ? current.links["trakt"]?.id : unit.links[job.target.source.rawValue]?.id) == job.target.id else {
                    backup.deliveries.removeAll { $0.id == job.id }; await persistAsync(); continue
                }
                if job.target.source != .trakt, (current.viewingUnits ?? []).filter({ $0.links[job.target.source.rawValue]?.id == job.target.id }).count > 1 {
                    if let index = backup.deliveries.firstIndex(where:{ $0.id == job.id }) { backup.deliveries[index].state = "同一平台条目关联了多个篇章，请先校正对应季和集数" }; await persistAsync(); continue
                }
                let latest: TrackingRecord
                do { latest = try current.unitPayload(unit,target:job.target) }
                catch {
                    if let index = backup.deliveries.firstIndex(where:{ $0.id == job.id }) { backup.deliveries[index].state = "失败"; backup.deliveries[index].errorDetail = error.localizedDescription }; await persistAsync(); continue
                }
                job.record = latest
                if let index = backup.deliveries.firstIndex(where:{ $0.id == job.id }) { backup.deliveries[index].record = latest }
            } else if job.unitID == nil {
                guard (current.links[job.target.source.rawValue]?.id ?? (current.work.source == job.target.source ? current.work.id : nil)) == job.target.id else {
                    backup.deliveries.removeAll { $0.id == job.id }; await persistAsync(); continue
                }
                do { job.record = try current.payload(for:job.target) }
                catch {
                    if let index = backup.deliveries.firstIndex(where:{ $0.id == job.id }) { backup.deliveries[index].state = "失败"; backup.deliveries[index].errorDetail = error.localizedDescription }
                    await persistAsync(); continue
                }
                if let index = backup.deliveries.firstIndex(where:{ $0.id == job.id }) { backup.deliveries[index].record = job.record }
            }
            job.record.syncFields = job.fields ?? job.record.syncFields
            var attempt = SyncAttempt(contents:job.contents)
            if let index = backup.deliveries.firstIndex(where:{ $0.id == job.id }) {
                backup.deliveries[index].record = job.record
                backup.deliveries[index].state = "同步中"
                backup.deliveries[index].attempts = (backup.deliveries[index].attempts ?? []) + [attempt]
            }
            guard await persistAsync() else { return }
            // A save/association edit can replace this job while the durable commit is awaited.
            guard backup.deliveries.contains(where:{ $0.id == job.id }) else { continue }
            let state:String
            do { try await api.save(job.record,to:job.target) { step in
                attempt.steps.append(step)
                if let index = self.backup.deliveries.firstIndex(where:{ $0.id == job.id }),
                   let attemptIndex = self.backup.deliveries[index].attempts?.firstIndex(where:{ $0.id == attempt.id }) {
                    self.backup.deliveries[index].attempts?[attemptIndex] = attempt
                    self.persistLater()
                }
            }; state = "已同步" }
            catch { attempt.error = DiagnosticLog.redacted(error.localizedDescription); state = "失败" }
            if let index = backup.deliveries.firstIndex(where:{ $0.id == job.id }) {
                backup.deliveries[index].record = job.record
                backup.deliveries[index].state = state
                backup.deliveries[index].errorDetail = attempt.error
                if let attemptIndex = backup.deliveries[index].attempts?.firstIndex(where:{ $0.id == attempt.id }) { backup.deliveries[index].attempts?[attemptIndex] = attempt }
                backup.acknowledgedDeliveryErrors?.removeValue(forKey:job.id.uuidString)
            }
            await persistAsync()
        }
    }
}

struct TMDBFilters: Equatable {
    var year = 0
    var genre = 0
    var language = ""
    var minimumScore = 0
    var minimumVotes = 0
    var maximumRuntime = 0
    var status = ""
    var sort = "popularity.desc"
    var key: String { "\(year)|\(genre)|\(language)|\(minimumScore)|\(minimumVotes)|\(maximumRuntime)|\(status)|\(sort)" }
    func parameters(kind:WorkKind) -> [URLQueryItem] {
        var values = [URLQueryItem(name:"sort_by",value:sort)]
        if year > 0 { values.append(URLQueryItem(name:kind == .movie ? "primary_release_year" : "first_air_date_year",value:String(year))) }
        if genre > 0 { values.append(URLQueryItem(name:"with_genres",value:String(genre))) }
        if !language.isEmpty { values.append(URLQueryItem(name:"with_original_language",value:language)) }
        if minimumScore > 0 { values.append(URLQueryItem(name:"vote_average.gte",value:String(minimumScore))) }
        if minimumVotes > 0 { values.append(URLQueryItem(name:"vote_count.gte",value:String(minimumVotes))) }
        if maximumRuntime > 0 && kind == .movie { values.append(URLQueryItem(name:"with_runtime.lte",value:String(maximumRuntime))) }
        if !status.isEmpty && kind == .tv { values.append(URLQueryItem(name:"with_status",value:status)) }
        return values
    }
}


struct ProviderFilters: Equatable {
    var sort = ""
    var year = 0
    var season = ""
    var genre = ""
    var minimumScore = 0
    var animationOnly = false
    var key:String { "\(sort)|\(year)|\(season)|\(genre)|\(minimumScore)|\(animationOnly)" }
}

extension TrackingStore {
    func cachePlatformRating(_ fresh:Work, for primary:Work) async {
        if var saved = libraryRecord(for:primary), saved.platformRatingEntries().contains(where:{ $0.id == fresh.id }) {
            saved.applyPlatformRating(fresh)
            backup.records[saved.id] = saved
            await persistAsync()
        } else if var association = backup.associations?[primary.id] {
            // Browsing a linked work must not admit it to the library.
            for key in Array(association.links.keys) where association.links[key]?.id == fresh.id {
                association.links[key]?.rating = fresh.publicRating
                association.links[key]?.url = fresh.catalogURL?.absoluteString ?? ""
            }
            for index in association.platformLinks?.indices ?? 0..<0 where association.platformLinks?[index].id == fresh.id {
                association.platformLinks?[index].target.rating = fresh.publicRating
                association.platformLinks?[index].target.url = fresh.catalogURL?.absoluteString ?? ""
            }
            backup.associations?[primary.id] = association
            await persistAsync()
        }
    }
}

/// SQLite and credential work use the persistence queue or a background sync task.
struct CloudStorage: @unchecked Sendable {
    let db:LibraryDatabase
    let cloudPreferences:UserDefaults
    let cloudReadCredentials:([String]) throws -> [String:String]
    let cloudWriteCredentials:([String:String]) throws -> Void

    func settingsFields(complete:Bool = false) throws -> [String:Data] {
        var settings:[String:Data] = [:]
        for key in CloudProjection.preferenceKeys {
            if let value = cloudPreferences.object(forKey:key) { settings[key] = try CloudProjection.encode(value) }
        }
        let previousSettings = try db.cloudBaseline(namespace:"settings")
        for service in Set(Credentials.names.map { String($0.split(separator:".")[0]) }).sorted() {
            let names = Credentials.names.filter { $0.hasPrefix(service+".") }
            let values = try cloudReadCredentials(names)
            let key = "credential/" + service
            if values.values.contains(where:{ !$0.isEmpty }) || previousSettings[key] != nil || complete { settings[key] = try CloudEncoding.data(values) }
        }
        return settings
    }
    func migrateDevicePreferences() throws {
        try db.transaction {
            guard try db.state("cloud.localPreferences.v1") == nil else { return }
            for collection in ["cloud-registers","cloud-field-baseline"] {
                for key in try db.keys(collection) where CloudProjection.isDevicePreference(key) {
                    try db.delete(collection:collection,key:key)
                }
            }
            try db.migrateCloudBaseline(namespace:"settings")
            for key in try db.keys("cloud-field-baseline") where CloudProjection.isDevicePreference(key) {
                try db.delete(collection:"cloud-field-baseline",key:key)
            }
            for operation in try db.pendingCloudOperations() where CloudProjection.isDevicePreference(operation.field) {
                try db.delete(collection:"cloud-outbox",key:operation.id)
            }
            try db.setState("cloud.localPreferences.v1","1")
        }
    }
    func captureMetadata(_ backup:Backup) throws {
        try cloudApplySettings()
        try migrateDevicePreferences()
        let settings = try settingsFields()
        try db.captureCloudFields(settings,namespace:"settings")
        let device = try db.cloudDeviceID()
        try db.captureCloudFields(try backup.deliveries.reduce(into:[String:Data]()) { result,delivery in result[delivery.id.uuidString] = try CloudEncoding.data(delivery) },namespace:"deliveryHistory/"+device)
        if let config = cloudPreferences.data(forKey:"cloud.configuration") {
            var connection = ["configuration":config]
            for (name,value) in try cloudReadCredentials(["cloud.access","cloud.secret"]) { connection[name] = try CloudEncoding.data(value) }
            try db.captureCloudFields(connection,namespace:"connections/"+device)
        }
    }
    func cloudBindDestination(_ destination:String,equivalent:Bool = false) throws {
        try db.transaction {
            let previous = try db.state("cloud.destination")
            guard previous != destination else { return }
            try db.setState("cloud.destination",destination)
            guard previous != nil, !equivalent else { return }
            for key in try db.keys("cloud-registers") {
                if let register = try db.read(CloudRegister.self,collection:"cloud-registers",key:key) {
                    for operation in register.operations.values { try db.put(operation,collection:"cloud-outbox",key:operation.id) }
                }
            }
        }
    }
    func cloudAcknowledge(_ ids:[String],key:String) throws {
        try db.transaction {
            try db.acknowledgeCloudOperations(ids)
            try db.setState("cloud.received/"+key,"1")
        }
    }
    func cloudHasBatch(_ key:String) throws -> Bool {
        if try db.state("cloud.received/"+key) != nil { return true }
        return try db.read(CloudBatch.self,collection:"cloud-inbox",key:key) != nil
    }
    func cloudReceive(_ batch:CloudBatch,key:String) throws {
        try batch.validateVersion()
        try db.put(batch,collection:"cloud-inbox",key:key)
    }
    func cloudReceiveMigration(_ bundle:CloudMigrationBundle,key:String) throws {
        try bundle.validate()
        try db.transaction {
            for (index,batch) in bundle.batches.enumerated() {
                try cloudReceive(batch,key:index == 0 ? key : key + "/migration-\(index)")
            }
        }
    }
    func cloudReceiveCheckpoint(_ checkpoint:CloudCheckpoint,key:String) throws {
        try checkpoint.validate()
        try db.transaction {
            try cloudReceiveMigration(checkpoint.snapshot,key:key)
            try db.put(checkpoint,collection:"cloud-checkpoint-pending",key:key)
        }
    }
    func prepareEncryptedJoin(libraryID:String) throws {
        guard let id = UUID(uuidString:libraryID) else { throw CloudJournalError.invalidOperation }
        try db.transaction {
            if let existing = try db.state("cloud.encryptedLibrary"), existing != id.uuidString.lowercased() { throw CloudJournalError.invalidOperation }
            guard try db.read([CloudOperation].self,collection:"cloud-join-pending") == nil else { throw CloudJournalError.invalidOperation }
            var frontier:[CloudOperation] = []
            for field in try db.keys("cloud-registers") {
                if let register = try db.read(CloudRegister.self,collection:"cloud-registers",key:field) { frontier.append(contentsOf:register.frontier) }
            }
            try db.put(frontier,collection:"cloud-join-pending")
            try db.setState("cloud.encryptedLibrary",id.uuidString.lowercased())
        }
    }

    /// Capture the complete current epoch, including all conflict branches and
    /// deletion snapshots, without altering the source journal or outbox.
    func migrationBatches() throws -> [CloudBatch] {
        try db.transaction {
            let epoch = try db.cloudEpoch()
            let fields = try db.keys("cloud-registers").filter { !$0.hasPrefix("drafts/") }
            try db.validateCloudAncestry(fields:Set(fields))
            var operations:[CloudOperation] = []
            for field in fields.sorted() {
                guard let register = try db.read(CloudRegister.self,collection:"cloud-registers",key:field) else { throw CloudJournalError.invalidOperation }
                operations.append(contentsOf:register.operations.values.sorted { $0.id < $1.id })
            }
            guard operations.allSatisfy({ $0.epoch == epoch }) else { throw CloudJournalError.invalidOperation }
            var batches:[CloudBatch] = []
            if let epoch {
                guard let reset = try db.read(CloudBatch.self,collection:"cloud-reset"), reset.reset == epoch else { throw CloudJournalError.missingAncestors }
                try reset.validateVersion()
                batches.append(reset)
            }
            let batch = CloudBatch(version:epoch == nil ? 1 : 2,operations:operations)
            try batch.validateVersion()
            batches.append(batch)
            return batches
        }
    }
    func makeCheckpoint(libraryID:String) throws -> CloudCheckpoint {
        guard let id = UUID(uuidString:libraryID) else { throw CloudJournalError.invalidOperation }
        return try db.transaction {
            guard try db.pendingCloudOperations().isEmpty, try db.keys("cloud-inbox").isEmpty else { throw CloudJournalError.missingAncestors }
            let prefix = "anishelf/v2/" + id.uuidString.lowercased() + "/commits/"
            let receivedPrefix = "cloud.received/" + prefix
            let covered = try db.query("SELECT key FROM state").compactMap { row -> String? in
                guard let key = row.first, key.hasPrefix(receivedPrefix) else { return nil }
                return String(key.dropFirst("cloud.received/".count))
            }.sorted()
            var batches = try migrationBatches()
            let index = batches.count - 1
            let superseded = Set(batches[index].operations.flatMap(\.parents))
            batches[index].operations = try batches[index].operations.map { operation in
                guard superseded.contains(operation.id), operation.compactedHash == nil else { return operation }
                return try operation.compacted()
            }
            let snapshot = CloudMigrationBundle(batches:batches)
            let result = CloudCheckpoint(version:1,libraryID:id.uuidString.lowercased(),covered:covered,snapshot:snapshot)
            try result.validate()
            return result
        }
    }
    func makeReset(_ backup:Backup) throws -> CloudBatch {
        let queued = try db.keys("cloud-inbox").compactMap {
            try db.read(CloudBatch.self,collection:"cloud-inbox",key:$0)?.reset
        }
        let number = max(try db.cloudEpoch()?.number ?? 0,queued.map(\.number).max() ?? 0)
        guard number < Int64.max else { throw CloudJournalError.invalidOperation }
        let epoch = CloudEpoch(number:number+1,id:UUID().uuidString)
        var values = try CloudProjection.fields(backup).mapKeys { "library/"+$0 }
        values.merge(try settingsFields(complete:true).mapKeys { "settings/"+$0 }) { _,new in new }
        for key in try db.keys("cloud-registers") where key.hasPrefix("deliveryHistory/") || key.hasPrefix("connections/") {
            if values[key] == nil { values[key] = try db.read(CloudRegister.self,collection:"cloud-registers",key:key)?.winner?.value }
        }
        var operations:[CloudOperation] = []
        // A new epoch has its own operation ID namespace.
        let origin = epoch.id
        func append(_ field:String,_ value:Data?,restoration:[String:Data]? = nil) {
            let sequence = Int64(operations.count)+1
            operations.append(CloudOperation(id:origin+":"+String(sequence),device:origin,sequence:sequence,
                field:field,parents:[],timestamp:Date(),value:value,restoration:restoration,epoch:epoch))
        }
        for (key,value) in values.sorted(by:{$0.key < $1.key}) { append(key,value) }
        for item in try db.cloudDeletedItems() where values[item.id] == nil {
            if let winner = try db.read(CloudRegister.self,collection:"cloud-registers",key:item.id)?.winner {
                append(item.id,nil,restoration:winner.restoration)
            }
        }
        return CloudBatch(version:2,operations:operations,reset:epoch,clearsDrafts:true)
    }

    func applyInbox(to backup:Backup,authoredReset:CloudEpoch? = nil,mutation:(@Sendable (LibraryDatabase) throws -> Void)? = nil) throws -> (Backup,String)? {
        try cloudApplySettings()
        let keys = try db.keys("cloud-inbox")
        guard !keys.isEmpty || mutation != nil else { return nil }
        return try db.transaction {
            try mutation?(db)
            let batches = try keys.compactMap { try db.read(CloudBatch.self,collection:"cloud-inbox",key:$0) }
            let previousEpoch = try db.cloudEpoch()
            var joining = try db.read([CloudOperation].self,collection:"cloud-join-pending")
            if joining != nil {
                var latest:[CloudOperation] = []
                for field in try db.keys("cloud-registers") {
                    if let register = try db.read(CloudRegister.self,collection:"cloud-registers",key:field) { latest.append(contentsOf:register.frontier) }
                }
                joining = latest
            }
            let reset = batches.filter { $0.reset != nil }.max { $0.reset! < $1.reset! }
            var epoch = previousEpoch
            var clearsDrafts = false
            if let reset, let next = reset.reset, previousEpoch.map({ $0 < next }) ?? true {
                try db.cloudInstallEpoch(next)
                clearsDrafts = reset.clearsDrafts == true
                if clearsDrafts {
                    for key in try db.keys("drafts") { try db.delete(collection:"drafts",key:key) }
                }
                try db.put(reset,collection:"cloud-reset")
                epoch = next
            }
            var applicable: [CloudOperation] = []
            for batch in batches {
                try batch.validateVersion()
                applicable += try batch.operations.filter { operation in
                    if let candidate = operation.epoch, epoch.map({ $0 < candidate }) ?? true {
                        throw CloudJournalError.missingAncestors
                    }
                    return operation.epoch == epoch && !CloudProjection.isDevicePreference(operation.field) && !operation.field.hasPrefix("drafts/")
                }
            }
            // Write each field history once even when the inbox has many commits for it.
            try db.receiveCloudBatch(CloudBatch(version:epoch == nil ? 1 : 2,operations:applicable))
            var touched = Set(applicable.map(\.field))
            try db.validateCloudAncestry(fields:touched)
            if let joining, epoch != previousEpoch {
                let device = try db.cloudDeviceID()
                for (field,branches) in Dictionary(grouping:joining,by:\.field) where !field.hasPrefix("drafts/") {
                    var register = try db.read(CloudRegister.self,collection:"cloud-registers",key:field) ?? CloudRegister()
                    for branch in branches {
                        if branches.count == 1, register.frontier.count == 1,
                           register.winner?.value == branch.value, register.winner?.restoration == branch.restoration { continue }
                        let sequence = (Int64(try db.state("cloud.sequence") ?? "0") ?? 0) + 1
                        let operation = CloudOperation(id:device + ":" + String(sequence),device:device,sequence:sequence,field:field,parents:[],timestamp:branch.timestamp,value:branch.value,restoration:branch.restoration,epoch:epoch)
                        try register.insert(operation)
                        try db.put(operation,collection:"cloud-outbox",key:operation.id)
                        try db.setState("cloud.sequence",String(sequence))
                    }
                    try db.put(register,collection:"cloud-registers",key:field)
                    touched.insert(field)
                }
            }
            if joining != nil { try db.delete(collection:"cloud-join-pending",key:"value") }
            let libraryChanged = epoch != previousEpoch || mutation != nil || touched.contains { $0.hasPrefix("library/") }
            var merged = backup
            if libraryChanged {
                merged = try CloudProjection.apply(db.cloudValues(namespace:"library"),to:backup)
                try LibraryValidation.validate(backup:merged)
                try db.acceptCloudBaseline(CloudProjection.fields(merged),namespace:"library")
            }
            if epoch != previousEpoch && epoch != authoredReset && joining == nil {
                // Old platform jobs must not deliver values just discarded by the reset.
                merged.deliveries.removeAll { $0.isPending }
            }
            if libraryChanged { try db.saveBackup(merged,previous:backup) }
            if epoch != previousEpoch || touched.contains(where:{ $0.hasPrefix("settings/") }) || mutation != nil {
                let settings = try db.cloudValues(namespace:"settings").filter { !CloudProjection.isDevicePreference("settings/"+$0.key) }
                try db.put(settings,collection:"cloud-settings-pending")
            }
            for key in keys {
                if let checkpoint = try db.read(CloudCheckpoint.self,collection:"cloud-checkpoint-pending",key:key) {
                    try checkpoint.validate()
                    for covered in checkpoint.covered { try db.setState("cloud.received/"+covered,"1") }
                    try db.delete(collection:"cloud-checkpoint-pending",key:key)
                }
                try db.setState("cloud.received/"+key,"1")
                try db.delete(collection:"cloud-inbox",key:key)
            }
            let generation = String((Int64(try db.state("library.generation") ?? "0") ?? 0)+1)
            try db.setState("library.generation",generation)
            return (merged,generation)
        }
    }
    func cloudApplySettings() throws {
        guard let settings = try db.read([String:Data].self,collection:"cloud-settings-pending") else { return }
        for (key,value) in settings {
            if key.hasPrefix("credential/") {
                let service = String(key.dropFirst(11))
                let values = try JSONDecoder().decode([String:String].self,from:value)
                let credentials = values.filter { Credentials.names.contains($0.key) && $0.key.hasPrefix(service+".") }
                try cloudWriteCredentials(credentials)
                #if os(iOS)
                if service == "anilist", let token = values["anilist.token"] {
                    if try TokenVault.readChecked() != (token.isEmpty ? nil : token) {
                        if token.isEmpty { try TokenVault.delete() } else { try TokenVault.write(token) }
                    }
                }
                #endif
            } else if CloudProjection.preferenceKeys.contains(key) {
                cloudPreferences.set(try JSONSerialization.jsonObject(with:value,options:.fragmentsAllowed),forKey:key)
            }
        }
        for key in CloudProjection.preferenceKeys where settings[key] == nil { cloudPreferences.removeObject(forKey:key) }
        try db.transaction {
            try db.acceptCloudBaseline(settings,namespace:"settings")
            try db.delete(collection:"cloud-settings-pending",key:"value")
        }
    }
    func cloudDeliveryHistory() throws -> [Delivery] {
        var values:[UUID:Delivery] = [:]
        for key in try db.keys("cloud-registers") where key.hasPrefix("deliveryHistory/") {
            if let register = try db.read(CloudRegister.self,collection:"cloud-registers",key:key), let data = register.winner?.value {
                let delivery = try JSONDecoder().decode(Delivery.self,from:data); values[delivery.id] = delivery
            }
        }
        return values.values.sorted { $0.date > $1.date }
    }
}

private extension Dictionary where Key == String {
    func mapKeys(_ transform:(String) -> String) -> [String:Value] {
        Dictionary<String,Value>(uniqueKeysWithValues:map { (transform($0.key),$0.value) })
    }
}

extension TrackingStore {
    func cloudStorage() throws -> CloudStorage {
        if let storageError { throw storageError }
        return CloudStorage(db:try persistence.requiredDatabase(),cloudPreferences:cloudPreferences,
                            cloudReadCredentials:cloudReadCredentials,cloudWriteCredentials:cloudWriteCredentials)
    }
    func cloudBackup() async throws -> Backup {
        let snapshot = backup, writer = persistence, destination = file
        return try await writer.perform {
            try writer.commit(snapshot,to:destination)
            return writer.committed
        }
    }
    func cloudMerge(_ storage:CloudStorage,reset:(CloudEpoch,Backup)? = nil,mutation:(@Sendable (LibraryDatabase) throws -> Void)? = nil) async throws {
        let writer = persistence, snapshot = backup, destination = file
        cloudApplying = true
        defer { cloudApplying = false }
        try await writer.perform {
            try writer.commit(snapshot,to:destination)
            try storage.captureMetadata(writer.committed)
            if let (value,generation) = try storage.applyInbox(to:writer.committed,authoredReset:reset?.0,mutation:mutation) {
                writer.committed = value
                writer.expected = Data(generation.utf8)
                writer.cloudEditBase = reset?.1 ?? snapshot
            }
        }
        while true {
            let revision = backupRevision, latest = backup
            let result = try await writer.perform {
                guard writer.cloudEditBase != nil else { return nil as (Backup, [(Work,Int,Int,String)])? }
                try writer.commit(latest,to:destination)
                let merged = writer.committed
                return (merged,merged.history?.map { ($0.work,$0.episode,$0.season,$0.event) } ?? [])
            }
            guard revision == backupRevision else { continue }
            if let (merged,history) = result {
                backup = merged; recent = history
                // No UI save can enqueue ahead of this after the merged snapshot is published.
                writer.queue.async { writer.cloudEditBase = nil }
            }
            break
        }
        try await writer.perform { try storage.cloudApplySettings() }
    }

}
