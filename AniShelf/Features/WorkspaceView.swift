import SwiftUI

enum ShelfLayout {
    static let pageInset: CGFloat = 20
    static let sectionSpacing: CGFloat = 24
    static let controlSpacing: CGFloat = 12
    static let cardSpacing: CGFloat = 16
    static let minimumHitSize: CGFloat = 44
}

struct WorkspaceView: View {
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var preferredColumn: NavigationSplitViewColumn = .content
    @Environment(AppStore.self) private var store
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif
    var body: some View {
        @Bindable var store = store
        Group {
            #if os(iOS)
            GeometryReader { geometry in
                if sizeClass == .compact {
                    phone
                } else {
                    desktop
                        .onAppear { adaptColumns(to: geometry.size.width) }
                        .onChange(of: geometry.size.width >= 1180) { _, _ in
                            adaptColumns(to: geometry.size.width)
                        }
                }
            }
            #else
            desktop.frame(minWidth: 920, minHeight: 680)
            #endif
        }
        .sheet(isPresented: $store.showingSettings) { SettingsView() }
    }
    private var desktop: some View {
        @Bindable var store = store
        return NavigationSplitView(columnVisibility: $columnVisibility, preferredCompactColumn: $preferredColumn) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 210, max: 240)
        } content: {
            BrowserView(isSplit: true)
                .navigationSplitViewColumnWidth(min: 300, ideal: 340, max: 400)
        } detail: {
            if let media = store.selectedMedia {
                MediaDetailView(media: media).id(media.id)
            } else {
                ContentUnavailableView {
                    Label("选择作品", systemImage: "rectangle.on.rectangle.angled")
                } description: {
                    Text("在作品列表中选择一部作品，\n在这里查看详情、评分与追番进度。")
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .onChange(of: store.selection) { _, selection in
            if selection != nil { preferredColumn = .detail }
        }
        .onChange(of: store.section) { _, _ in preferredColumn = .content }
    }
    // Keep the browser and detail readable in portrait and Stage Manager windows.
    private func adaptColumns(to width: CGFloat) {
        columnVisibility = width >= 1180 ? .all : .doubleColumn
    }
    #if os(iOS)
    private var phone: some View {
        @Bindable var store = store
        return TabView(selection: $store.section) {
            Tab("探索", systemImage: "square.grid.2x2", value: WorkspaceSection.discover) {
                NavigationStack { BrowserView(isSplit: false) }
            }
            Tab("我的片单", systemImage: "rectangle.stack", value: WorkspaceSection.library) {
                NavigationStack { BrowserView(isSplit: false) }
            }
        }
        .tabBarMinimizeBehavior(.never)
    }
    #endif
}

private enum SidebarDestination: Hashable {
    case discover
    case library(ListStatus?)
}

struct SidebarView: View {
    @Environment(AppStore.self) private var store

    // Derive selection from the shared state so keyboard commands and browser
    // filters keep the native sidebar highlight in sync.
    private var destination: Binding<SidebarDestination?> {
        Binding {
            store.section == .discover ? .discover : .library(store.statusFilter)
        } set: { value in
            guard let value else { return }
            switch value {
            case .discover:
                store.section = .discover
                store.statusFilter = nil
            case .library(let status):
                store.section = .library
                store.statusFilter = status
            }
            store.selection = nil
        }
    }

    var body: some View {
        @Bindable var store = store
        List(selection: destination) {
            Section {
                NavigationLink(value: SidebarDestination.discover) {
                    Label("探索", systemImage: "square.grid.2x2")
                }
                NavigationLink(value: SidebarDestination.library(nil)) {
                    Label("我的片单", systemImage: "rectangle.stack")
                }
            }
            if store.viewer != nil {
                Section("片单状态") {
                    ForEach(ListStatus.allCases) { status in
                        NavigationLink(value: SidebarDestination.library(status)) {
                            Label(status.title, systemImage: status.icon)
                        }
                        .badge(store.counts[status] ?? 0)
                    }
                }
            }
            Section("媒体") {
                Picker("媒体类型", selection: $store.kind) {
                    ForEach(MediaKind.allCases) { kind in
                        Text(kind.title).tag(kind)
                    }
                }
                .onChange(of: store.kind) { _, _ in store.selection = nil }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("AniShelf")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { store.showingSettings = true } label: {
                    Label("账号与设置", systemImage: "person.crop.circle")
                }
                .help(store.viewer.map { "\($0.name) · 账号与设置" } ?? "连接 AniList 与设置")
            }
        }
    }
}

extension View {
    /// Register custom column headers with the scroll edge so the system's
    /// variable blur includes the status-bar safe area and fades into content.
    func shelfTopBar<Bar: View>(@ViewBuilder content: () -> Bar) -> some View {
        self
            .safeAreaBar(edge: .top, spacing: 0, content: content)
            .scrollEdgeEffectStyle(.soft, for: .top)
    }

    @ViewBuilder func inlineNavigationTitle() -> some View {
        #if os(iOS)
        navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }
    @ViewBuilder func plainTextInput() -> some View {
        #if os(iOS)
        textInputAutocapitalization(.never).autocorrectionDisabled()
        #else
        autocorrectionDisabled()
        #endif
    }
}

// Shared native Liquid Glass surfaces for the workspace and sheets.
struct GlassPanel: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var cornerRadius: CGFloat
    var interactive: Bool

    @ViewBuilder func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(Color.panel, in: .rect(cornerRadius: cornerRadius))
        } else {
            content.glassEffect(
                interactive ? .regular.interactive() : .regular,
                in: .rect(cornerRadius: cornerRadius)
            )
        }
    }
}

extension View {
    func glassPanel(cornerRadius: CGFloat = 24, interactive: Bool = false) -> some View {
        modifier(GlassPanel(cornerRadius: cornerRadius, interactive: interactive))
    }
}

struct WorkspaceBackdrop: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var body: some View {
        ZStack {
            Color(.systemGroupedBackground)
            if !reduceTransparency {
                RadialGradient(colors:[.indigo.opacity(scheme == .dark ? 0.16 : 0.07),.clear],
                               center:.topLeading,startRadius:0,endRadius:780)
                RadialGradient(colors:[.cyan.opacity(scheme == .dark ? 0.08 : 0.04),.clear],
                               center:.trailing,startRadius:0,endRadius:600)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
