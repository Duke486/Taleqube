import SwiftUI
import UIKit

struct WorkSheet: View {
    let work: Work
    var embedded = false
    var systemDark = false
    var fromRecent = false
    var initialSection = "详情"
    var observesAssociationUpdates = false
    @State private var headerHeight: CGFloat = 112
    @State private var topSafeArea: CGFloat = 0
    @Environment(TrackingStore.self) private var tracker
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorSchemeContrast) private var colorContrast
    @State private var artworkPalette = ArtworkPalette.neutral
    private var theme: ArtworkTheme {
        artworkPalette.theme(systemDark:systemDark,increasedContrast:colorContrast == .increased)
    }
    private var themeSources: [String] {
        var seen = Set<String>()
        return [artwork.images.first?.url ?? "",displayed.backdrop ?? "",displayed.image]
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }
    private var themeKey: String { ([artworkSource.id] + themeSources + [cacheRevision.uuidString]).joined(separator:"|") }
    private func loadTheme() async {
        for source in themeSources {
            guard !Task.isCancelled else { return }
            guard let data = try? await PosterCache.shared.data(for:source,owner:artworkSource.id,retention:source == displayed.image || source == displayed.backdrop ? .preferred : .standard) else { continue }
            let sampled = await Task.detached(priority:.utility) { ArtworkPalette.extract(data) }.value
            guard !Task.isCancelled else { return }
            artworkPalette = sampled
            return
        }
        if !Task.isCancelled { artworkPalette = .neutral }
    }
    @State private var record: TrackingRecord?
    @State private var activeUnitID = ""
    @State private var busy = false
    @State private var operationError: String?
    @State private var original = false
    @State private var scoreText = ""
    @State private var titleText = ""
    @State private var editingTitle = false
    @State private var dirty = false
    @State private var savedRecord: TrackingRecord?
    @State private var closing = false
    @State private var section = "详情"
    @State private var matchingPlatform: Catalog?
    @State private var pendingAssociationRemoval: Work?
    @State private var editingAssociationID: String?
    @State private var editingMapping: PlatformAssociation?
    @State private var matchingRevision = UUID()
    @State private var matchNotes: [String:String] = [:]
    @State private var activeMatchingPlatforms = Set<Catalog>()
    @State private var episodeMatchingID: String?
    @State private var matchingTask: Task<Void,Never>?
    @State private var matchingInProgress = false
    @State private var associationNotice: String?
    @State private var artwork = MediaArtwork()
    @State private var artworkLoading = false
    @State private var artworkError: String?
    @State private var artworkRevision = UUID()
    @State private var episodes: [MediaEpisode] = []
    @State private var episodeMetadata: [String:[MediaEpisode]] = [:]
    @State private var episodesLoading = false
    @State private var episodeError: String?
    @Namespace private var browserTransition
    @State private var selectedEpisode: MediaEpisode?
    @State private var gallerySelection: GalleryImage?
    @AppStorage(UIDevice.current.userInterfaceIdiom == .phone ? "shelf.phoneStillWidth" : "shelf.stillWidth")
    private var stillWidth: Double = UIDevice.current.userInterfaceIdiom == .phone ? 190 : 220
    @GestureState private var stillPinch: CGFloat = 1
    @State private var stillViewport: CGFloat = 0
    private var stillCardWidth: CGFloat {
        let desired = min(440,max(120,stillWidth * stillPinch))
        guard stillViewport > 0 else { return desired }
        if UIDevice.current.userInterfaceIdiom == .phone { return min(desired,stillViewport) }
        let columns = max(1,Int((stillViewport + 12) / (desired + 12)))
        return (stillViewport - CGFloat(columns - 1) * 12) / CGFloat(columns)
    }
    @State private var importing = false
    @State private var closeAfterAdmission = false
    @State private var overallScoreText = ""
    @State private var removingFromLibrary = false
    @State private var bookDetails: BookDetails?
    @State private var bookError: String?
    @State private var bookLoading = false
    @State private var bookRevision = UUID()
    private var bookSource: Work? {
        guard work.kind == .manga else { return nil }
        let current = record ?? initialRecord
        return current.work.source == .anilist ? current.work : current.links["anilist"]
    }
    @State private var clearingCache = false
    @State private var resolvingTMDB = false
    @State private var tmdbTask: Task<Void,Never>?
    @State private var tmdbRevision = UUID()
    @State private var tmdbCandidate: Work?
    @State private var sourceFallbackAllowed = false
    private var detailRequestsReady: Bool {
        record != nil && (work.kind == .manga || artworkSource.source == .tmdb || sourceFallbackAllowed)
    }
    @State private var needsSourceRefresh = false
    @State private var cacheRevision = UUID()
    @State private var hasChosenSeason = false
    @State private var refreshedRatings: Set<String> = []
    @State private var ratingErrors: [String:String] = [:]
    @State private var ratingsLoading = false
    @State private var ratingRevision = UUID()
    private var platformRatingsKey: String {
        (record?.platformRatingEntries().map(\.id).sorted().joined(separator:",") ?? "") + ":\(cacheRevision):\(ratingRevision):\(detailRequestsReady):\(artworkSource.id):\(sourceFallbackAllowed)"
    }
    private var hasUnsavedChanges: Bool { dirty || (record != nil && titleText != displayed.title) }
    private var matchingActive: Bool { matchingInProgress || resolvingTMDB }
    private var initialRecord: TrackingRecord { tracker.record(work) }
    private var displayed: Work { tracker.display(artworkSource) }
    private var artworkSource: Work { tracker.detailSource(record ?? initialRecord) }
    private var infuseEnabled: Bool {
        work.kind != .manga && artworkSource.source == .tmdb && Int(artworkSource.remoteID).map { $0 > 0 } == true
    }
    private func openInfuse(season: Int? = nil, episode: Int? = nil) {
        guard infuseEnabled else { return }
        var path = "infuse://" + (artworkSource.kind == .tv ? "series/" : "movie/") + artworkSource.remoteID
        if artworkSource.kind == .tv, let season { path += "-\(season)"; if let episode { path += "-\(episode)" } }
        guard let url = URL(string:path) else { return }
        UIApplication.shared.open(url,options:[:]) { opened in
            if !opened { operationError = "无法打开 Infuse，请确认已安装 Infuse。" }
        }
    }
    private var units: [ViewingUnit] { (record?.viewingUnits ?? []).sorted { seasonOrder($0.season) < seasonOrder($1.season) } }
    private func seasonOrder(_ number:Int) -> Int { number == 0 ? Int.max : number }
    private var unit: ViewingUnit? { units.first { $0.id == activeUnitID } }
    private var season: Int { unit?.season ?? record?.season ?? 1 }
    private var isTV: Bool { work.kind == .tv }
    private var currentLinks: [String:Work] {
        var links = record?.links ?? [:]
        for link in record?.platformLinks ?? [] { links[link.target.source.rawValue] = link.target }
        return links
    }
    private var platforms: [Catalog] { Catalog.allCases.filter { !(work.kind == .manga && [.tmdb,.trakt].contains($0)) } }
    private var scoreIsValid: Bool { scoreText.isEmpty || Double(scoreText).map { $0.isFinite && $0 > 0 && $0 <= 100 } == true }
    private var overallScoreIsValid: Bool { !isTV || overallScoreText.isEmpty || Double(overallScoreText).map { $0.isFinite && $0 > 0 && $0 <= 100 } == true }
    private var scopeIsValid: Bool { unit?.validScope ?? true }
    private var visibleEpisodes: [MediaEpisode] {
        guard let unit, unit.scopeConfirmed else { return [] }
        return episodes.filter { unit.episodeIndex(season:$0.season,number:$0.number) != nil }
    }
    private var gallery: [GalleryImage] { artwork.images }
    var body: some View {
        Group { if embedded { detail } else { NavigationStack { detail.toolbar(.hidden,for:.navigationBar) } } }
            // Lock only the presenting content, before attaching the modal views.
            .allowsHitTesting(selectedEpisode == nil && gallerySelection == nil)
            .accessibilityHidden(selectedEpisode != nil || gallerySelection != nil)
            .task(id:work.id) { section = initialSection; await prepare() }
            .onChange(of:associationSnapshot(tracker.record(work)) + tracker.record(work).links.map { $0.key + $0.value.id }.sorted().joined()) { _,_ in
                guard observesAssociationUpdates, !busy else { return }
                let latest = tracker.record(work)
                record?.links = latest.links
                record?.platformLinks = latest.platformLinks
                record?.noEntryPlatforms = latest.noEntryPlatforms
                if dirty { updateDirtyState() }
            }
            .onChange(of:displayed.title) { old,new in if titleText == old || titleText.isEmpty { titleText = new } }
            .task(id:"source-fallback:\(work.id)") {
                guard work.kind != .manga, work.source != .tmdb else { return }
                do { try await Task.sleep(for:.seconds(3)) } catch { return }
                guard !Task.isCancelled, artworkSource.source != .tmdb else { return }
                sourceFallbackAllowed = true
            }
            .onChange(of:resolvingTMDB) { _,active in
                if !active, record != nil, artworkSource.source != .tmdb { sourceFallbackAllowed = true }
            }
            .task(id:"localize:\(detailRequestsReady):\(artworkSource.id)") {
                guard detailRequestsReady else { return }
                await localizeDetails()
            }
            .task(id:"\(bookSource?.id ?? ""):\(cacheRevision):\(bookRevision)") { await loadBookDetails() }
            .task(id:themeKey) { await loadTheme() }
            .task(id:platformRatingsKey) { await refreshPlatformRatings() }
            .task(id:"\(detailRequestsReady):\(artworkSource.id):\(artworkRevision)") { await loadArtwork() }
            .task(id:"\(detailRequestsReady):\(artworkSource.id):\(activeUnitID):\(unit?.ranges.map { "\($0.season)-\($0.first)-\($0.last ?? 0)" }.joined(separator:",") ?? ""):\(artwork.seasons.count)") { await loadEpisodes() }
            .sheet(item:$matchingPlatform) { platform in
                MatchPickerView(work:record?.work ?? work,platform:platform,initial:editingAssociationID.flatMap { id in record?.platformLinks?.first(where:{ $0.id == id })?.target } ?? (!isTV || [Catalog.tmdb,.trakt].contains(platform) ? currentLinks[platform.rawValue] : nil),
                    allowsMultiple:isTV && ![Catalog.tmdb,.trakt].contains(platform) && editingAssociationID == nil,
                    existingIDs:Set((record?.platformLinks ?? []).map(\.id)),
                    onConfirmMany:{ selections in
                        let previous = record
                        record?.addPlatformSelections(selections)
                        if persistAssociations() { matchNotes[platform.rawValue] = "已添加 \(selections.count) 个条目"; return true }
                        record = previous; return false
                    }) { selected in
                    if selected.source == .tmdb { selectTMDB(selected); return }
                    let previous = record
                    if record?.setPlatformAssociation(selected,replacing:editingAssociationID) == true {
                        if persistAssociations() { matchNotes[platform.rawValue] = "已关联" } else { record = previous }
                    }
                }
                .navigationTransition(.zoom(sourceID:"match:\(platform.rawValue)",in:browserTransition))
            }
            .sheet(item:$editingMapping) { link in
                MappingEditorView(association:link,tmdb:artworkSource,units:units) { map,scope in
                    let previous = record
                    guard let index = record?.platformLinks?.firstIndex(where:{ $0.id == link.id }) else { return false }
                    record?.platformLinks?[index].mapping = map; record?.platformLinks?[index].scope = scope
                    record?.platformLinks?[index].season = map.seasons.first ?? 1
                    if persistAssociations() { return true }; record = previous; return false
                }
                .navigationTransition(.zoom(sourceID:"mapping:\(link.id)",in:browserTransition))
            }
            .onDisappear { matchingRevision = UUID(); matchingTask?.cancel(); tmdbTask?.cancel(); tmdbRevision = UUID() }
            .sheet(item:$selectedEpisode) { episode in
                EpisodeGallery(episodes:visibleEpisodes,initialID:episode.id,cacheOwner:artworkSource.id,play:infuseEnabled ? { openInfuse(season:$0.season,episode:$0.number) } : nil)
                    .modifier(MediaBrowserTheme(theme:theme))
                    .navigationTransition(.zoom(sourceID:episode.id,in:browserTransition))
            }
            .sheet(item:$gallerySelection) { selected in
                GalleryViewer(images:gallery,initial:selected.id,cacheOwner:artworkSource.id)
                    .modifier(MediaBrowserTheme(theme:theme))
                    .navigationTransition(.zoom(sourceID:selected.id,in:browserTransition))
            }
            .sheet(isPresented:$importing,onDismiss:reloadSavedRecord) {
                LibraryImportView(records:record.map { [$0] } ?? [],showsCompletion:false)
            }
            .sheet(item:$tmdbCandidate) { candidate in
                NavigationStack {
                    VStack(alignment:.leading,spacing:20) {
                        MediaHero(work:candidate,backdrop:candidate.backdrop ?? "")
                        Text(candidate.overview).lineLimit(8)
                        Button("使用此 TMDB 作品") { applyTMDB(candidate); tmdbCandidate = nil }.buttonStyle(DetailPrimaryButtonStyle(theme:theme))
                    }.padding(20).navigationTitle("AI 匹配结果").inlineNavigationTitle()
                        .toolbar { ToolbarItem(placement:.cancellationAction) { Button("取消") { tmdbCandidate = nil } } }
                }.presentationDetents([.large])
            }
            .confirmationDialog("删除此匹配？",isPresented:Binding(get:{ pendingAssociationRemoval != nil },set:{ if !$0 { pendingAssociationRemoval = nil } }),titleVisibility:.visible) {
                if let target = pendingAssociationRemoval {
                    Button("删除匹配",role:.destructive) { removeAssociation(target); pendingAssociationRemoval = nil }
                }
                Button("取消",role:.cancel) { pendingAssociationRemoval = nil }
            } message: {
                Text(pendingAssociationRemoval?.title ?? "")
            }
            .confirmationDialog("是否将此作品移出资料库？",isPresented:$removingFromLibrary,titleVisibility:.visible) {
                Button("本地移除",role:.destructive) { removeFromLibrary(everywhere:false) }
                Button("全平台移除",role:.destructive) { removeFromLibrary(everywhere:true) }
                Button("取消",role:.cancel) { }
            } message: {
                Text("本地移除保留平台记录；全平台移除会清除已关联平台的评分、状态和进度（跳过 Bangumi）。移除本地记录会同时丢弃本作未保存的修改。" + (matchingActive ? "确认移除将停止正在进行的匹配。" : ""))
            }
            .confirmationDialog("清除本作缓存并重新获取？",isPresented:$clearingCache,titleVisibility:.visible) {
                Button("清除并重新获取",role:.destructive) { clearCache() }
                Button("取消",role:.cancel) { }
            } message: { Text("清除元数据、季资料、译文和全部平台绑定，从 \(work.source.title) 重新获取。本机评分和观看记录保留，未保存的修改也会保留。") }
            .background(SheetDismissGuard(blocked:hasUnsavedChanges || matchingActive || busy,onAttempt:requestClose))
            .confirmationDialog(matchingActive ? "AI 匹配尚未完成" : "保存修改？",isPresented:$closing,titleVisibility:.visible) {
                if hasUnsavedChanges {
                    Button(matchingActive ? "停止匹配、保存并关闭" : "保存并关闭") {
                        stopMatchingForClose()
                        if titleText != displayed.title, !saveTitle() { return }
                        if dirty { saveProgress(closeAfter:true) } else { close() }
                    }.disabled(!scoreIsValid || !overallScoreIsValid || !scopeIsValid || titleText.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || titleText.count > 120 || (busy && !matchingActive))
                    Button(matchingActive ? "停止匹配、放弃修改并关闭" : "放弃修改并关闭",role:.destructive) {
                        stopMatchingForClose()
                        close()
                    }
                } else {
                    Button("停止匹配并关闭",role:.destructive) { stopMatchingForClose(); close() }
                }
                Button(matchingActive ? "继续匹配" : "继续编辑",role:.cancel) { }
            } message: {
                Text(matchingActive ? "关闭将停止当前匹配，已保存的平台关联会保留。" : "当前修改尚未保存。")
            }
            // Scope to this browsing space. Read the host scheme above this override,
            // so an artwork-triggered dark theme cannot latch onto itself.
            .environment(\.colorScheme,theme.dark ? .dark : .light)
            .preferredColorScheme(theme.dark ? .dark : .light)
            .foregroundStyle(theme.primary.color,theme.secondary.color)
            .tint(theme.accent.color)
            .accentColor(theme.accent.color)
            .environment(\.browserTheme,theme)
            .presentationBackground(theme.canvas.color)

    }
    private var detail: some View {
        detailContent
            .shelfTopBar {
                detailHeader.onGeometryChange(for:CGFloat.self,of:{ $0.size.height },action:{ headerHeight = $0 })
            }
            .onGeometryChange(for:CGFloat.self,of:{ $0.safeAreaInsets.top },action:{ topSafeArea = $0 })
            .background { ArtworkThemeBackground(theme:theme) }
    }
    private var detailHeader: some View {
        VStack(spacing:0) {
            HStack(spacing:12) {
                Text(displayed.title).font(.headline).lineLimit(1)
                Spacer(minLength:8)
                if busy { ProgressView() }
                if dirty {
                    Button("保存") { saveProgress() }.buttonStyle(DetailPrimaryButtonStyle(theme:theme))
                        .disabled(busy || !scoreIsValid || !overallScoreIsValid || !scopeIsValid)
                        .keyboardShortcut(.return,modifiers:.command)
                }
                Menu {
                    Button("重新同步") {
                        Task { await tracker.synchronizeSaved(record?.work ?? work,force:true) }
                    }.disabled(record?.hasSubmittedTracking != true)
                } label: {
                    Image(systemName:"ellipsis").frame(width:ShelfLayout.minimumHitSize,height:ShelfLayout.minimumHitSize)
                }.accessibilityLabel("作品操作")
                Button {
                    requestClose()
                } label: { Image(systemName:"xmark").frame(width:ShelfLayout.minimumHitSize,height:ShelfLayout.minimumHitSize) }
                    .accessibilityLabel("关闭详情")
                    #if targetEnvironment(macCatalyst)
                    .keyboardShortcut(.cancelAction)
                    #endif
            }.padding(.horizontal,ShelfLayout.pageInset).frame(minHeight:56)
            if let error = operationError {
                Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal:false,vertical:true)
                    .frame(maxWidth:.infinity,alignment:.leading).padding(.horizontal,20).padding(.vertical,8)
            }
            let failed = tracker.backup.deliveries.filter { $0.record.id == record?.id && $0.isError }
            if !failed.isEmpty {
                HStack {
                    Text("已保存，\(Set(failed.map { $0.target.source }).count) 个平台同步失败")
                    Button("重试") { Task { await tracker.retry(recordID:record?.id,deliveryIDs:Set(failed.map(\.id))) } }
                }.font(.caption).padding(.horizontal,20).padding(.bottom,8)
            }
            ShelfTabs(values:["详情","平台关联"],selection:$section,title:{ $0 }).padding(.horizontal,20).padding(.vertical,10)
        }
    }
    private var detailContent: some View {
        Group {
            if record == nil { ProgressView().frame(maxWidth:.infinity,maxHeight:.infinity) }
            else {
                ZStack {
                associations.opacity(section == "平台关联" ? 1 : 0)
                    .allowsHitTesting(section == "平台关联")
                    .accessibilityHidden(section != "平台关联")
                ScrollView {
                    VStack(alignment:.leading,spacing:28) {
                        heroSection
                        ratingSection
                        synopsis
                        if !artwork.images.isEmpty { stills }
                        if isTV && !units.isEmpty { seasonPicker }
                        supplementarySection
                    }.padding(20)
                }.scrollDismissesKeyboard(.interactively)
                    .scrollClipDisabled()
                    .opacity(section == "详情" ? 1 : 0)
                    .allowsHitTesting(section == "详情")
                    .accessibilityHidden(section != "详情")
                }
            }
        }
    }
    // Keep type-erased section boundaries: expanding the combined detail view
    // previously crashed during Swift runtime generic metadata resolution on iPad.
    private var heroSection: AnyView {
        AnyView(
            VStack(alignment:.leading,spacing:16) {
                MediaHero(work:displayed,backdrop:artwork.images.first?.url ?? "",showsRating:false,immersive:true,
                          topBleed:headerHeight + topSafeArea,matchingTMDB:resolvingTMDB,
                          matchWithAI:work.kind == .manga ? nil : { startTMDB(forceAI:true) },
                          matchManually:work.kind == .manga ? nil : { openManualTMDB() },theme:theme,
                          editTitle:{ editingTitle.toggle() },findTitle:{ lookupTitle() },titleBusy:busy,infuseAction:infuseEnabled ? { openInfuse() } : nil)
                    .padding(.horizontal,-20).padding(.top,-20).id(cacheRevision)
                if editingTitle { titleEditor }
                if work.kind != .manga { tmdbIdentity }
                if let bookDetails {
                    let authors = (bookDetails.staff?.edges ?? []).prefix(2).map { "\($0.node.displayName) · \($0.roleTitle)" }.joined(separator:" / ")
                    if !authors.isEmpty { Text(authors).font(.subheadline).foregroundStyle(theme.secondary.color) }
                    if !bookDetails.releaseStatus.isEmpty { Text(bookDetails.releaseStatus).font(.caption).foregroundStyle(theme.secondary.color) }
                }
                if needsSourceRefresh {
                    Button("重新获取来源资料") { startTMDB(refreshSource:true) }.font(.subheadline)
                }
                platformRatingsPanel(season:nil)
                if tracker.isInLibrary(record?.work ?? work) {
                    Button { removingFromLibrary = true } label: {
                        Label("已添加到资料库",systemImage:"checkmark.circle.fill")
                    }.font(.subheadline).disabled(busy)
                } else {
                    Button { saveProgress() } label: {
                        Label("添加到资料库",systemImage:"plus")
                            .frame(maxWidth:.infinity,minHeight:36)
                    }.buttonStyle(DetailPrimaryButtonStyle(theme:theme))
                        .disabled(busy || !scoreIsValid || !overallScoreIsValid || !scopeIsValid)
                }
            }
        )
    }
    private var ratingSection: AnyView {
        AnyView(Group {
            if work.kind == .manga {
                recording.disabled(busy && !matchingInProgress)
            } else {
                VStack(alignment:.leading,spacing:16) {
                    if isTV { overallRating } else { personalRating }
                }
                .padding(16)
                .background(theme.card.color,in:.rect(cornerRadius:20))
                .disabled(busy && !matchingInProgress)
            }
        })
    }
    private var supplementarySection: AnyView {
        AnyView(Group {
            if work.kind == .manga {
                if let bookDetails { BookDetailSections(details:bookDetails,owner:bookSource?.id ?? work.id,work:displayed) }
                if bookLoading { ProgressView("加载书籍资料…") }
                if let bookError {
                    Text(bookError).font(.caption).foregroundStyle(.red)
                    Button("重新加载书籍资料") { bookRevision = UUID() }
                }
            } else if !isTV || unit != nil { recording.disabled(busy && !matchingInProgress) }
            else if !artworkLoading { Button("关联 TMDB 作品以读取季资料") { section = "平台关联" } }
            if isTV { episodeGallery }
            if work.kind != .manga && detailRequestsReady { ScreenCreditsSection(work:artworkSource).id(artworkSource.id) }
            if let error = artworkError { Text(error).font(.caption).foregroundStyle(theme.secondary.color); Button("重新加载资料") { artworkRevision = UUID() } }
            if artworkLoading { ProgressView("加载作品资料…") }
        })
    }
    private var tmdbIdentity: some View {
        VStack(alignment:.leading,spacing:6) {
            if resolvingTMDB {
                Text("正在匹配 TMDB…").foregroundStyle(theme.secondary.color)
            } else if let target = record?.links["tmdb"] {
                Text("TMDB · " + [target.title,target.year].filter { !$0.isEmpty }.joined(separator:" · "))
                    .foregroundStyle(theme.secondary.color).textSelection(.enabled)
            } else {
                Text("尚未关联 TMDB · 可使用横图右下角的 AI 或铅笔按钮匹配")
                    .foregroundStyle(theme.secondary.color)
            }
        }.font(.caption).fixedSize(horizontal:false,vertical:true)
    }
    private func openManualTMDB() {
        tmdbTask?.cancel(); tmdbRevision = UUID(); resolvingTMDB = false
        editingAssociationID = nil; matchingPlatform = .tmdb
    }
    private func platformRatingsPanel(season selected:Int?) -> some View {
        let entries = (record?.platformRatingEntries(season:selected) ?? []).filter { selected != nil || $0.scope == .whole }
        return VStack(alignment:.leading,spacing:8) {
            PlatformRatingLayout(spacing:8) {
                ForEach(entries) { entry in platformRatingLink(entry) }
            }
            if entries.isEmpty {
                Button { section = "平台关联" } label: {
                    Label("关联平台评分",systemImage:"link").font(.caption)
                }
            }
            let failures = entries.filter { ratingErrors[$0.id] != nil }
            if !failures.isEmpty {
                DisclosureGroup("\(failures.count) 个条目评分刷新失败") {
                    ForEach(failures) { entry in
                        Text("\(entry.target.source.title) · \(entry.scopeTitle)：\(ratingErrors[entry.id] ?? "")")
                            .font(.caption).foregroundStyle(theme.secondary.color)
                    }
                    Button("重试刷新") { ratingRevision = UUID() }.disabled(ratingsLoading)
                }.font(.caption)
            }
        }.frame(maxWidth:.infinity,alignment:.leading)
    }
    @ViewBuilder private func platformRatingLink(_ entry:PlatformRatingEntry) -> some View {
        if let url = entry.target.catalogURL {
            Link(destination:url) { platformRatingLabel(entry) }
                .buttonStyle(.plain)
                .accessibilityLabel("\(entry.target.source.title)，\(entry.scopeTitle)，\(entry.target.title)，\(entry.target.publicRating.map { "平台均分 \(($0 * 10).formatted())，满分一百分" } ?? "暂无评分")")
                .accessibilityHint("打开对应平台条目")
        } else { platformRatingLabel(entry) }
    }
    private func platformRatingLabel(_ entry:PlatformRatingEntry) -> some View {
        HStack(spacing:5) {
            Image("Platform-" + entry.target.source.rawValue)
                .resizable().scaledToFit().frame(width:16,height:16).accessibilityHidden(true)
            if isTV && entry.scope == .whole { Text("整部").font(.caption).foregroundStyle(theme.secondary.color) }
            Text(entry.target.publicRating.map { ($0 * 10).formatted(.number.precision(.fractionLength(0...1))) } ?? "—")
                .font(.subheadline.weight(.semibold)).monospacedDigit()
        }
        .lineLimit(1).fixedSize(horizontal:true,vertical:true)
        .padding(.horizontal,9).padding(.vertical,6)
        .background(theme.raised.color,in:Capsule())
        .contentShape(Capsule())
    }

    private func refreshPlatformRatings() async {
        guard detailRequestsReady, let record else { return }
        let revision = cacheRevision
        let entries = record.platformRatingEntries().filter {
            work.kind == .manga || work.source == .tmdb || sourceFallbackAllowed || $0.target.source != work.source
        }
        refreshedRatings.formIntersection(Set(entries.map(\.id)))
        ratingsLoading = true
        defer { if !Task.isCancelled { ratingsLoading = false } }
        for entry in entries where !refreshedRatings.contains(entry.id) {
            do {
                let fresh = try await CatalogAPI.shared.platformRatingDetails(entry.target)
                try Task.checkCancellation()
                guard revision == cacheRevision, self.record?.platformRatingEntries().contains(where:{ $0.id == entry.id }) == true else { continue }
                self.record?.applyPlatformRating(fresh); savedRecord?.applyPlatformRating(fresh)
                await tracker.cachePlatformRating(fresh,for:self.record?.work ?? work)
                refreshedRatings.insert(entry.id); ratingErrors[entry.id] = nil
            } catch is CancellationError { return }
            catch {
                guard !Task.isCancelled, revision == cacheRevision else { return }
                ratingErrors[entry.id] = error.localizedDescription
            }
        }
    }
    private var titleEditor: some View {
        VStack(alignment:.leading,spacing:8) {
            TextField("中文名",text:$titleText,axis:.vertical)
                .lineLimit(1...5).padding(12)
                .foregroundStyle(theme.primary.color)
                .background(theme.raised.color,in:.rect(cornerRadius:12))
                .overlay { RoundedRectangle(cornerRadius:12).strokeBorder(theme.secondary.color.opacity(0.4)) }
                .accessibilityLabel("编辑中文名").onSubmit { saveTitle() }
            titleSave
        }

    }
    private func lookupTitle() {
        Task {
            busy = true; defer { busy = false }
            do { try await tracker.researchTitle(record?.work ?? work); titleText = displayed.title }
            catch { operationError = error.localizedDescription }
        }
    }
    private var titleSave: some View {
        Button("保存名称") { saveTitle(); if titleText == displayed.title { editingTitle = false } }
            .font(.subheadline).buttonStyle(.glass).tint(theme.accent.color)
            .disabled(titleText == displayed.title || titleText.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || titleText.count > 120)
    }
    private var overallRating: some View {
        VStack(alignment:.leading,spacing:8) {
            DetailControlRow {
                VStack(alignment:.leading,spacing:4) {
                    Text("我的整部评分").font(.headline)
                    Text("各季默认继承此评分").font(.caption).foregroundStyle(theme.secondary.color)
                }
            } control: {
                RatingInput(text:Binding(get:{ overallScoreText },set:{ value in
                    overallScoreText = value
                    if overallScoreIsValid { record?.score = PercentRating.storedValue(value); record?.scoreCleared = value.isEmpty }
                    updateDirtyState()
                }),label:"整部评分")
            }
            if !overallScoreIsValid { Text("请输入大于 0、不超过 100 的评分。").font(.caption).foregroundStyle(.red) }
        }
    }
    private var personalRating: some View {
        VStack(alignment:.leading,spacing:8) {
            DetailControlRow {
                Text("我的评分").font(.headline)
            } control: {
                RatingInput(text:Binding(get:{ scoreText },set:{ value in
                    scoreText = value
                    if scoreIsValid { record?.score = PercentRating.storedValue(value); record?.scoreCleared = value.isEmpty }
                    updateDirtyState()
                }),label:"我的评分")
            }
            if !scoreIsValid { Text("请输入大于 0、不超过 100 的评分。").font(.caption).foregroundStyle(.red) }
        }
    }
    private var synopsis: some View {
        VStack(alignment:.leading,spacing:10) {
            HStack {
                Text("简介").font(.headline)
                Spacer()
                if tracker.overviewTranslation(record?.work ?? work) != nil { Button(original ? "译文" : "原文") { original.toggle() }.font(.caption) }
                else if !MediaLanguage.isChinese(displayed.overview), !displayed.overview.isEmpty {
                    Button("翻译") { Task { busy = true; defer { busy = false }; do { try await tracker.translateDescription(record?.work ?? work) } catch { operationError = error.localizedDescription } } }.font(.caption).disabled(busy)
                }
            }
            ExpandableSynopsis(text:original ? MediaLanguage.plainText((record?.work ?? work).overview) : displayed.overview,ink:theme.secondary.color)
        }
    }
    private var seasonPicker: some View {
        VStack(alignment:.leading,spacing:12) {
            HStack {
                Text("季与特别篇").font(.headline)
                Spacer()
                Text("\(units.count) 项").font(.caption).foregroundStyle(theme.secondary.color)
            }
            LazyVGrid(columns:[GridItem(.adaptive(minimum:145),spacing:8)],spacing:8) {
                ForEach(units) { value in
                    let selected = value.id == activeUnitID
                    ZStack(alignment:.topTrailing) {
                        Button { hasChosenSeason = true; selectUnit(value.id) } label: {
                            VStack(alignment:.leading,spacing:7) {
                                HStack(spacing:6) {
                                    Text(value.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                                    Spacer(minLength:0)
                                    Color.clear.frame(width:44,height:32)
                                }
                                Text(value.total.map { "\(value.progress) / \($0) 集" } ?? "已看 \(value.progress) 集")
                                    .font(.caption).monospacedDigit().foregroundStyle(theme.secondary.color)
                                if let total = value.total, total > 0 {
                                    ProgressView(value:Double(min(value.progress,total)),total:Double(total)).tint(theme.accent.color)
                                }
                            }.padding(10).frame(maxWidth:.infinity,alignment:.leading)
                                .foregroundStyle(theme.primary.color)
                                .background(theme.card.color,in:.rect(cornerRadius:10))
                                .overlay { RoundedRectangle(cornerRadius:10).strokeBorder(selected ? theme.accent.color : theme.secondary.color.opacity(0.2),lineWidth:selected ? 1.5 : 0.5) }
                        }.buttonStyle(.plain).disabled(!scoreIsValid)
                        if infuseEnabled {
                            Button { openInfuse(season:value.season) } label: {
                                Text("播放").font(.subheadline.weight(.medium)).frame(width:52,height:44).contentShape(Rectangle())
                            }.buttonStyle(.plain).foregroundStyle(theme.accent.color)
                                .accessibilityLabel("在 Infuse 中打开" + value.title)
                        }
                    }
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
        }
    }
    private var seasonRatingControl: some View {
        VStack(alignment:.leading,spacing:8) {
            RatingInput(text:Binding(get:{ scoreText },set:{ value in
                scoreText = value
                if scoreIsValid { updateUnit { $0.score = PercentRating.storedValue(value); $0.scoreCleared = false } }
                else { updateDirtyState() }
            }),label:"本季评分")
            if !scoreIsValid { Text("请输入大于 0、不超过 100 的评分。").font(.caption).foregroundStyle(.red) }
        }
    }
    private var seasonRatingLabel: some View {
        VStack(alignment:.leading,spacing:2) {
            Text("我的本季评分").font(.subheadline.weight(.medium))
            if unit?.score != nil {
                Button("恢复整部评分") { scoreText = ""; updateUnit { $0.score = nil; $0.scoreCleared = false } }
                    .font(.caption).padding(.vertical,6)
            } else {
                Text("继承整部评分" + (record?.score.map { " · " + ($0 * 10).formatted(.number.precision(.fractionLength(0...1))) } ?? " · 未评分"))
                    .font(.caption).foregroundStyle(theme.secondary.color)
            }
        }
    }
    private var recording: some View {
        VStack(alignment:.leading,spacing:10) {
            if work.kind == .manga { Text("我的阅读").font(.headline); personalRating; Divider() }
            if isTV {
                HStack {
                    Text(unit?.title ?? "本季").font(.headline)
                    Spacer()

                }
                if let overview = artwork.seasons.first(where:{ $0.number == season })?.overview,
                   !overview.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty {
                    ExpandableSynopsis(text:MediaLanguage.plainText(overview),ink:theme.secondary.color)
                }
                platformRatingsPanel(season:season)
                Divider()
                ViewThatFits(in:.horizontal) {
                    HStack(alignment:.center,spacing:16) {
                        seasonRatingLabel
                        seasonRatingControl
                    }
                    VStack(alignment:.leading,spacing:8) {
                        seasonRatingLabel
                        seasonRatingControl
                    }
                }
                Divider()
            }
            HStack(spacing:16) {
                Text("状态")
                Menu {
                    Picker("状态",selection:Binding(get:{ unit?.status ?? record?.status ?? "计划中" },set:{ value in
                        if isTV { updateUnit { $0.setStatus(value) } } else { record?.status = value; updateDirtyState() }
                    })) { ForEach(["计划中","进行中","已完成","已暂停","已放弃","重温中"],id:\.self) { StatusMenuLabel(status:$0).tag($0) } }
                } label: { HStack(spacing:4) { StatusBadge(text:unit?.status ?? record?.status ?? "计划中"); Image(systemName:"chevron.down").font(.caption2) } }
                .tint(StatusAppearance(unit?.status ?? record?.status ?? "计划中").ink(dark:theme.dark))
            }.font(.subheadline)
            if isTV && unit != nil {
                DetailControlRow {
                    HStack(spacing:8) {
                    Text("看到第").font(.subheadline)
                    TextField("0",value:Binding(get:{ unit?.progress ?? 0 },set:{ value in
                        guard value >= 0, value <= (unit?.total ?? 100000) else { operationError = "请输入本季范围内的集数。"; return }
                        updateUnit { $0.markThrough(value) }; operationError = nil
                    }),format:.number.grouping(.never)).keyboardType(.numberPad).multilineTextAlignment(.center)
                        .frame(width:64).padding(.vertical,8).background(theme.raised.color,in:.rect(cornerRadius:8)).accessibilityLabel("本季已看集数")
                    Text("集" + (unit?.total.map { " / 共 \($0) 集" } ?? "")).font(.subheadline).foregroundStyle(theme.secondary.color)
                    }
                } control: {
                    if let total = unit?.total {
                        Button("本季看完") { updateUnit { $0.markThrough(total) } }
                            .font(.subheadline).buttonStyle(.glass).frame(minHeight:44)
                    }
                }
                if let total = unit?.total, total > 0 {
                    ProgressView(value:Double(min(unit?.progress ?? 0,total)),total:Double(total))
                        .tint(theme.accent.color).accessibilityLabel("本季观看进度")
                }
            } else if work.kind == .manga {
                ThemedStepper("已读 \(record?.progress ?? 0) 话",value:Binding(get:{ record?.progress ?? 0 },set:{ record?.progress = $0; updateDirtyState() }),in:0...100000,theme:theme)
                ThemedStepper("已读 \(record?.volumes ?? 0) 卷",value:Binding(get:{ record?.volumes ?? 0 },set:{ record?.volumes = $0; updateDirtyState() }),in:0...10000,theme:theme)
            }
        }.padding(18)
            .background(theme.card.color,in:.rect(cornerRadius:20))
            .overlay { RoundedRectangle(cornerRadius:20).strokeBorder(Color.primary.opacity(0.06),lineWidth:0.5) }
    }
    private var episodeGallery: some View {
        VStack(alignment:.leading,spacing:12) {
            HStack { Text("剧集").font(.headline); Spacer(); if !visibleEpisodes.isEmpty { Text("\(visibleEpisodes.count) 集").font(.caption).foregroundStyle(theme.secondary.color) } }
            if episodesLoading { ProgressView("加载剧集…") }
            if let error = episodeError { Text(error).font(.caption).foregroundStyle(theme.secondary.color) }
            EpisodeStrip(episodes:visibleEpisodes,cacheOwner:artworkSource.id,transitionNamespace:browserTransition,play:infuseEnabled ? { openInfuse(season:$0.season,episode:$0.number) } : nil,select:{ selectedEpisode = $0 }).id(activeUnitID)
            if visibleEpisodes.isEmpty && !episodesLoading {
                if unit?.scopeConfirmed == true { Text("暂无剧集资料").font(.caption).foregroundStyle(theme.secondary.color) }
                else { Button("在平台关联中选择对应季") { section = "平台关联" }.font(.caption) }
            }
        }
    }
    private var stills: some View {
        VStack(alignment:.leading,spacing:12) {
            Text("剧照").font(.headline)
            ScrollView(.horizontal) { LazyHStack(spacing:12) { ForEach(artwork.images) { image in
                Button { gallerySelection = image } label: { CachedArtwork(address:image.url,cacheOwner:artworkSource.id).frame(width:stillCardWidth,height:stillCardWidth * 9 / 16).clipShape(.rect(cornerRadius:12)) }.buttonStyle(.plain)
                    .id(image.id)
                    .matchedTransitionSource(id:image.id,in:browserTransition)
            } }.scrollTargetLayout() }
                .onGeometryChange(for:CGFloat.self,of:{ $0.size.width }) { stillViewport = $0 }
                .simultaneousGesture(MagnifyGesture().updating($stillPinch) { value,state,_ in state = value.magnification }
                    .onEnded { stillWidth = min(440,max(120,stillWidth * $0.magnification)) })
                .scrollIndicators(.hidden)
        }
    }
    private var associations: some View {
        ScrollView {
            LazyVStack(alignment:.leading,spacing:24) {
                VStack(alignment:.leading,spacing:10) {
                    AdaptiveControls {
                        Button("自动匹配所有平台") { matchingTask = Task { await findAssociations() } }.buttonStyle(.glass).disabled(busy)
                        Button("重新匹配") { matchingTask = Task { await findAssociations(replace:true) } }.buttonStyle(.glass).disabled(busy)
                        if busy { Button("取消") { cancelAssociationMatching() } }
                    }
                    if busy { ProgressView("正在匹配…") }
                    if let associationNotice { Text(associationNotice).font(.caption).foregroundStyle(theme.secondary.color) }
                    Text("关联自动保存。AI 按 TMDB 季匹配；重新匹配会刷新资料并整体替换现有关联，保留评分与观看记录。无条目平台禁用同步并跳过整体匹配，可在该平台下匹配。")
                        .font(.caption).foregroundStyle(theme.secondary.color)
                }
                ForEach(platforms) { platform in
                    Section {
                        if record?.hasNoEntry(platform) == true {
                            associationCard {
                                Text("无条目").font(.headline)
                                Text("已禁用同步").font(.subheadline).foregroundStyle(theme.secondary.color)
                            }
                        } else if isTV && ![Catalog.tmdb,.trakt].contains(platform) {
                            ForEach(sortedAssociations(platform)) { link in associationRow(link) }
                        } else if let linked = record?.links[platform.rawValue] {
                            associationCard {
                                HStack(alignment:.top) {
                                    associationHeading(linked)
                                    Spacer(minLength:8)
                                    associationDeleteButton(linked)
                                }
                            }
                        } else {
                            Text("尚未关联").font(.subheadline).foregroundStyle(theme.secondary.color)
                        }
                        if let note = matchNotes[platform.rawValue] {
                            Text(note).font(.caption).foregroundStyle(theme.secondary.color)
                        }
                    } header: {
                        VStack(alignment:.leading,spacing:12) {
                            HStack(spacing:8) {
                                Image("Platform-" + platform.rawValue).resizable().scaledToFit()
                                    .frame(width:20,height:20).accessibilityHidden(true)
                                Text(platform.title).font(.headline)
                            }.accessibilityAddTraits(.isHeader)
                            AdaptiveControls {
                                let hasEntry = record?.links[platform.rawValue] != nil || record?.platformLinks?.contains(where:{ $0.target.source == platform }) == true
                                if !hasEntry || ![Catalog.tmdb,.trakt].contains(platform) {
                                    Button { editingAssociationID = nil; matchingPlatform = platform } label: {
                                        Label("添加条目",systemImage:"plus")
                                    }.tint(.blue).disabled(busy)
                                }
                                if hasEntry {
                                    Button("重新匹配") { matchingTask = Task { await findAssociations(replace:true,only:platform) } }
                                        .tint(.orange).disabled(busy)
                                } else {
                                    Button("匹配") { matchingTask = Task { await findAssociations(only:platform) } }
                                        .tint(.indigo).disabled(busy)
                                    if record?.hasNoEntry(platform) != true {
                                        Button("设为无条目") {
                                            let previous = record
                                            record?.setNoEntry(platform)
                                            if !persistAssociations() { record = previous }
                                        }.tint(.red).disabled(busy)
                                    }
                                }
                            }.font(.subheadline).buttonStyle(.borderless)
                        }.matchedTransitionSource(id:"match:\(platform.rawValue)",in:browserTransition)
                    }
                }

                VStack(alignment:.leading,spacing:8) {
                    Button("清除本作缓存",role:.destructive) { clearingCache = true }
                        .foregroundStyle(.red).tint(.red).buttonStyle(.borderless).frame(minHeight:44)
                    Text("忘记元数据、季资料和全部绑定，从本次进入详情的来源重新获取。")
                        .font(.caption).foregroundStyle(theme.secondary.color)
                }
            }.padding(ShelfLayout.pageInset)
        }
    }
    private func associationCard<Content:View>(@ViewBuilder content:() -> Content) -> some View {
        VStack(alignment:.leading,spacing:12,content:content)
            .frame(maxWidth:.infinity,alignment:.leading)
            .padding(16)
            .background(theme.card.color,in:.rect(cornerRadius:18))
            .overlay { RoundedRectangle(cornerRadius:18).strokeBorder(Color.primary.opacity(0.07),lineWidth:0.5) }
    }
    private func associationHeading(_ target:Work) -> some View {
        VStack(alignment:.leading,spacing:4) {
            Text(tracker.display(target).title).font(.headline).fixedSize(horizontal:false,vertical:true)
            if let url = target.catalogURL {
                Link(destination:url) { Label("查看平台条目",systemImage:"arrow.up.right").font(.subheadline).frame(minHeight:44) }
            }
        }
    }
    private func sortedAssociations(_ platform:Catalog) -> [PlatformAssociation] {
        (record?.platformLinks ?? []).filter { $0.target.source == platform }.enumerated().sorted { a,b in
            let left = a.element.scope == .whole ? -1 : seasonOrder(a.element.season)
            let right = b.element.scope == .whole ? -1 : seasonOrder(b.element.season)
            return left == right ? a.offset < b.offset : left < right
        }.map(\.element)
    }
    private func associationRow(_ link:PlatformAssociation) -> some View {
        associationCard {
            HStack(alignment:.top) {
                associationHeading(link.target)
                Spacer(minLength:8)
                associationDeleteButton(link.target)
            }
            HStack(alignment:.center,spacing:12) {
                Text("对应范围").font(.subheadline)
                Spacer(minLength:8)
                Menu {
                    Button("整部作品") { setManualScope(link,season:nil) }
                    ForEach(units) { value in
                        Button(value.title) { setManualScope(link,season:value.season) }
                    }
                } label: {
                    HStack(spacing:6) {
                        Text(link.mappingLabel(regularSeasons:units.map(\.season))).fixedSize(horizontal:false,vertical:true)
                        Image(systemName:"chevron.up.chevron.down").font(.caption)
                    }.font(.subheadline).frame(minHeight:44)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("对应范围，\(link.title)")
            }
            if let map = link.mapping {
                Text(map.reason).font(.caption).foregroundStyle(theme.secondary.color)
                Text(record?.mappingRatingError(link) ?? ("评分：" + (record?.effectiveRating(for:link).source ?? ""))).font(.caption).foregroundStyle(theme.secondary.color)
                Text(map.matchedEpisodeCount == 0 ? "进度：集匹配 0 集" : map.complete ? "进度：已映射 \(map.matchedEpisodeCount) 集" : "进度：部分匹配 · 已映射 \(map.matchedEpisodeCount) 集")
                    .font(.caption).foregroundStyle(map.matchedEpisodeCount == 0 ? .red : map.complete ? theme.secondary.color : .yellow)
            } else {
                Text("进度：集匹配 0 集").font(.caption).foregroundStyle(.red)
            }
            AdaptiveControls {
                Button("编辑集对应",systemImage:"list.number") { editingMapping = link }
                    .buttonStyle(.bordered).tint(.blue).disabled(busy)
                    .matchedTransitionSource(id:"mapping:\(link.id)",in:browserTransition)
                Button("AI 补全集对应",systemImage:"sparkles") {
                    episodeMatchingID = link.id
                    matchNotes[link.target.source.rawValue] = "准备复核季归属与集对应…"
                    matchingTask = Task { await findAssociations(only:link.target.source,selected:[link.target]) }
                }.buttonStyle(.bordered).tint(.indigo).disabled(busy)
            }
            if episodeMatchingID == link.id, let note = matchNotes[link.target.source.rawValue] {
                HStack(alignment:.top,spacing:8) {
                    if busy { ProgressView().controlSize(.small) }
                    Text(note).font(.caption).foregroundStyle(theme.secondary.color)
                }
            }
        }
    }
    private func associationDeleteButton(_ target:Work) -> some View {
        Button(role:.destructive) { pendingAssociationRemoval = target } label: {
            Image(systemName:"trash").foregroundStyle(.red).frame(width:44,height:44)
        }.buttonStyle(.plain).accessibilityLabel("删除匹配：" + target.title).disabled(busy)
    }
    private func removeAssociation(_ target:Work) {
        let previous = record
        record?.platformLinks?.removeAll { $0.target.id == target.id }
        record?.links[target.source.rawValue] = record?.platformLinks?.first(where:{ $0.target.source == target.source })?.target
        record?.retiredAssociationIDs = (record?.retiredAssociationIDs ?? []).union([target.id])
        if !persistAssociations() { record = previous }
    }
    private func changeAssociation(_ id:String,_ change:(inout PlatformAssociation)->Void) {
        guard let index = record?.platformLinks?.firstIndex(where:{ $0.id == id }) else { return }
        matchingRevision = UUID(); matchingTask?.cancel(); busy = false; matchingInProgress = false
        let previous = record
        change(&record!.platformLinks![index]); if !persistAssociations() { record = previous }
    }
    private func associationSnapshot(_ record:TrackingRecord) -> String {
        (record.platformLinks ?? []).map { "\($0.id)|\($0.scope.rawValue)|\($0.season)|\($0.mapping?.revision.uuidString ?? "legacy")" }.sorted().joined(separator:";")
        + (record.noEntryPlatforms ?? []).sorted().joined(separator:",")
    }
    private func setManualScope(_ link:PlatformAssociation,season:Int?) {
        changeAssociation(link.id) { association in
            association.scope = season == nil ? .whole : .season; association.season = season ?? 1
            association.mapping = ContentMapping(tmdbID:artworkSource.remoteID,confirmed:true,
                seasons:season.map { [$0] } ?? units.filter { $0.season > 0 }.map(\.season),manual:true,
                reason:"人工确认季归属；集对应关系待确认")
        }
    }
    private func findAssociations(replace:Bool = false, only:Catalog? = nil, selected:[Work]? = nil) async {
        do {
            try await AIRequestDeadline.run(seconds:1800) {
                await self.performFindAssociations(replace:replace,only:only,selected:selected)
            }
        } catch is CancellationError { }
        catch { associationNotice = error.localizedDescription }
    }
    private func cancelAssociationMatching() {
        for platform in activeMatchingPlatforms { matchNotes[platform.rawValue] = "已取消；此前平台已保存的关联保留" }
        associationNotice = "已取消；此前平台已保存的关联保留。"
        activeMatchingPlatforms = []
        matchingRevision = UUID(); matchingTask?.cancel(); busy = false; matchingInProgress = false
    }
    private func performFindAssociations(replace:Bool, only:Catalog?, selected:[Work]?) async {
        guard !busy, let initial = record else { return }
        if only == .tmdb {
            let revision = UUID(); matchingRevision = revision
            busy = true; matchingInProgress = true; activeMatchingPlatforms = [.tmdb]
            defer { if matchingRevision == revision { busy = false; matchingInProgress = false; activeMatchingPlatforms = [] } }
            do {
                let candidate = try await MediaSearch.shared.matchSinglePlatform(initial.work,platform:.tmdb,origin:work,allowNoEntry:true) { matchNotes["tmdb"] = $0 }
                try Task.checkCancellation()
                guard matchingRevision == revision else { return }
                guard let candidate else { throw APIError.message("未确认 TMDB 对应作品") }
                let previous = record
                _ = record?.setPlatformAssociation(candidate)
                if await persistAssociationsAsync() { applyTMDB(candidate,automatic:true) } else { record = previous }
            } catch let error as NoMatchingEntry {
                guard !Task.isCancelled, matchingRevision == revision else { return }
                let previous = record; record?.setNoEntry(.tmdb)
                if await persistAssociationsAsync() { matchNotes["tmdb"] = error.localizedDescription } else { record = previous }
            } catch { if matchingRevision == revision { matchNotes["tmdb"] = "匹配失败：" + error.localizedDescription } }
            return
        }
        if selected == nil { episodeMatchingID = nil }
        busy = true; matchingInProgress = true; associationNotice = nil; matchNotes = [:]
        let revision = UUID(); matchingRevision = revision
        var expectedSnapshot = associationSnapshot(initial)
        var expectedLinks = initial.links.mapValues(\.id)
        defer { if matchingRevision == revision { busy = false; matchingInProgress = false; activeMatchingPlatforms = [] } }
        if let only { matchNotes[only.rawValue] = "准备 TMDB 季资料…" }
        var count = 0, savedPlatforms = 0, failedPlatforms = 0
        do {
            let reference = initial.work
            var catalog: MatchCatalog?
            let requestedPlatforms = platforms.filter { $0 != .tmdb && (only == nil || $0 == only) && initial.shouldAttemptMatching($0,explicitRetry:only == $0) }
            guard !requestedPlatforms.isEmpty else { associationNotice = "无待匹配平台；无条目平台已跳过"; return }
            if isTV {
                guard !initial.hasNoEntry(.tmdb) || artworkSource.source == .tmdb else { throw APIError.message("TMDB 已设为无条目，请先在 TMDB 下重新匹配以读取季资料") }
                let tmdb = artworkSource.source == .tmdb ? artworkSource : try await MediaSearch.shared.matchTMDB(reference)
                guard let tmdb else { throw APIError.message("请先确认 TMDB 主作品") }
                catalog = try await CatalogAPI.shared.matchingCatalog(tmdb)
            }
            // Every child receives the same immutable starting point. Only the consumer
            // mutates records, applying one platform's delta to the latest saved state.
            let preparedCatalog = catalog
            var seed = initial
            if let catalog {
                seed.links["tmdb"] = catalog.work
                for item in catalog.seasons {
                    seed.ensureSeason(item.number,title:item.name)
                    if let index = seed.viewingUnits?.firstIndex(where:{ $0.season == item.number }) { seed.viewingUnits?[index].lastEpisode = item.count > 0 ? item.count : nil }
                }
            }
            let matchingSeed = seed
            var expectedStoredSnapshot = associationSnapshot(tracker.record(initial.work))
            var expectedStoredLinks = tracker.record(initial.work).links.mapValues(\.id)
            activeMatchingPlatforms = Set(requestedPlatforms)
            try await ConcurrentPlatformMatching.run(requestedPlatforms,operation:{ platform -> PlatformMatchingOutcome in
                guard matchingRevision == revision else { throw CancellationError() }
                return try await AutomaticPlatformMatching.match(seed:matchingSeed,origin:work,platform:platform,
                    catalog:preparedCatalog,replace:replace,selected:selected) { note in
                        if matchingRevision == revision && activeMatchingPlatforms.contains(platform) { matchNotes[platform.rawValue] = note }
                    }
            },consume:{ platform,outcome in
                try Task.checkCancellation()
                guard matchingRevision == revision else { throw CancellationError() }
                defer { if matchingRevision == revision { activeMatchingPlatforms.remove(platform) } }
                do {
                    let result = try outcome.get()
                    if case .unchanged(let note) = result { matchNotes[platform.rawValue] = note; return }
                    let stored = tracker.record(initial.work)
                    guard var draft = record, associationSnapshot(draft) == expectedSnapshot, draft.links.mapValues(\.id) == expectedLinks,
                          associationSnapshot(stored) == expectedStoredSnapshot, stored.links.mapValues(\.id) == expectedStoredLinks else {
                        throw APIError.message("关联已被修改，本次结果未覆盖新修改")
                    }
                    let applied = try result.applying(to:draft,platform:platform,catalog:preparedCatalog,replace:replace,reconsideredIDs:Set((selected ?? []).map(\.id)))
                    draft = applied.record
                    let matchedCount = applied.count, finalNote = applied.note
                    let previous = record
                    let priorStoredSnapshot = expectedStoredSnapshot, priorStoredLinks = expectedStoredLinks
                    record = draft
                    guard await persistAssociationsAsync(onStaged:{ saved in
                        expectedStoredSnapshot = associationSnapshot(saved); expectedStoredLinks = saved.links.mapValues(\.id)
                    }) else {
                        if matchingRevision == revision, record.map(associationSnapshot) == associationSnapshot(draft) {
                            record = previous
                            expectedStoredSnapshot = priorStoredSnapshot; expectedStoredLinks = priorStoredLinks
                        }
                        throw APIError.message("关联保存失败：" + (operationError ?? "磁盘写入失败"))
                    }
                    guard matchingRevision == revision else { throw CancellationError() }
                    if let saved = record { expectedSnapshot = associationSnapshot(saved); expectedLinks = saved.links.mapValues(\.id) }
                    count += matchedCount; savedPlatforms += 1
                    matchNotes[platform.rawValue] = finalNote
                    DiagnosticLog.shared.record("info",component:"association-save",message:"platform=\(platform.rawValue); saved=true; associations=\(matchedCount)")
                } catch {
                    try Task.checkCancellation()
                    guard matchingRevision == revision else { throw CancellationError() }
                    failedPlatforms += 1
                    matchNotes[platform.rawValue] = "已结束：" + error.localizedDescription
                    DiagnosticLog.shared.record("error",component:"association-save",message:"platform=\(platform.rawValue); saved=false; \(error.localizedDescription)")
                }
            })
            if let catalog, savedPlatforms > 0 {
                artwork.seasons = catalog.seasons.map { MediaSeason(number:$0.number,title:$0.name,episodeCount:$0.count) }
                episodeMetadata = [:]; artworkRevision = UUID()
            }
            associationNotice = "匹配已结束，已保存 \(count) 个关联。" + (failedPlatforms > 0 ? "\(failedPlatforms) 个平台未完成，原因见平台状态。" : "各平台结果见下方。")
        } catch {
            guard matchingRevision == revision else { return }
            let message = Task.isCancelled || error is CancellationError ? "已取消；此前平台已保存的关联保留" : "已结束：" + error.localizedDescription
            for platform in activeMatchingPlatforms { matchNotes[platform.rawValue] = message }
            associationNotice = message
        }
    }
    @discardableResult private func persistAssociations() -> Bool {
        guard let record else { return false }
        tracker.saveAssociations(record)
        if let error = tracker.message { operationError = error; return false }
        if dirty { updateDirtyState() }
        return true
    }
    @discardableResult private func persistAssociationsAsync(onStaged:((TrackingRecord) -> Void)? = nil) async -> Bool {
        guard let record else { return false }
        guard await tracker.saveAssociationsAsync(record,onStaged:onStaged) else { operationError = tracker.message; return false }
        if dirty { updateDirtyState() }
        return true
    }
    private func updateUnit(_ change:(inout ViewingUnit)->Void) {
        guard let index = record?.viewingUnits?.firstIndex(where:{ $0.id == activeUnitID }) else { return }
        change(&record!.viewingUnits![index]); updateDirtyState()
    }
    private func selectUnit(_ id:String) { matchNotes = [:]; associationNotice = nil; activeUnitID = id; scoreText = (isTV ? unit?.score : record?.score).map { ($0 * 10).formatted(.number.locale(Locale(identifier:"en_US_POSIX"))) } ?? ""; if dirty { updateDirtyState() } }
    @discardableResult private func saveTitle() -> Bool {
        guard titleText != displayed.title else { return true }
        let success = tracker.setTitle(titleText,for:record?.work ?? work)
        if !success { operationError = tracker.message }
        return success
    }
    private func requestClose() {
        if hasUnsavedChanges || matchingActive { closing = true }
        else if !busy { close() }
    }
    private func stopMatchingForClose() {
        if matchingInProgress { cancelAssociationMatching() }
        if resolvingTMDB { tmdbTask?.cancel(); tmdbRevision = UUID(); resolvingTMDB = false }
    }
    private func loadBookDetails() async {
        bookDetails = nil; bookError = nil; bookLoading = false
        guard let source = bookSource, let id = Int(source.remoteID) else { return }
        bookLoading = true
        do {
            let details = try await AniListAPI.shared.bookDetails(id:id)
            try Task.checkCancellation()
            guard bookSource?.id == source.id else { return }
            bookDetails = details
            let translated = try await Intelligence.shared.translatedBook(details,work:displayed)
            try Task.checkCancellation()
            guard bookSource?.id == source.id else { return }
            bookDetails = translated; bookLoading = false
        } catch is CancellationError { }
        catch { if !Task.isCancelled { bookError = error.localizedDescription; bookLoading = false } }
    }
    private func removeFromLibrary(everywhere:Bool) {
        guard !busy, let saved = tracker.libraryRecord(for:record?.work ?? work) else { return }
        stopMatchingForClose()
        busy = true; operationError = nil
        Task {
            defer { busy = false }
            do {
                if everywhere { try await tracker.removeEverywhere(saved) }
                else {
                    tracker.message = nil; tracker.deleteRecords([saved.id])
                    if let error = tracker.message { throw APIError.message(error) }
                }
                dirty = false; close()
            } catch { operationError = error.localizedDescription }
        }
    }
    private func close() { if embedded { tracker.selected = nil } else { dismiss() } }
    private func updateDirtyState() {
        guard let record, let savedRecord else { return }
        dirty = record.hasTrackingChanges(from:savedRecord) || !scoreIsValid || !overallScoreIsValid
    }
    private func saveProgress(closeAfter:Bool = false) {
        guard scoreIsValid, overallScoreIsValid, scopeIsValid, let record, !busy else { return }
        busy = true; operationError = nil
        Task {
            defer { busy = false }
            let primary = LibraryIdentity.primarySource(for:record.work.kind)
            if record.work.source != primary && record.links[primary.rawValue] == nil && record.libraryException == nil { closeAfterAdmission = closeAfter; importing = true; return }
            let success = await tracker.saveProgressChanges(record,from:savedRecord ?? record,unitID:isTV && unit != nil ? activeUnitID : nil)
            operationError = tracker.message
            if success {
                self.record = tracker.libraryRecord(for:record.work) ?? record
                savedRecord = self.record
                dirty = false
                if closeAfter { close() }
            }
        }
    }
    private func reloadSavedRecord() {
        defer { closeAfterAdmission = false }
        guard let saved = tracker.libraryRecord(for:work) else { return }
        record = saved; record?.prepareUnits()
        selectUnit(units.contains(where:{ $0.id == activeUnitID }) ? activeUnitID : units.first?.id ?? "")
        overallScoreText = saved.score.map { ($0 * 10).formatted(.number.locale(Locale(identifier:"en_US_POSIX"))) } ?? ""
        saveProgress(closeAfter:closeAfterAdmission)
    }
    private func prepare() async {
        let cached = tracker.record(work)
        if tracker.libraryRecord(for:work) != nil { record = cached }
        else if let target = cached.links["tmdb"], cached.work.kind != .manga {
            record = (try? LibraryIdentity.canonical(cached,using:target)) ?? cached
        } else { record = cached }
        record?.prepareUnits(); titleText = displayed.title
        if let current = record, !current.hasNoEntry(current.work.source), record?.links[current.work.source.rawValue] == nil { record?.links[record!.work.source.rawValue] = record?.work }
        selectUnit(units.first?.id ?? "")
        savedRecord = record
        overallScoreText = record?.score.map { ($0 * 10).formatted(.number.locale(Locale(identifier:"en_US_POSIX"))) } ?? ""
        dirty = false
        applySeasons(artwork.seasons)
        if record?.libraryException == "正在重新获取作品资料" { needsSourceRefresh = true; startTMDB(refreshSource:true) }
        else if work.kind != .manga { startTMDB() }
    }
    private func localizeDetails() async {
        await tracker.localize(record?.work ?? work)
        guard !Task.isCancelled else { return }
        if Intelligence.shared.available, !MediaLanguage.isChinese(displayed.overview), !displayed.overview.isEmpty, displayed.overview.count <= 4000 {
            do { try await tracker.translateDescription(record?.work ?? work) } catch is CancellationError { } catch { operationError = "简介翻译失败，可稍后重试。" }
        }
    }
    private func loadArtwork() async {
        guard detailRequestsReady else { return }
        artworkLoading = true; artworkError = nil
        defer { if !Task.isCancelled { artworkLoading = false } }
        do {
            let data = try await CatalogAPI.shared.artwork(artworkSource); try Task.checkCancellation(); artwork = data
            if record != nil, isTV {
                applySeasons(data.seasons)
                if unit == nil { selectUnit(units.first?.id ?? "") }
            }
        } catch is CancellationError { } catch { if !Task.isCancelled { artworkError = error.localizedDescription } }
    }
    private func loadEpisodes() async {
        guard detailRequestsReady, isTV, unit != nil else { return }
        episodesLoading = true; episodeError = nil; episodes = []
        defer { if !Task.isCancelled { episodesLoading = false } }
        do {
            var all: [MediaEpisode] = []
            for number in Array(Set(unit?.ranges.map(\.season) ?? [season])).sorted() {
                let key = "\(artworkSource.id):\(number)"
                let data: [MediaEpisode]
                if let cached = episodeMetadata[key] { data = cached }
                else { data = try await CatalogAPI.shared.episodes(artworkSource,season:number); try Task.checkCancellation(); episodeMetadata[key] = data }
                all += data.map { value in var row = value; row.season = number; return row }
            }
            episodes = all
            if let index = record?.viewingUnits?.firstIndex(where:{ $0.id == activeUnitID }), unit?.scopeConfirmed == true,
               let last = all.map(\.number).max(), last > 0 { record?.viewingUnits?[index].lastEpisode = last }
        } catch is CancellationError { } catch { if !Task.isCancelled { episodeError = error.localizedDescription } }
    }
    private func selectTMDB(_ selected:Work) {
        tmdbTask?.cancel(); tmdbRevision = UUID()
        let revision = tmdbRevision
        resolvingTMDB = true
        tmdbTask = Task {
            defer { if revision == tmdbRevision { resolvingTMDB = false } }
            do {
                let fresh = try await CatalogAPI.shared.tmdbDetails(id:Int(selected.remoteID) ?? 0,kind:selected.kind)
                try Task.checkCancellation(); guard revision == tmdbRevision else { return }
                applyTMDB(fresh)
            } catch { if !Task.isCancelled && revision == tmdbRevision { operationError = error.localizedDescription } }
        }
    }
    private func applyTMDB(_ target:Work, automatic:Bool = false) {
        guard var current = record else { return }
        let previous = current.work
        _ = current.setPlatformAssociation(target)
        tracker.saveAssociations(current,metadataRefresh:automatic)
        guard tracker.message == nil else { operationError = tracker.message; return }
        do {
            let manual = tracker.titleTranslation(previous)

            current = try LibraryIdentity.canonical(current,using:target)
            if let savedRecord { self.savedRecord = try LibraryIdentity.canonical(savedRecord,using:target) }
            if let manual, manual.origin == "手动" { tracker.setTitle(manual.text,for:target,touchRecord:false) }
            record = current; titleText = displayed.title
            if previous.id != target.id {
                artwork = MediaArtwork(); episodes = []; episodeMetadata = [:]; artworkRevision = UUID()
            }
            if dirty { updateDirtyState() }
            operationError = nil
        } catch { operationError = error.localizedDescription }
    }
    private func startTMDB(forceAI:Bool = false,refreshSource:Bool = false) {
        guard record?.hasNoEntry(.tmdb) != true else { return }
        if !forceAI && !refreshSource, let target = record?.work.source == .tmdb ? record?.work : record?.links["tmdb"] {
            if record?.work.id != target.id { applyTMDB(target,automatic:true) }
            return
        }
        tmdbTask?.cancel(); tmdbRevision = UUID()
        let revision = tmdbRevision
        resolvingTMDB = true
        tmdbTask = Task {
            defer { if revision == tmdbRevision { resolvingTMDB = false } }
            do {
                if refreshSource {
                    let fresh = try await CatalogAPI.shared.details(work)
                    try Task.checkCancellation(); guard revision == tmdbRevision else { return }
                    let old = record?.work ?? work
                    tracker.refreshWorkMetadata(fresh,replacing:old)
                    record?.work = fresh; record?.setPlatformAssociation(fresh)
                    savedRecord?.work = fresh; savedRecord?.setPlatformAssociation(fresh)
                    titleText = fresh.title; needsSourceRefresh = false
                    if dirty { updateDirtyState() }
                    artworkRevision = UUID()
                }
                guard work.kind != .manga else { return }
                let sourceReference = work.source != .tmdb ? record?.sourceRecords?[work.id]?.work ?? work : record?.sourceRecords?.values.sorted(by:{ $0.id < $1.id }).first(where:{ $0.work.source != .tmdb })?.work ?? work
                var reference = forceAI ? sourceReference : record?.work ?? work
                reference.title = tracker.display(reference).title
                let candidate = try await MediaSearch.shared.matchTMDB(reference,linked:record?.links["tmdb"],forceAI:forceAI)
                try Task.checkCancellation(); guard revision == tmdbRevision else { return }
                guard let candidate else { operationError = "未找到 TMDB 对应作品，可修改搜索词手动匹配。"; return }
                if forceAI { tmdbCandidate = candidate } else { applyTMDB(candidate,automatic:true) }
            } catch { if !Task.isCancelled && revision == tmdbRevision { operationError = error.localizedDescription } }
        }
    }
    private func clearCache() {
        tmdbTask?.cancel(); matchingTask?.cancel(); tmdbRevision = UUID()
        guard let current = record else { return }
        let wasDirty = dirty
        let urls = artwork.images.map(\.url) + episodeMetadata.values.flatMap { $0.map(\.image) } + [current.work.image,current.work.backdrop ?? "",work.image] + current.links.values.map(\.image)
        do {
            var fresh = try tracker.clearWorkCache(from:work,current:current.work)
            savedRecord = fresh
            if wasDirty {
                fresh.score = current.score; fresh.scoreCleared = current.scoreCleared
                fresh.progress = current.progress; fresh.status = current.status; fresh.volumes = current.volumes
                fresh.retainedSeasonTracking = current.viewingUnits?.map { value in
                    var item = ViewingUnit(id:value.id,title:"",season:value.season,scopeConfirmed:true)
                    item.score = value.score; item.progress = value.progress; item.watched = value.watched; item.status = value.status
                item.trackingMarked = value.trackingMarked; item.trackingUpdatedAt = value.trackingUpdatedAt
                    return item
                }
            }
            record = fresh; artwork = MediaArtwork(); episodes = []; episodeMetadata = [:]
            artworkError = nil; episodeError = nil; operationError = nil; matchNotes = [:]; associationNotice = nil
            activeUnitID = ""; hasChosenSeason = false; titleText = fresh.work.title; needsSourceRefresh = true
            if wasDirty { updateDirtyState() }
            refreshedRatings = []; ratingErrors = [:]
            cacheRevision = UUID(); artworkRevision = UUID()
            let revision = tmdbRevision
            Task {
                await CatalogAPI.shared.invalidateArtwork(current.relatedWorkIDs.union([work.id]))
                do { try await PosterCache.shared.remove(urls,owners:current.relatedWorkIDs.union([work.id])) }
                catch { if revision == tmdbRevision { operationError = error.localizedDescription } }
                guard revision == tmdbRevision else { return }
                startTMDB(refreshSource:true)
            }
        } catch { operationError = error.localizedDescription }
    }
    private func applySeasons(_ seasons:[MediaSeason]) {
        for season in seasons {
            record?.ensureSeason(season.number,title:season.title)
            savedRecord?.ensureSeason(season.number,title:season.title)
            if let count = season.episodeCount, count > 0, let index = record?.viewingUnits?.firstIndex(where:{ $0.season == season.number }) {
                record?.viewingUnits?[index].lastEpisode = count
                if let savedIndex = savedRecord?.viewingUnits?.firstIndex(where:{ $0.season == season.number }) { savedRecord?.viewingUnits?[savedIndex].lastEpisode = count }
            }
        }
        if (unit == nil || !hasChosenSeason), let first = units.first { selectUnit(first.id) }
    }
}

/// Compare actual line-limited and full text at the same width and font.
struct ExpandableSynopsis: View {
    let text: String
    var lineLimit = 10
    var ink: Color = .secondary
    @State private var expanded = false
    @State private var fullHeight: CGFloat = 0
    @State private var collapsedHeight: CGFloat = 0
    private var overflows: Bool { fullHeight > collapsedHeight + 1 }
    private var content: String { text.isEmpty ? "暂无简介" : text }
    var body: some View {
        VStack(alignment:.leading,spacing:8) {
            Text(content).font(.body).foregroundStyle(ink).lineLimit(expanded ? nil : lineLimit).textSelection(.enabled)
                .frame(maxWidth:.infinity,alignment:.leading)
                .background(alignment:.topLeading) {
                    Text(content).font(.body).lineLimit(lineLimit).frame(maxWidth:.infinity,alignment:.leading).fixedSize(horizontal:false,vertical:true)
                        .onGeometryChange(for:CGFloat.self,of:{ $0.size.height },action:{ collapsedHeight = $0 })
                        .hidden().accessibilityHidden(true)
                }
                .background(alignment:.topLeading) {
                    Text(content).font(.body).fixedSize(horizontal:false,vertical:true).frame(maxWidth:.infinity,alignment:.leading)
                        .onGeometryChange(for:CGFloat.self,of:{ $0.size.height },action:{ fullHeight = $0 })
                        .hidden().accessibilityHidden(true)
                }
            if overflows { Button(expanded ? "收起" : "展开") { expanded.toggle() }.font(.caption) }
        }.onChange(of:text) { _,_ in expanded = false }
            .onChange(of:overflows) { _,value in if !value { expanded = false } }
    }
}

struct PlatformRatingLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let layout = arrangement(width:proposal.width ?? .infinity,subviews:subviews)
        return CGSize(width:proposal.width ?? layout.size.width,height:layout.size.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let layout = arrangement(width:bounds.width,subviews:subviews)
        for (index,subview) in subviews.enumerated() {
            let frame = layout.frames[index]
            subview.place(at:CGPoint(x:bounds.minX + frame.minX,y:bounds.minY + frame.minY),
                          anchor:.topLeading,proposal:ProposedViewSize(frame.size))
        }
    }

    private func arrangement(width: CGFloat, subviews: Subviews) -> (size:CGSize,frames:[CGRect]) {
        let width = max(0,width)
        var frames: [CGRect] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var contentWidth: CGFloat = 0
        for subview in subviews {
            let ideal = subview.sizeThatFits(.unspecified)
            let size = ideal
            if x > 0 && x + size.width > width {
                x = 0; y += rowHeight + spacing; rowHeight = 0
            }
            frames.append(CGRect(origin:CGPoint(x:x,y:y),size:size))
            contentWidth = max(contentWidth,x + size.width)
            rowHeight = max(rowHeight,size.height)
            x += size.width + spacing
        }
        return (CGSize(width:contentWidth,height:y + rowHeight),frames)
    }
}

struct DeliveryView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Environment(TrackingStore.self) private var tracker
    @State private var retrying = false
    var body: some View {
        List {
            Section {
                AdaptiveControls {
                    Button(retrying ? "正在重试…" : "重试未完成项") { Task { retrying = true; defer { retrying = false }; await tracker.retry() } }
                        .disabled(retrying || !tracker.backup.deliveries.contains(where:{ $0.isPending }))
                    Button("清除错误计数") { tracker.clearDeliveryErrorCount() }.disabled(tracker.deliveryErrorCount == 0)
                }
                .buttonStyle(.borderless)
            }
            if tracker.backup.deliveries.isEmpty { Text("暂无同步记录").foregroundStyle(.secondary) }
            ForEach(tracker.backup.deliveries.reversed()) { job in
                DisclosureGroup {
                    Text(job.contents.isEmpty ? "旧版任务未保存字段快照" : job.contents)
                        .font(.subheadline).textSelection(.enabled)
                    Text("目标：\(job.target.source.title) · \(job.target.remoteID)").font(.caption).foregroundStyle(.secondary)
                    if let error = job.errorDetail ?? (job.isError ? job.state : nil) {
                        Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
                    }
                    ForEach(job.attempts ?? []) { attempt in
                        VStack(alignment:.leading,spacing:8) {
                            Text(attempt.date,format:.dateTime.year().month().day().hour().minute().second()).font(.caption).foregroundStyle(.secondary)
                            Text(attempt.contents).font(.caption).textSelection(.enabled)
                            ForEach(attempt.steps) { step in
                                Label("\(step.method) \(step.path)" + (step.status.map { " · HTTP \($0)" } ?? ""),systemImage:step.error == nil ? "checkmark.circle" : "exclamationmark.circle")
                                    .font(.caption).foregroundStyle(step.error == nil ? Color.secondary : .red)
                                if let body = step.requestBody { DisclosureGroup("提交内容") { Text(body).font(.caption.monospaced()).textSelection(.enabled) } }
                                if let error = step.error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
                            }
                            if let error = attempt.error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
                        }.padding(.vertical,8)
                    }
                    if job.isPending {
                        Button("重试此项") { Task { retrying = true; defer { retrying = false }; await tracker.retry(deliveryIDs:[job.id]) } }
                            .buttonStyle(.borderless).disabled(retrying)
                    }
                } label: {
                    VStack(alignment:.leading,spacing:6) {
                        Text(job.target.title).font(.headline)
                        Text("\(job.target.source.title) · \(job.state)").font(.subheadline).foregroundStyle(job.isError ? Color.red : .secondary)
                        Text(job.contents).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                        Text(job.date,format:.dateTime.month().day().hour().minute()).font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical,4)
                }
            }
        }.navigationTitle("同步记录").inlineNavigationTitle()
    }
}

private struct DetailControlRow<Label:View,Control:View>: View {
    @ViewBuilder var label: () -> Label
    @ViewBuilder var control: () -> Control
    var body: some View {
        ViewThatFits(in:.horizontal) {
            HStack(alignment:.center,spacing:20) {
                label().fixedSize(horizontal:true,vertical:false)
                Spacer(minLength:0)
                control().fixedSize(horizontal:true,vertical:false)
            }
            VStack(alignment:.leading,spacing:12) {
                label()
                control()
            }.frame(maxWidth:.infinity,alignment:.leading)
        }
    }
}

private struct RatingInput: View {
    @Binding var text: String
    let label: String
    @Environment(\.browserTheme) private var theme
    @FocusState private var focused: Bool
    @ScaledMetric(relativeTo:.body) private var inputWidth: CGFloat = 76
    var body: some View {
        HStack(spacing:8) {
            Image(systemName:"star.fill").foregroundStyle((theme?.accent.color ?? Color.accentColor)).accessibilityHidden(true)
            TextField("未评分",text:$text)
                .font(.body.weight(.semibold)).monospacedDigit()
                .keyboardType(.decimalPad).multilineTextAlignment(.center).frame(width:min(130,inputWidth))
                .focused($focused).accessibilityLabel(label).accessibilityHint("输入大于零、不超过一百分的评分")
            Text("/ 100").font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal,12).frame(minHeight:44)
        .foregroundStyle(theme?.primary.color ?? .primary)
        .background(theme?.raised.color ?? Color.secondary.opacity(0.08),in:.rect(cornerRadius:10))
        .overlay { RoundedRectangle(cornerRadius:10).strokeBorder((theme?.accent.color ?? Color.accentColor).opacity(focused ? 0.8 : 0.3),lineWidth:focused ? 2 : 1) }
        .contentShape(.rect(cornerRadius:10)).onTapGesture { focused = true }
    }
}

// The delegate receives attempted swipe/zoom dismissals, including when dismissal is blocked.
private struct SheetDismissGuard: UIViewControllerRepresentable {
    var blocked: Bool
    var onAttempt: () -> Void
    func makeUIViewController(context:Context) -> Controller { Controller() }
    func updateUIViewController(_ controller:Controller,context:Context) {
        controller.blocked = blocked; controller.onAttempt = onAttempt
        controller.install()
        DispatchQueue.main.async { [weak controller] in controller?.install() }
    }
    final class Controller: UIViewController, UIAdaptivePresentationControllerDelegate {
        var blocked = false
        var onAttempt: (() -> Void)?
        weak var previousDelegate: UIAdaptivePresentationControllerDelegate?
        override func didMove(toParent parent:UIViewController?) { super.didMove(toParent:parent); install() }
        override func viewDidAppear(_ animated:Bool) { super.viewDidAppear(animated); install() }
        func install() {
            var current: UIViewController? = self
            while let candidate = current {
                if candidate.presentingViewController != nil, let presentation = candidate.presentationController {
                    if presentation.delegate !== self { previousDelegate = presentation.delegate }
                    presentation.delegate = self
                    candidate.isModalInPresentation = blocked
                    return
                }
                current = candidate.parent
            }
        }
        func presentationControllerShouldDismiss(_ presentationController:UIPresentationController) -> Bool { !blocked }
        func presentationControllerDidAttemptToDismiss(_ presentationController:UIPresentationController) { onAttempt?() }
        func presentationControllerWillDismiss(_ presentationController:UIPresentationController) {
            previousDelegate?.presentationControllerWillDismiss?(presentationController)
        }
        func presentationControllerDidDismiss(_ presentationController:UIPresentationController) {
            previousDelegate?.presentationControllerDidDismiss?(presentationController)
        }
    }
}

struct DetailPrimaryButtonStyle: ButtonStyle {
    let theme: ArtworkTheme
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration:Configuration) -> some View {
        configuration.label.fontWeight(.semibold)
            .foregroundStyle(theme.canvas.color)
            .padding(.horizontal,14).padding(.vertical,10)
            .background(theme.accent.color,in:Capsule())
            .opacity(enabled ? (configuration.isPressed ? 0.75 : 1) : 0.4)
    }
}

private struct ThemedStepper: View {
    let title:String
    @Binding var value:Int
    let range:ClosedRange<Int>
    let theme:ArtworkTheme
    init(_ title:String,value:Binding<Int>,in range:ClosedRange<Int>,theme:ArtworkTheme) {
        self.title = title; self._value = value; self.range = range; self.theme = theme
    }
    var body:some View {
        HStack {
            Text(title).foregroundStyle(theme.primary.color)
            Spacer()
            HStack(spacing:0) {
                Button { value -= 1 } label: { Image(systemName:"minus").frame(width:44,height:44) }
                    .disabled(value <= range.lowerBound).accessibilityLabel("减少" + title)
                Rectangle().fill(theme.secondary.color.opacity(0.25)).frame(width:1,height:20)
                Button { value += 1 } label: { Image(systemName:"plus").frame(width:44,height:44) }
                    .disabled(value >= range.upperBound).accessibilityLabel("增加" + title)
            }.buttonStyle(.borderless).foregroundStyle(theme.accent.color)
                .background(theme.raised.color,in:.rect(cornerRadius:10))
                .overlay { RoundedRectangle(cornerRadius:10).strokeBorder(theme.secondary.color.opacity(0.3)) }
        }.accessibilityElement(children:.contain)
    }
}
