import Foundation
import Observation

enum WorkspaceSection: String, CaseIterable, Identifiable {
    case discover, library
    var id: String { rawValue }
    var title: String { self == .discover ? "探索" : "我的片单" }
    var icon: String { self == .discover ? "square.grid.2x2" : "rectangle.stack" }
}

@MainActor @Observable
final class AppStore {
    let auth = Authentication()
    var section: WorkspaceSection = .discover
    var kind: MediaKind = .anime
    var sort: BrowseSort = .trending
    var search = ""
    var statusFilter: ListStatus?
    var selection: Int?
    var showingSettings = false
    var grid = false
    var error: String?
    private(set) var viewer: Viewer?
    private(set) var discoveries: [Media] = []
    private(set) var library: [ListEntry] = []
    private(set) var isLoading = false
    private(set) var isLoadingMore = false
    private(set) var hasNextPage = false
    private(set) var page = 1
    @ObservationIgnored private var revision = UUID()

    var requestKey: String { "\(section.rawValue)|\(kind.rawValue)|\(sort.rawValue)|\(section == .discover ? search : "")|\(viewer?.id ?? 0)" }
    var visibleMedia: [Media] {
        if section == .discover { return discoveries }
        return library.filter { entry in
            (statusFilter == nil || entry.status == statusFilter) &&
            (search.isEmpty || [entry.media.title.display, entry.media.title.subtitle].contains { $0.localizedCaseInsensitiveContains(search) })
        }.map(\.media)
    }
    var selectedMedia: Media? { visibleMedia.first { $0.id == selection } }
    var counts: [ListStatus: Int] { Dictionary(grouping: library, by: \.status).mapValues(\.count) }

    func restore(ifTokenChanged:Bool = false) async {
        let previousToken = auth.token
        let stored:(String?,String)
        do {
            stored = try await Task.detached(priority:.utility) {
                (try TokenVault.readChecked(),try Credentials.readChecked("anilist.token"))
            }.value
        } catch { self.error = error.localizedDescription; return }
        guard auth.token == previousToken else { return }
        let tokenOnDisk = stored.0 ?? (stored.1.isEmpty ? nil : stored.1)
        do {
            if stored.1.isEmpty, let token = stored.0 { try Credentials.write("anilist.token",token) }
            if stored.0 == nil, !stored.1.isEmpty { try TokenVault.write(stored.1) }
        } catch { self.error = error.localizedDescription; return }
        guard !ifTokenChanged || previousToken != tokenOnDisk else { return }
        auth.reloadToken(tokenOnDisk)
        guard let token = auth.token else { viewer = nil; return }
        do {
            let result = try await AniListAPI.shared.viewer(token: token)
            guard auth.token == token else { return }
            viewer = result
        } catch { if auth.token == token { handle(error,token:token) } }
    }
    func login(clientID: String) async {
        do {
            try await auth.login(clientID: clientID.trimmingCharacters(in: .whitespacesAndNewlines))
            await restore()
        } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
            return
        } catch { handle(error) }
    }
    func logout() {
        revision = UUID()
        do { try auth.logout() } catch { self.error = error.localizedDescription; return }
        viewer = nil; library = []; selection = nil
        isLoading = false; isLoadingMore = false
    }
    func load() async {
        let generation = UUID()
        revision = generation
        let currentSection = section
        let requestToken = auth.token
        let currentKind = kind
        let currentSearch = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let currentSort = sort
        // Clear previous query results immediately; cancelled tasks cannot replace new results.
        isLoading = true; error = nil; hasNextPage = false
        if currentSection == .discover { discoveries = [] } else { library = [] }
        defer { if revision == generation { isLoading = false } }
        do {
            if currentSection == .discover {
                try await Task.sleep(for: .milliseconds(currentSearch.isEmpty ? 0 : 350))
                try Task.checkCancellation()
                let result = try await AniListAPI.shared.browse(kind: currentKind, search: currentSearch, sort: currentSort, page: 1)
                try Task.checkCancellation()
                guard revision == generation else { return }
                discoveries = result.media; hasNextPage = result.hasNextPage; page = 1
            } else if let viewer, let token = auth.token {
                let entries = try await AniListAPI.shared.library(userID: viewer.id, kind: currentKind, token: token)
                try Task.checkCancellation()
                guard revision == generation else { return }
                library = entries
            }
            if !visibleMedia.contains(where: { $0.id == selection }) { selection = nil }
        } catch is CancellationError { }
        catch let network as URLError where network.code == .cancelled { }
        catch { if revision == generation { handle(error,token:currentSection == .library ? requestToken : nil) } }
    }
    func loadMore() async {
        guard !isLoading, !isLoadingMore, hasNextPage, section == .discover else { return }
        let generation = revision
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let result = try await AniListAPI.shared.browse(kind: kind, search: search.trimmingCharacters(in: .whitespacesAndNewlines), sort: sort, page: page + 1)
            guard generation == revision else { return }
            var seen = Set(discoveries.map(\.id))
            discoveries += result.media.filter { seen.insert($0.id).inserted }
            hasNextPage = result.hasNextPage; page += 1
        } catch { if generation == revision { handle(error) } }
    }
    func apply(_ value: EntryValue, to media: Media) {
        guard media.type == kind else { return }
        let entry = ListEntry(id: value.id, status: value.status, progress: value.progress, score: value.score, media: media)
        if let index = library.firstIndex(where: { $0.media.id == media.id }) { library[index] = entry }
        else { library.append(entry) }
    }
    func handle(_ failure: Error,token:String? = nil) {
        if case APIError.unauthorized = failure, let token, auth.token == token {
            AccountHealth.shared.invalidate(.anilist,token:token)
            viewer = nil
        }
        error = failure.localizedDescription
    }
}

import AuthenticationServices
