import SwiftUI

struct BrowserView: View {
    @Environment(AppStore.self) private var store
    let isSplit: Bool
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var searchPresented = false

    var body: some View {
        @Bindable var store = store
        VStack(spacing: 0) {
            if store.section == .library && store.viewer == nil {
                ContentUnavailableView {
                    Label("连接 AniList 片单", systemImage: "rectangle.stack.badge.person.crop")
                } description: {
                    Text("登录 AniList，载入片单并同步观看进度。")
                } actions: {
                    Button("连接 AniList") { store.showingSettings = true }.buttonStyle(.glassProminent)
                }
            } else if store.isLoading && store.visibleMedia.isEmpty {
                Spacer(); ProgressView("载入作品…"); Spacer()
            } else if let error = store.error {
                ContentUnavailableView {
                    Label("暂时无法载入", systemImage: "wifi.exclamationmark")
                } description: { Text(error) } actions: {
                    Button("重试") { Task { await store.load() } }.buttonStyle(.glass)
                }
            } else if store.visibleMedia.isEmpty {
                ContentUnavailableView.search(text: store.search)
            } else {
                mediaContent
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            filters.padding(.horizontal, 12).padding(.vertical, 8)
        }
        .background { WorkspaceBackdrop() }
        .navigationTitle(store.section == .discover ? "探索" : "我的片单")
        .inlineNavigationTitle()
        .searchable(text: $store.search, isPresented: $searchPresented, prompt: store.section == .discover ? "搜索动画、书籍…" : "搜索片单…")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { searchPresented = true } label: { Label("搜索", systemImage: "magnifyingglass") }.keyboardShortcut("f")
                Button { Task { await store.load() } } label: { Label("刷新", systemImage: "arrow.clockwise") }
                    .disabled(store.isLoading)
                Button { store.grid.toggle() } label: {
                    Label(store.grid ? "列表视图" : "海报视图", systemImage: store.grid ? "list.bullet" : "square.grid.2x2")
                }
                Button { store.showingSettings = true } label: { Label("账号", systemImage: "person.crop.circle") }
            }
        }
        .task(id: store.requestKey) { await store.load() }
        .onChange(of: store.statusFilter) { _, _ in
            if !store.visibleMedia.contains(where: { $0.id == store.selection }) { store.selection = nil }
        }
    }

    private var filters: some View {
        @Bindable var store = store
        return VStack(spacing: 12) {
            Picker("媒体类型", selection: $store.kind) {
                ForEach(MediaKind.allCases) { kind in Text(kind.title).tag(kind) }
            }.pickerStyle(.segmented)
            HStack {
                Text(store.section == .discover ? "DISCOVER / \(store.kind.rawValue)" : "LIBRARY / \(store.kind.rawValue)")
                    .font(.caption2.weight(.bold)).tracking(1.5).foregroundStyle(.secondary)
                Spacer()
                if store.section == .discover {
                    Menu {
                        Picker("排序", selection: $store.sort) {
                            ForEach(BrowseSort.allCases) { Text($0.title).tag($0) }
                        }
                    } label: { Label(store.sort.title, systemImage: "line.3.horizontal.decrease") }
                        .font(.subheadline.weight(.medium))
                        .frame(minHeight: 44)
                } else {
                    Menu {
                        Button("全部") { store.statusFilter = nil }
                        ForEach(ListStatus.allCases) { status in
                            Button(status.title) { store.statusFilter = status }
                        }
                    } label: { Label(store.statusFilter?.title ?? "全部状态", systemImage: "line.3.horizontal.decrease") }
                        .font(.subheadline.weight(.medium))
                        .frame(minHeight: 44)
                }
            }
        }.padding(14)
            .glassPanel()
    }

    @ViewBuilder private var mediaContent: some View {
        if store.grid && !dynamicTypeSize.isAccessibilitySize {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 16, alignment: .top)], alignment: .leading, spacing: 24) {
                    ForEach(store.visibleMedia) { media in
                        mediaLink(media) { PosterCard(media: media, selected: isSplit && store.selection == media.id) }
                    }
                }.padding(16)
                pagination
            }.refreshable { await store.load() }
        } else {
            List {
                ForEach(store.visibleMedia) { media in
                    mediaLink(media) {
                        MediaRow(media: media, entry: store.library.first { $0.media.id == media.id })
                    }
                    .listRowBackground(isSplit && store.selection == media.id ? Color.accentColor.opacity(0.09) : Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                }
                if store.section == .discover { pagination.listRowSeparator(.hidden) }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .refreshable { await store.load() }
        }
    }
    @ViewBuilder private func mediaLink<LabelView: View>(_ media: Media, @ViewBuilder label: () -> LabelView) -> some View {
        if isSplit {
            Button { store.selection = media.id } label: {
                label().frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(store.selection == media.id ? [.isSelected] : [])
            .hoverEffect(.highlight)
        } else {
            NavigationLink { MediaDetailView(media: media) } label: { label() }.buttonStyle(.plain)
        }
    }
    @ViewBuilder private var pagination: some View {
        if store.section == .discover && store.hasNextPage {
            HStack {
                Spacer()
                Button { Task { await store.loadMore() } } label: {
                    if store.isLoadingMore { ProgressView() } else { Text("载入更多作品") }
                }.disabled(store.isLoadingMore).buttonStyle(.glass)
                Spacer()
            }.padding()
        }
    }
}

struct MediaRow: View {
    let media: Media
    var entry: ListEntry?
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            CoverImage(url: media.coverURL).frame(width: 64, height: 92).clipShape(.rect(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 6) {
                Text(media.title.display).font(.subheadline.weight(.semibold)).lineLimit(2)
                Text(media.title.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Text(media.metadata).font(.caption2).foregroundStyle(.secondary)
                HStack {
                    if let entry {
                        Text("\(entry.progress) / \(media.total.map(String.init) ?? "—") \(media.unit)")
                        Spacer()
                        StatusBadge(text:entry.status.title)
                    } else {
                        if let score = media.averageScore {
                            Label("\(score)%", systemImage: "star.fill").foregroundStyle(.indigo)
                        }
                        Spacer()
                        StatusBadge(text:media.releaseStatus)
                    }
                }.font(.caption2.weight(.medium)).monospacedDigit()
            }.padding(.vertical, 3)
        }.accessibilityElement(children: .combine)
    }
}

struct PosterCard: View {
    @ScaledMetric(relativeTo:.subheadline) private var captionHeight: CGFloat = 64
    let media: Media
    var selected = false
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            CoverImage(url: media.coverURL)
                .aspectRatio(0.7, contentMode: .fit)
                .clipShape(.rect(cornerRadius: 12))
                .overlay(alignment: .topTrailing) {
                    if let score = media.averageScore {
                        Text("\(score)%").font(.caption2.bold()).padding(7)
                            .glassEffect(.regular, in: .capsule).padding(8)
                    }
                }
                .overlay(alignment: .bottomTrailing) { if media.type == .manga, ["MANGA","ONE_SHOT","NOVEL"].contains(media.format ?? "") { BookBadge(isNovel:media.format == "NOVEL") } }
                .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 3) }
            VStack(alignment:.leading,spacing:6) {
                Text(media.title.display).font(.subheadline.weight(.semibold)).lineLimit(2).frame(maxWidth:.infinity,alignment:.topLeading)
                Text(media.metadata).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength:0)
            }.frame(height:captionHeight,alignment:.topLeading)
        }.contentShape(Rectangle())
    }
}

struct CoverImage: View {
    let url: URL?
    var body: some View {
        CachedArtwork(address:url?.absoluteString ?? "",retention:.preferred)
            .accessibilityHidden(true)
    }
}

extension Color {
    static var canvas: Color {
        #if os(iOS)
        Color(uiColor: .systemBackground)
        #else
        Color(nsColor: .windowBackgroundColor)
        #endif
    }
    static var panel: Color {
        #if os(iOS)
        Color(uiColor: .secondarySystemGroupedBackground)
        #else
        Color(nsColor: .controlBackgroundColor)
        #endif
    }
}
