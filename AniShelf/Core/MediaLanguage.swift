import Foundation

struct TitleSource: Codable, Hashable, Identifiable, Sendable {
    var title: String
    var url: String
    var id: String { url }
}
struct LocalizedText: Codable, Equatable {
    var original: String
    var text: String
    var origin: String
    var sources: [TitleSource] = []
    func valid(for original: String) -> Bool { self.original == original }
}
struct LocalizationArchive: Codable, Equatable {
    var titles: [String:LocalizedText] = [:]
    var overviews: [String:LocalizedText] = [:]
}
enum MediaLanguage {
    private nonisolated(unsafe) static let plainTextCache: NSCache<NSString,NSString> = {
        let cache = NSCache<NSString,NSString>()
        cache.totalCostLimit = 8 * 1_048_576
        return cache
    }()
    static let batchSize = 12
    static let titleLimit = 120
    static func plainText(_ html:String) -> String {
        if let cached = plainTextCache.object(forKey:html as NSString) { return cached as String }
        var text = html
        let entities = ["amp":"&","lt":"<","gt":">","quot":"\"","apos":"'","nbsp":" ","hellip":"…","mdash":"—","ndash":"–","lsquo":"‘","rsquo":"’","ldquo":"“","rdquo":"”","bull":"•","copy":"©","reg":"®","trade":"™","ensp":" ","emsp":" ","thinsp":" "]
        for _ in 0..<2 {
            guard let pattern = try? NSRegularExpression(pattern:"&(#x[0-9a-fA-F]+|#[0-9]+|[a-zA-Z]+);") else { break }
            for match in pattern.matches(in:text,range:NSRange(text.startIndex...,in:text)).reversed() {
                guard let range = Range(match.range,in:text), let tokenRange = Range(match.range(at:1),in:text) else { continue }
                let token = String(text[tokenRange]); var replacement = entities[token]
                if token.hasPrefix("#x"), let value = UInt32(token.dropFirst(2),radix:16), let scalar = UnicodeScalar(value) { replacement = String(scalar) }
                else if token.hasPrefix("#"), let value = UInt32(token.dropFirst()), let scalar = UnicodeScalar(value) { replacement = String(scalar) }
                if let replacement { text.replaceSubrange(range,with:replacement) }
            }
        }
        for tag in ["script","style","iframe","object"] {
            text = text.replacingOccurrences(of:"(?is)<" + tag + "\\b[^>]*>.*?</" + tag + "\\s*>",with:"",options:.regularExpression)
        }
        text = text.replacingOccurrences(of:"(?s)<!--.*?-->",with:"",options:.regularExpression)
        text = text.replacingOccurrences(of:"(?i)<br\\s*/?>|</(?:p|div|li|h[1-6])\\s*>",with:"\n",options:.regularExpression)
        text = text.replacingOccurrences(of:"(?i)<li(?:\\s[^>]*)?>",with:"• ",options:.regularExpression)
        text = text.replacingOccurrences(of:"</?[A-Za-z][^>]*>",with:"",options:.regularExpression)
        text = text.replacingOccurrences(of:"[\\t ]+",with:" ",options:.regularExpression)
        text = text.replacingOccurrences(of:"\\n{3,}",with:"\n\n",options:.regularExpression)
        let cleaned = text.trimmingCharacters(in:.whitespacesAndNewlines)
        plainTextCache.setObject(cleaned as NSString,forKey:html as NSString,cost:(html.utf16.count + cleaned.utf16.count) * 2)
        return cleaned
    }
    static func titleIdentity(_ work: Work) -> String { work.title + "\u{1f}" + work.original }
    static func isChinese(_ text: String) -> Bool {
        // Kana prevents Japanese mixed-script text from being mistaken for Chinese.
        let values = text.unicodeScalars.map(\.value)
        let han = values.contains { (0x3400...0x4DBF).contains($0) || (0x4E00...0x9FFF).contains($0) || (0xF900...0xFAFF).contains($0) || (0x20000...0x323AF).contains($0) }
        let kana = values.contains { (0x3040...0x30FF).contains($0) || (0x31F0...0x31FF).contains($0) || (0xFF66...0xFF9D).contains($0) }
        let hangul = values.contains { (0xAC00...0xD7AF).contains($0) || (0x1100...0x11FF).contains($0) || (0x3130...0x318F).contains($0) }
        return han && !kana && !hangul
    }
    static func isLocalizedTitle(_ text:String) -> Bool {
        if isChinese(text) { return true }
        // Validate a width-normalized copy while preserving the title's original typography.
        let normalized = text.folding(options:.widthInsensitive,locale:Locale(identifier:"en_US_POSIX"))
        let scalars = normalized.unicodeScalars
        guard scalars.contains(where: { (65...90).contains($0.value) }) else { return false }
        return scalars.allSatisfy { scalar in
            (65...90).contains(scalar.value) || (48...57).contains(scalar.value)
                || CharacterSet.whitespaces.contains(scalar) || CharacterSet.punctuationCharacters.contains(scalar)
                || "+×☆★".unicodeScalars.contains(scalar)
        }
    }
    static func terms(_ values: [String], limit: Int = 5) -> [String] {
        var seen = Set<String>()
        return Array(values.compactMap { value -> String? in
            let term = value.trimmingCharacters(in:.whitespacesAndNewlines)
            guard !term.isEmpty, term.count <= titleLimit, seen.insert(term.folding(options:[.caseInsensitive,.widthInsensitive],locale:Locale(identifier:"en_US_POSIX"))).inserted else { return nil }
            return term
        }.prefix(limit))
    }
    static func searchTerms(_ values:[String],limit:Int = 3) -> [String] {
        terms(values.compactMap { raw in
            let text = plainText(raw).split(whereSeparator: { $0.isWhitespace }).joined(separator:" ")
                .trimmingCharacters(in:CharacterSet(charactersIn:"\"“”"))
            guard !text.contains("://"), !text.contains("```"), !text.lowercased().contains("site:"),
                  !text.hasPrefix("{"), !text.hasPrefix("["), text.count <= 120 else { return nil }
            return text
        },limit:limit)
    }
    static func ranked(_ works:[Work], terms:[String], year:String) -> [Work] {
        let names = Set(terms.map { $0.folding(options:[.caseInsensitive,.widthInsensitive],locale:Locale(identifier:"en_US_POSIX")) })
        func score(_ work:Work) -> Int {
            let exact = [work.title,work.original].contains { names.contains($0.folding(options:[.caseInsensitive,.widthInsensitive],locale:Locale(identifier:"en_US_POSIX"))) }
            return (exact ? 10 : 0) + (!year.isEmpty && work.year == year ? 2 : 0)
        }
        return works.enumerated().sorted { left,right in
            let a = score(left.element), b = score(right.element)
            return a == b ? left.offset < right.offset : a > b
        }.map(\.element)
    }
    static func merge(_ existing: [Work], _ new: [Work]) -> [Work] {
        var seen = Set<String>()
        return (existing + new).filter { seen.insert($0.id).inserted }
    }
}
struct NameResolution: Sendable {
    var aliases: [String] = []
    var chineseTitle: String?
    var sources: [TitleSource] = []
    var origin = "联网查证"
}
struct SearchResult {
    var works: [Work] = []
    var terms: [String] = []
    var notices: [String] = []
}

/// Each caller can leave immediately; the underlying request stops when its last subscriber leaves.
@MainActor final class SharedAIRequest<Value:Sendable> {
    private var task: Task<Void,Never>?
    private var result: Result<Value,Error>?
    private var waiters: [UUID:CheckedContinuation<Value,Error>] = [:]
    var isFinished: Bool { result != nil }
    init(operation:@escaping @MainActor @Sendable () async throws -> Value) {
        task = Task {
            do { finish(.success(try await operation())) }
            catch { finish(.failure(error)) }
        }
    }
    private func finish(_ value:Result<Value,Error>) {
        guard result == nil else { return }
        result = value
        let pending = waiters.values; waiters = [:]
        for waiter in pending { waiter.resume(with:value) }
        task = nil
    }
    func cancel() { task?.cancel(); finish(.failure(CancellationError())) }
    private func leave(_ id:UUID) {
        waiters.removeValue(forKey:id)?.resume(throwing:CancellationError())
        if waiters.isEmpty && result == nil { cancel() }
    }
    func value() async throws -> Value {
        let id = UUID()
        return try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                if let result { continuation.resume(with:result) }
                else { waiters[id] = continuation }
            }
        }, onCancel: { Task { @MainActor in self.leave(id) } })
    }
}

enum AIRequestDeadline {
    @MainActor static func map<Input:Sendable,Output:Sendable>(_ items:[Input],limit:Int = 3,operation:@escaping @MainActor @Sendable (Input) async throws -> Output) async throws -> [Output] {
        guard !items.isEmpty else { return [] }
        return try await withThrowingTaskGroup(of:(Int,Output).self) { group in
            var next = 0
            var output: [Int:Output] = [:]
            func enqueue(_ index:Int) {
                group.addTask { try Task.checkCancellation(); return (index,try await operation(items[index])) }
            }
            for index in 0..<min(max(1,limit),items.count) { enqueue(index); next += 1 }
            while let (index,value) = try await group.next() {
                try Task.checkCancellation()
                output[index] = value
                if next < items.count { enqueue(next); next += 1 }
            }
            return items.indices.map { output[$0]! }
        }
    }
    @MainActor static func run<T:Sendable>(seconds:Double,operation:@escaping @MainActor @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of:T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds:UInt64(max(0,seconds) * 1_000_000_000))
                throw APIError.message("AI 任务超过时间预算，已停止；可重试未完成部分")
            }
            defer { group.cancelAll() }
            guard let value = try await group.next() else { throw CancellationError() }
            return value
        }
    }
}

@MainActor final class MediaSearch {
    static let shared = MediaSearch()
    let api: CatalogAPI
    let intelligence: Intelligence
    private var names: [String:NameResolution] = [:]
    private var pending: [String:SharedAIRequest<NameResolution>] = [:]
    init(api: CatalogAPI? = nil, intelligence: Intelligence? = nil) {
        self.api = api ?? .shared; self.intelligence = intelligence ?? .shared
    }
    func resolve(_ query: String, kind: WorkKind, year: String = "", refresh: Bool = false) async throws -> NameResolution {
        try await resolve(Work(source:.anilist,remoteID:"",kind:kind,title:query,year:year),refresh:refresh)
    }
    func resolve(_ work:Work,refresh:Bool = false) async throws -> NameResolution {
        let key = [work.id,work.title,work.original,work.format ?? "",work.year,work.overview,work.url].joined(separator:"\u{1f}")
        if !refresh, let cached = names[key] { return cached }
        let task = pending[key] ?? SharedAIRequest { try await self.intelligence.researchNames(work) }
        pending[key] = task
        defer { if task.isFinished, pending[key] === task { pending[key] = nil } }
        let result = try await task.value()
        try Task.checkCancellation()
        if result.chineseTitle != nil || !result.aliases.isEmpty { names[key] = result }
        return result
    }
    func search(_ source: Catalog, kind: WorkKind, query: String, original: String = "", year: String = "", expand: Bool = true, filters: AniListFilters = AniListFilters(), provider:ProviderFilters = ProviderFilters(),
                seed: [Work]? = nil, update: ((SearchResult) -> Void)? = nil) async throws -> SearchResult {
        try Task.checkCancellation()
        if query.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty {
            return SearchResult(works:try await api.search(source,kind:kind,query:"",filters:filters,provider:provider))
        }
        var result = SearchResult()
        let initial = MediaLanguage.terms([query,original])
        for term in initial {
            try Task.checkCancellation()
            do {
                let rows: [Work]
                if term == query, let seed { rows = seed }
                else { rows = try await api.search(source,kind:kind,query:term,filters:filters,provider:provider) }
                result.works = MediaLanguage.merge(result.works,rows)
            }
            catch is CancellationError { throw CancellationError() }
            catch { result.notices.append("\(source.title)：\(error.localizedDescription)") }
            try Task.checkCancellation()
            result.terms.append(term); update?(result)
        }
        if expand && intelligence.available {
            do {
                let aliases = try await researchedSearchTerms(Work(source:source,remoteID:"",kind:kind,title:query,original:original,year:year),platform:source,excluding:initial)
                try Task.checkCancellation()
                for term in aliases {
                    try Task.checkCancellation()
                    do { result.works = MediaLanguage.merge(result.works,try await api.search(source,kind:kind,query:term,filters:filters,provider:provider)) }
                    catch is CancellationError { throw CancellationError() }
                    catch { result.notices.append("\(term)：\(error.localizedDescription)") }
                    try Task.checkCancellation()
                    result.terms.append(term); update?(result)
                }
            } catch is CancellationError { throw CancellationError() }
            catch { result.notices.append("联网查别名未完成：\(error.localizedDescription)") }
        }
        result.notices = Array(Set(result.notices)).sorted()
        for notice in result.notices { api.diagnostics.record("warning",component:"search",message:notice) }
        return result
    }
}

extension MediaSearch {
    func forget(_ works:[Work]) {
        let ids = Set(works.map(\.id))
        for key in Array(names.keys) where ids.contains(String(key.split(separator:"\u{1f}").first ?? "")) { names[key] = nil }
        for key in Array(pending.keys) where ids.contains(String(key.split(separator:"\u{1f}").first ?? "")) { pending.removeValue(forKey:key)?.cancel() }
    }
    /// Shared expansion for discovery, platform search, association and import.
    /// DeepSeek performs query planning -> web search -> evidence-based alias resolution.
    func researchedSearchTerms(_ work:Work, platform:Catalog, excluding:[String] = [], adaptToPlatform:Bool = false) async throws -> [String] {
        var aliases: [String] = []
        if intelligence.hasDeepSeek {
            let resolution = try await resolve(work)
            aliases = MediaLanguage.searchTerms(resolution.aliases + [resolution.chineseTitle ?? ""],limit:5)
        }
        try Task.checkCancellation()
        let newAliases = aliases.filter { term in !excluding.contains { $0.compare(term,options:[.caseInsensitive,.widthInsensitive]) == .orderedSame } }
        if adaptToPlatform || newAliases.isEmpty {
            let generated = try await intelligence.platformSearchTerms(work,platform:platform,excluding:excluding,aliases:aliases)
            if !generated.isEmpty { return generated }
        }
        return newAliases
    }
    /// Whole-work platforms reuse source identity and verified external IDs before title matching.
    func matchSinglePlatform(_ reference:Work, platform:Catalog, origin:Work, linked:Work? = nil, canonical:Work? = nil, allowNoEntry:Bool = false, update:(String) -> Void = { _ in }) async throws -> Work? {
        try Task.checkCancellation()
        var identity = platform == .trakt ? (canonical ?? reference) : reference
        if identity.kind == .manga, identity.bookMatchType == nil || (identity.source == .bangumi && identity.bookSeries == nil) || (identity.source == .mal && identity.volumeCount == nil && identity.chapterCount == nil) {
            let fresh = try await api.details(identity)
            identity.format = fresh.format; identity.bookSeries = fresh.bookSeries
            identity.volumeCount = fresh.volumeCount; identity.chapterCount = fresh.chapterCount
            if identity.overview.isEmpty { identity.overview = fresh.overview }
            try Task.checkCancellation()
        }
        let tmdbID = identity.source == .tmdb ? Int(identity.remoteID) : identity.tmdbID
        func compatible(_ candidate:Work) -> Bool {
            guard candidate.source == platform, candidate.matchesBookType(of:identity), !candidate.remoteID.isEmpty else { return false }
            if platform == .trakt, let expected = tmdbID, let actual = candidate.tmdbID { return expected == actual }
            return true
        }
        // The entry the user opened is already an identified object on its own platform.
        for source in [identity,origin,reference] where compatible(source) { return source }
        if platform == .trakt, let linked, compatible(linked), let tmdbID, linked.tmdbID == tmdbID { return linked }
        var terms = MediaLanguage.searchTerms([identity.original,identity.title],limit:2)
        var searched: [String] = []
        var candidates: [Work] = []
        var bookEvidence = ""
        var foundCount = 0
        var searchHistory: [[String:String]] = []
        let maximumRounds = SeasonMatcher.maximumRounds
        var finalRequested = false
        var webQueries = Set<String>()
        var attemptedBookDetails = Set<String>()
        func needsBookDetails(_ candidate:Work) -> Bool {
            candidate.bookMatchType == nil || candidate.overview.isEmpty
                || (identity.bookSeries != nil && candidate.bookSeries == nil)
        }
        for pass in 0..<maximumRounds {
            let finalReview = finalRequested || pass == maximumRounds - 1
            do {
                let model = Intelligence.model
                update("\(platform.title) · \(model) · \(finalReview ? "最终复核" : "作品身份") 第 \(pass + 1)/\(maximumRounds) 轮")
                api.diagnostics.record("info",component:"book-match",message:"round=\(pass + 1); model=\(model); final=\(finalReview)")
            }
            try Task.checkCancellation()
            update("平台搜索：" + terms.joined(separator:" / "))
            let results = try await AIRequestDeadline.map(terms) { term -> (rows:[Work],error:String?) in
                do { return (try await self.api.search(platform,kind:identity.kind,query:term),nil) }
                catch is CancellationError { throw CancellationError() }
                catch { try Task.checkCancellation(); return ([],error.localizedDescription) }
            }
            for (term,result) in zip(terms,results) {
                if let error = result.error {
                    searchHistory.append(["query":term,"round":String(pass + 1),"status":"failed","error":error])
                    api.diagnostics.record("warning",component:"platform-search",message:"platform=\(platform.rawValue); query=\(term); round=\(pass + 1); status=failed; " + error)
                } else {
                    searchHistory.append(["query":term,"round":String(pass + 1),"status":"success","rawCount":String(result.rows.count),"compatibleCount":String(result.rows.filter(compatible).count)])
                }
            }
            let groups = results.map(\.rows)
            searched += terms
            foundCount += groups.reduce(0) { $0 + $1.count }
            candidates = groups.reduce(candidates) { MediaLanguage.merge($0,$1.filter(compatible)) }
            if platform == .trakt, let tmdbID {
                let exact = candidates.filter { $0.tmdbID == tmdbID }
                if exact.count == 1 { return exact[0] }
            }
            if identity.kind == .manga && pass > 0 {
                let pending = Array(candidates.filter { !attemptedBookDetails.contains($0.id) && needsBookDetails($0) }.prefix(4))
                attemptedBookDetails.formUnion(pending.map(\.id))
                update("读取书籍详情：\(pending.count) 个候选")
                let details = try await AIRequestDeadline.map(pending) { candidate -> Work in
                    do {
                        return try await AIRequestDeadline.run(seconds:5) { try await self.api.details(candidate) }
                    } catch is CancellationError { throw CancellationError() }
                    catch { try Task.checkCancellation(); return candidate }
                }
                for fresh in details {
                    guard let index = candidates.firstIndex(where: { $0.id == fresh.id }) else { continue }
                    var enriched = fresh
                    if enriched.format == nil { enriched.format = candidates[index].format }
                    if enriched.bookSeries == nil { enriched.bookSeries = candidates[index].bookSeries }
                    candidates[index] = enriched
                }
                candidates = candidates.filter(compatible)
            }
            do {
                update("AI 关联：判断 \(candidates.count) 个候选" + (pass > 0 ? "（结合补充证据）" : ""))
                if let match = try await intelligence.match(identity,candidates:candidates,researchEvidence:bookEvidence,finalReview:finalReview,round:pass + 1,allowNoEntry:allowNoEntry,targetPlatform:platform,searchHistory:searchHistory) { return match }
            }
            guard !finalReview else { break }
            guard intelligence.available else { throw APIError.message("请先配置 DeepSeek 或 OpenAI 匹配模型密钥") }
            do {
                if intelligence.hasDeepSeek {
                    update("AI 搜索：联网查找 \(platform.title) 的作品身份与别名")
                    let title = identity.original.isEmpty ? identity.title : identity.original
                    let query = String(((pass == 0 ? title : terms.first ?? candidates.first?.original ?? title) + " " + identity.typeTitle + " " + platform.title).prefix(128))
                    if webQueries.insert(query).inserted {
                    do {
                        let evidence = try await AIRequestDeadline.run(seconds:7) { try await self.intelligence.matchingSearch(query,quick:true) }
                        bookEvidence += "\n\n" + evidence.map { $0.title + "\n" + ($0.url ?? "") + "\n" + String($0.text.prefix(900)) }.joined(separator:"\n\n")
                    } catch is CancellationError { throw CancellationError() }
                    catch {
                        try Task.checkCancellation()
                        update("联网搜索未完成，继续使用已有候选与作品别名")
                        api.diagnostics.record("warning",component:"book-match",message:"可选搜索已跳过：" + error.localizedDescription)
                    }
                    }
                } else { update("AI 搜索：生成作品别名（联网搜索需 DeepSeek Key）") }
                terms = try await intelligence.platformSearchTerms(identity,platform:platform,excluding:searched,evidence:bookEvidence)
                let unreadBookDetails = identity.kind == .manga && candidates.contains {
                    !attemptedBookDetails.contains($0.id) && needsBookDetails($0)
                }
                finalRequested = terms.isEmpty && !unreadBookDetails
                // A stalled search still receives a final review with accumulated evidence.
            }
        }
        if !searchHistory.isEmpty, !searchHistory.contains(where: { $0["status"] == "success" }) {
            let failures = searchHistory.compactMap { row in row["error"].map { "「" + (row["query"] ?? "") + "」：" + $0 } }
            throw APIError.message("匹配失败：平台搜索请求均失败；" + failures.joined(separator:"；"))
        }
        update(foundCount == 0 ? "平台搜索及 AI 搜索后未返回候选" : candidates.isEmpty ? "搜索结果存在书籍类型或系列／单卷冲突" : "AI 已复核 \(candidates.count) 个候选，仍未确认对应作品")
        if allowNoEntry { throw APIError.message("匹配失败：轮次结束后仍未确认对应作品") }
        return nil
    }

    func matchTMDB(_ work:Work, linked:Work? = nil, forceAI:Bool = false) async throws -> Work? {
        guard work.kind != .manga else { return nil }
        if !forceAI {
            if let linked, linked.source == .tmdb, linked.kind == work.kind, let id = Int(linked.remoteID), id > 0 { return linked }
            if work.source == .tmdb, let id = Int(work.remoteID), id > 0 { return work }
            if let id = work.tmdbID { return try await api.tmdbDetails(id:id,kind:work.kind) }
            let title = work.title.trimmingCharacters(in:.whitespacesAndNewlines)
            guard !title.isEmpty else { throw APIError.message("作品缺少标题，请先重新获取来源资料") }
            let direct = try await api.search(.tmdb,kind:work.kind,query:title)
            if !direct.isEmpty {
                guard intelligence.available else { throw APIError.message("已找到 TMDB 候选，请配置 AI 或手动确认主作品") }
                if let selected = try await intelligence.matchTMDBSeries(work,candidates:direct), let id = Int(selected.remoteID) {
                    return try await api.tmdbDetails(id:id,kind:work.kind)
                }
            }
        }
        guard intelligence.available else { throw APIError.message("标题搜索无结果，请配置 AI 匹配服务或手动选择 TMDB 条目") }
        let queries = try await researchedSearchTerms(work,platform:.tmdb,adaptToPlatform:true)
        let groups = try await AIRequestDeadline.map(queries) { query in
            try await self.api.search(.tmdb,kind:work.kind,query:query)
        }
        let all = groups.reduce([Work]()) { MediaLanguage.merge($0,$1) }
        guard !all.isEmpty else { return nil }
        let selected = try await intelligence.matchTMDBSeries(work,candidates:MediaLanguage.ranked(all,terms:queries,year:work.year))
        try Task.checkCancellation()
        guard let selected, let id = Int(selected.remoteID) else { return nil }
        return try await api.tmdbDetails(id:id,kind:work.kind)
    }
}

/// Permits cover actual in-flight requests across all clients; waiting never blocks a thread.
@MainActor final class RequestPermits {
    static let deepSeek = RequestPermits(limit:30)
    private let limit:Int
    private var active = 0
    private var waiting: [(UUID,CheckedContinuation<Void,Error>)] = []
    init(limit:Int) { self.limit = max(1,limit) }
    func acquire() async throws {
        try Task.checkCancellation()
        if active < limit { active += 1; return }
        let id = UUID()
        try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation:CheckedContinuation<Void,Error>) in
                waiting.append((id,continuation))
            }
        }, onCancel: { Task { @MainActor in
            if let index = self.waiting.firstIndex(where:{ $0.0 == id }) {
                self.waiting.remove(at:index).1.resume(throwing:CancellationError())
            }
        } })
        // Cancellation after handoff still owns a permit, which must be returned.
        if Task.isCancelled { release(); throw CancellationError() }
    }
    func release() {
        if !waiting.isEmpty { waiting.removeFirst().1.resume() }
        else { active -= 1 }
    }
}

/// Platform work overlaps; the single consumer commits completed results one at a time.
/// One provider's failure does not cancel the other providers. Parent cancellation does.
enum ConcurrentPlatformMatching {
    @MainActor static func run<Output:Sendable>(
        _ platforms:[Catalog],
        operation:@escaping @MainActor @Sendable (Catalog) async throws -> Output,
        consume:@MainActor (Catalog,Result<Output,Error>) async throws -> Void
    ) async throws {
        try await withThrowingTaskGroup(of:(Catalog,Result<Output,Error>).self) { group in
            for platform in platforms {
                group.addTask {
                    do { try Task.checkCancellation(); return (platform,.success(try await operation(platform))) }
                    catch { return (platform,.failure(error)) }
                }
            }
            while let (platform,result) = try await group.next() {
                try Task.checkCancellation()
                try await consume(platform,result)
            }
        }
    }
}

enum PlatformMatchingOutcome: Sendable {
    case seasons(SeasonMatchResult)
    case single(Work)
    case noEntry(String)
    case unchanged(String)
}

extension PlatformMatchingOutcome {
    /// Apply a platform delta to the latest record, retaining other platforms and tracking edits.
    func applying(to current:TrackingRecord,platform:Catalog,catalog:MatchCatalog?,replace:Bool,reconsideredIDs:Set<String> = []) throws -> (record:TrackingRecord,count:Int,note:String) {
        var draft = current
        if case .unchanged(let note) = self { return (draft,0,note) }
        if let catalog {
            draft.links["tmdb"] = catalog.work
            for item in catalog.seasons {
                draft.ensureSeason(item.number,title:item.name)
                if let index = draft.viewingUnits?.firstIndex(where:{ $0.season == item.number }) { draft.viewingUnits?[index].lastEpisode = item.count > 0 ? item.count : nil }
            }
        }
        let count:Int
        var note:String
        switch self {
        case .seasons(let result):
            try draft.applyMatching(result,platform:platform,replace:replace,reconsideredIDs:reconsideredIDs)
            count = result.associations.count; note = result.summary(saved:true)
            if replace && !result.canReplaceAssociations { note += "；未确认的原有关联保留" }
            if !result.notes.isEmpty { note += "；" + result.notes.joined(separator:"；") }
        case .single(let candidate):
            if draft.links[platform.rawValue]?.id != candidate.id { _ = draft.setPlatformAssociation(candidate) }
            count = 1; note = "已保存关联 1 项；匹配完成"
        case .noEntry(let reason):
            draft.setNoEntry(platform); count = 0; note = reason + "；已保存并禁用同步"
        case .unchanged(let reason): return (draft,0,reason)
        }
        if count > 0 { draft.noEntryPlatforms?.remove(platform.rawValue) }
        return (draft,count,note)
    }
}

/// Shared by detail matching and the import preview.
enum AutomaticPlatformMatching {
    @MainActor static func match(seed:TrackingRecord,origin:Work,platform:Catalog,catalog:MatchCatalog?,
                         replace:Bool = false,selected:[Work]? = nil,
                         progress:@escaping @MainActor (String) -> Void) async throws -> PlatformMatchingOutcome {
        do {
            if let catalog = catalog, ![Catalog.trakt,.tmdb].contains(platform) {
                let matcher = SeasonMatcher()
                let result = try await matcher.match(catalog:catalog,platform:platform,
                    existing:seed.platformLinks ?? [],replace:replace,selected:selected,requireEpisodes:selected != nil,reconsiderSelected:selected != nil) { note in
                        progress(note)
                    }
                try Task.checkCancellation()
                if result.associations.isEmpty && result.rounds > 0 { throw APIError.message("匹配失败：" + result.summary(saved:false)) }
                return .seasons(result)
            }
            if !replace && seed.links[platform.rawValue] != nil { return .unchanged("已有关联，已保留") }
            var lastNote = "确认作品关联…"
            progress(lastNote)
            let candidate = try await MediaSearch.shared.matchSinglePlatform(seed.work,platform:platform,origin:origin,
                linked:seed.links[platform.rawValue],canonical:seed.links["tmdb"],allowNoEntry:true) { note in
                    lastNote = note; progress(note)
                }
            try Task.checkCancellation()
            guard let candidate else { return .unchanged("已结束：" + lastNote) }
            return .single(candidate)
        } catch let error as NoMatchingEntry {
            try Task.checkCancellation()
            return .noEntry(error.localizedDescription)
        }
    }
}
