import SwiftUI

enum ShelfDestination: Int, CaseIterable, Identifiable {
    case home, discover, library, anilist, trakt
    static var tabs: [ShelfDestination] { [.home,.discover,.library] }
    var id: Int { rawValue }
    var title: String { switch self { case .home: "首页"; case .discover: "发现"; case .library: "资料库"; case .anilist: "AniList"; case .trakt: "Trakt" } }
    var icon: String { switch self { case .home: "house"; case .discover: "magnifyingglass"; case .library: "books.vertical"; case .anilist: "book.closed"; case .trakt: "play.tv" } }
}
private enum WorkspaceSheet: Identifiable {
    case settings, deliveries, work(Work)
    var id:String { switch self { case .settings: "settings"; case .deliveries: "deliveries"; case .work(let work): work.id } }
}
private enum WorkspaceUtilitySheet {
    case settings, deliveries
}
struct WorkTransitionContext: Sendable {
    let namespace: Namespace.ID
    let open: @MainActor @Sendable (Work,String) -> Void
}
private struct WorkTransitionKey: EnvironmentKey { static let defaultValue: WorkTransitionContext? = nil }
extension EnvironmentValues {
    var workTransition: WorkTransitionContext? {
        get { self[WorkTransitionKey.self] }
        set { self[WorkTransitionKey.self] = newValue }
    }
}
struct WorkTransitionSource: ViewModifier {
    let id: String
    let namespace: Namespace.ID?
    @ViewBuilder func body(content:Content) -> some View {
        if let namespace { content.matchedTransitionSource(id:id,in:namespace) }
        else { content }
    }
}
@MainActor private enum PlatformNavigationIcon {
    static let anilist = image("Platform-anilist")
    static let trakt = image("Platform-trakt")
    private static func image(_ name: String) -> UIImage {
        let size = CGSize(width:22,height:22)
        let format = UIGraphicsImageRendererFormat(); format.scale = 3
        return UIGraphicsImageRenderer(size:size,format:format).image { _ in
            UIImage(named:name)?.draw(in:CGRect(origin:.zero,size:size))
        }.withRenderingMode(.alwaysOriginal)
    }
}
private struct ShelfSidebarVisibleKey: EnvironmentKey { static let defaultValue = false }
private extension EnvironmentValues {
    var shelfSidebarVisible: Bool {
        get { self[ShelfSidebarVisibleKey.self] }
        set { self[ShelfSidebarVisibleKey.self] = newValue }
    }
}
// A tab group's children are peers, not a drill-down navigation stack.
// UIKit may push a lazily created child the first time it is selected.
private final class ShelfImmediateTransition: NSObject, UIViewControllerAnimatedTransitioning {
    func transitionDuration(using transitionContext: (any UIViewControllerContextTransitioning)?) -> TimeInterval { 0 }
    func animateTransition(using transitionContext: any UIViewControllerContextTransitioning) {
        guard let destination = transitionContext.viewController(forKey:.to),
              let view = transitionContext.view(forKey:.to) else {
            transitionContext.completeTransition(false)
            return
        }
        UIView.performWithoutAnimation {
            view.transform = .identity
            view.frame = transitionContext.finalFrame(for:destination)
            transitionContext.containerView.addSubview(view)
            view.layoutIfNeeded()
        }
        transitionContext.completeTransition(!transitionContext.transitionWasCancelled)
    }
}
private final class ShelfTabNavigationController: UINavigationController, UINavigationControllerDelegate {
    override func viewDidLoad() {
        super.viewDidLoad()
        delegate = self
    }
    func navigationController(_ navigationController: UINavigationController, animationControllerFor operation: UINavigationController.Operation, from fromVC: UIViewController, to toVC: UIViewController) -> (any UIViewControllerAnimatedTransitioning)? {
        ShelfImmediateTransition()
    }
    override func pushViewController(_ viewController: UIViewController, animated: Bool) {
        super.pushViewController(viewController,animated:false)
    }
    override func setViewControllers(_ viewControllers: [UIViewController], animated: Bool) {
        super.setViewControllers(viewControllers,animated:false)
    }
    override func popViewController(animated: Bool) -> UIViewController? {
        super.popViewController(animated:false)
    }
    override func popToViewController(_ viewController: UIViewController, animated: Bool) -> [UIViewController]? {
        super.popToViewController(viewController,animated:false)
    }
    override func popToRootViewController(animated: Bool) -> [UIViewController]? {
        super.popToRootViewController(animated:false)
    }
}
private struct NativeShelfNavigation<Content: View, Footer: View>: UIViewControllerRepresentable {
    @Binding var selection: ShelfDestination
    let wide: Bool
    @ViewBuilder var content: (ShelfDestination) -> Content
    @ViewBuilder var footer: () -> Footer

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIViewController(context: Context) -> UITabBarController {
        let controller = UITabBarController()
        controller.mode = .tabSidebar
        controller.tabBarMinimizeBehavior = .never
        controller.delegate = context.coordinator
        controller.sidebar.delegate = context.coordinator
        controller.sidebar.preferredLayout = .tile
        controller.sidebar.isHidden = !wide
        controller.sidebar.headerContentConfiguration = UIHostingConfiguration {
            Text("Taleqube").font(.title2.bold()).padding(.vertical,8)
        }
        context.coordinator.owner = controller
        context.coordinator.installTabs()
        let bottom = UIHostingController(rootView:AnyView(footer().tint(.indigo)))
        bottom.sizingOptions = .intrinsicContentSize
        bottom.view.backgroundColor = .clear
        controller.addChild(bottom)
        controller.sidebar.bottomBarView = bottom.view
        bottom.didMove(toParent:controller)
        context.coordinator.bottom = bottom
        return controller
    }
    func updateUIViewController(_ controller: UITabBarController, context: Context) {
        let coordinator = context.coordinator
        let layoutChanged = coordinator.parent.wide != wide
        coordinator.parent = self
        if layoutChanged { coordinator.installTabs() }
        coordinator.updateContent()
        if let selected = coordinator.tabs[selection], controller.selectedTab !== selected {
            controller.selectedTab = selected
        }
        coordinator.bottom?.rootView = AnyView(footer().tint(.indigo))
    }
    final class Coordinator: NSObject, UITabBarControllerDelegate, UITabBarController.Sidebar.Delegate {
        var parent: NativeShelfNavigation
        weak var owner: UITabBarController?
        var bottom: UIHostingController<AnyView>?
        var tabs: [ShelfDestination:UITab] = [:]
        var hosts: [ShelfDestination:UIHostingController<AnyView>] = [:]
        init(_ parent: NativeShelfNavigation) { self.parent = parent }
        private func root(_ item: ShelfDestination) -> AnyView {
            AnyView(parent.content(item).environment(\.shelfSidebarVisible,parent.wide && owner?.sidebar.isHidden == false))
        }
        func updateContent() {
            for (item,host) in hosts { host.rootView = root(item) }
        }
        func installTabs() {
            guard let owner else { return }
            for item in ShelfDestination.allCases where tabs[item] == nil {
                let image: UIImage? = switch item {
                case .anilist: PlatformNavigationIcon.anilist
                case .trakt: PlatformNavigationIcon.trakt
                default: UIImage(systemName:item.icon)
                }
                let tab = UITab(title:item.title,image:image,identifier:"workspace.\(item.rawValue)") { [weak self] _ in
                    guard let self else { return UIViewController() }
                    if let host = self.hosts[item] { return host }
                    let host = UIHostingController(rootView:self.root(item))
                    self.hosts[item] = host
                    return host
                }
                tab.preferredPlacement = .fixed
                tab.allowsHiding = false
                tabs[item] = tab
            }
            if parent.wide {
                let main = UITabGroup(title:"浏览",image:nil,identifier:"workspace.browse",children:ShelfDestination.tabs.compactMap { tabs[$0] },viewControllerProvider:{ _ in UIViewController() })
                let platforms = UITabGroup(title:"平台",image:nil,identifier:"workspace.platforms",children:[tabs[.anilist]!,tabs[.trakt]!],viewControllerProvider:{ _ in UIViewController() })
                for group in [main,platforms] {
                    let navigation = ShelfTabNavigationController()
                    // This is the single navigation bar for the group's pages.
                    // UIKit can integrate it with the top tab bar when the sidebar closes.
                    navigation.setNavigationBarHidden(false,animated:false)
                    group.managingNavigationController = navigation
                    group.preferredPlacement = .sidebarOnly
                    group.sidebarAppearance = .rootSection
                    group.allowsReordering = false
                    group.allowsHiding = false
                }
                owner.setTabs([main,platforms],animated:false)
            } else {
                owner.setTabs(ShelfDestination.tabs.compactMap { tabs[$0] },animated:false)
            }
            owner.selectedTab = tabs[parent.selection] ?? tabs[.home]
        }
        func tabBarController(_ tabBarController: UITabBarController, didSelectTab selectedTab: UITab, previousTab: UITab?) {
            guard let item = tabs.first(where:{ $0.value === selectedTab })?.key else { return }
            guard parent.selection != item else { return }
            parent.selection = item
        }
        func tabBarController(_ tabBarController: UITabBarController, sidebarVisibilityWillChange sidebar: UITabBarController.Sidebar, animator: any UITabBarController.Sidebar.Animating) {
            // Update inside the system transition, without a second queued layout pass.
            updateContent()
        }
    }
}
private struct WorkspaceUtilityToolbar<Utilities: View>: ViewModifier {
    @Environment(\.shelfSidebarVisible) private var sidebarVisible
    @ViewBuilder var utilities: () -> Utilities

    func body(content: Content) -> some View {
        content.toolbar {
            if !sidebarVisible {
                ToolbarItemGroup(placement:.primaryAction) { utilities() }
            }
        }
    }
}
struct TrackingView: View {
    @Namespace private var workZoom
    @State private var workSource = ""

    @Environment(TrackingStore.self) private var tracker
    @Environment(AppStore.self) private var appStore
    @Environment(\.scenePhase) private var phase
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.horizontalSizeClass) private var size
    @AppStorage("workspace.destination") private var destination: ShelfDestination = .home
    @State private var utilitySheet: WorkspaceUtilitySheet?
    @State private var libraryMedia = "影视"
    @State private var selecting = false
    @State private var refreshingPages = Set<ShelfDestination>()
    private var refreshing:Bool { refreshingPages.contains(destination) }
    @ScaledMetric(relativeTo:.title2) private var featureHeight: CGFloat = UIDevice.current.userInterfaceIdiom == .phone ? 360 : 410
    @State private var featuredPage = 0
    @State private var selectedIDs: Set<String> = []
    @State private var deletingIDs: Set<String> = []
    @State private var libraryFilter = "全部"
    @State private var matchingFilter = ""
    @State private var libraryQuery = ""
    @State private var librarySort: LibrarySort = .added
    @State private var bookFilter: BookFilter = .all
    private var usesWideNavigation: Bool {
        #if targetEnvironment(macCatalyst)
        true
        #else
        size == .regular
        #endif
    }
    private var contentInset: CGFloat { usesWideNavigation ? 32 : ShelfLayout.pageInset }
    private var sheetDestination: WorkspaceSheet? {
        switch utilitySheet {
        case .settings: return .settings
        case .deliveries: return .deliveries
        case nil: break
        }
        if let work = tracker.selected { return .work(tracker.detailWork(for:work)) }
        return nil
    }
    private var presentedSheet: Binding<WorkspaceSheet?> {
        // Read state during body evaluation so button actions invalidate the presenter.
        let currentSheet = sheetDestination
        return Binding(get: { currentSheet }, set: { value in
            if value == nil {
                if utilitySheet != nil { utilitySheet = nil }
                else { tracker.selected = nil }
            }
        })
    }
    private func presentPendingArchive() {
        guard tracker.pendingArchiveURL != nil, tracker.selected == nil else { return }
        utilitySheet = .settings
    }
    @ViewBuilder private var navigation: some View {
        #if targetEnvironment(macCatalyst)
        NavigationSplitView {
            List(selection: Binding<ShelfDestination?>(get: { destination }, set: { if let value = $0 { destination = value } })) {
                Section("浏览") {
                    ForEach(ShelfDestination.tabs) { item in Label(item.title,systemImage:item.icon).tag(item) }
                }
                Section("平台") {
                    ForEach([ShelfDestination.anilist,.trakt]) { item in Label(item.title,systemImage:item.icon).tag(item) }
                }
            }
            .navigationTitle("Taleqube")
            .navigationSplitViewColumnWidth(min:180,ideal:220,max:300)
        } detail: {
            NavigationStack { page(destination) }
        }
        .background(MacWindowConfiguration())
        #else
        NativeShelfNavigation(selection:$destination,wide:usesWideNavigation) { item in
            Group {
                if usesWideNavigation {
                    page(item)
                } else {
                    NavigationStack { page(item) }
                }
            }
                .environment(tracker)
                .environment(\.workTransition,WorkTransitionContext(namespace:workZoom,open:{ work,source in
                    workSource = source; tracker.selected = work
                }))
                .tint(.indigo)
        } footer: {
            HStack {
                settingsButton.buttonStyle(.glass).buttonBorderShape(.circle)
                Spacer(minLength:12)
                deliveriesButton.buttonStyle(.glass).buttonBorderShape(.circle)
            }
            .padding(.horizontal,20).padding(.vertical,12)
        }
        #endif
    }
    var body: some View {
        navigation
        // Let UIKit own safe-area insets once, including its translucent bars.
        // Applying SwiftUI's outer safe area clips the entire controller first.
        #if !targetEnvironment(macCatalyst)
        .ignoresSafeArea(.container)
        #endif
        .onAppear { normalizeCompactDestination(); presentPendingArchive() }
        .onChange(of:tracker.pendingArchiveURL) { _,_ in presentPendingArchive() }
        .onChange(of:tracker.selected) { _,_ in presentPendingArchive() }
        .onChange(of:size) { _,_ in normalizeCompactDestination() }
        .environment(\.workTransition,WorkTransitionContext(namespace:workZoom,open:{ work,source in
            workSource = source; tracker.selected = work
        }))
        .sheet(item:presentedSheet) { sheet in
            Group {
                switch sheet {
                case .deliveries:
                    NavigationStack { DeliveryView().toolbar { ToolbarItem(placement:.confirmationAction) { Button("完成") { utilitySheet = nil } } } }
                        .presentationDetents([.large]).presentationSizing(.form)
                        .navigationTransition(.zoom(sourceID:"deliveries",in:workZoom))
                case .settings: ConnectionsView().presentationSizing(.form).presentationDetents([.large])
                        .navigationTransition(.zoom(sourceID:"settings",in:workZoom))
                case .work(let work): WorkSheet(work:work,systemDark:colorScheme == .dark,fromRecent:workSource.hasPrefix("recent:"))
                        .frame(idealWidth:700,idealHeight:1100)
                        .presentationSizing(.fitted)
                        .presentationDetents([.large])
                        .navigationTransition(.zoom(sourceID:workSource,in:workZoom))
                }
            }
            .environment(tracker)
            .environment(appStore)
        }
        .alert("操作未完成",isPresented:Binding(get:{ tracker.message != nil && tracker.selected == nil && utilitySheet == nil },set:{ if !$0 { tracker.message = nil } })) { Button("好") { tracker.message = nil } } message: { Text(tracker.message ?? "") }
        .task {
            if Credentials.read("anilist.token").isEmpty, let token = TokenVault.read() { try? Credentials.write("anilist.token",token) }
            async let history:Void = tracker.refreshHistory()
            async let home:Void = tracker.loadHome()
            async let library:Void = tracker.refreshLibrary()
            _ = await (history,home,library)
        }
        .onChange(of:tracker.keyboardRefreshRequest) { _,_ in Task { await refreshPage(destination) } }
        .onChange(of:destination) { _,_ in selecting = false; selectedIDs = [] }
        .confirmationDialog("从资料库删除 \(deletingIDs.count) 部作品？",isPresented:Binding(get:{ !deletingIDs.isEmpty },set:{ if !$0 { deletingIDs = [] } }),titleVisibility:.visible) {
            Button("删除",role:.destructive) { tracker.deleteRecords(deletingIDs); selectedIDs.subtract(deletingIDs); deletingIDs = []; if selectedIDs.isEmpty { selecting = false } }
        } message: { Text("删除本机记录和待同步任务，平台收藏保持原状。") }
        .onChange(of:libraryQuery) { _,_ in selectedIDs.formIntersection(Set(records.map(\.id))) }
        .task(id:"\(libraryMedia):\(bookFilter.rawValue)") { if libraryMedia == "书籍" && bookFilter != .all { await tracker.resolveLibraryBookFormats() } }
        .onChange(of:bookFilter) { _,_ in selectedIDs.formIntersection(Set(records.map(\.id))) }
        .onChange(of:libraryFilter) { _,_ in selectedIDs.formIntersection(Set(records.map(\.id))) }
        .onChange(of:records.map(\.id)) { _,ids in
            selectedIDs.formIntersection(Set(ids))
            if ids.isEmpty { selecting = false }
        }
        .onChange(of:tracker.searchFocusRequest) { _,_ in destination = .discover }
        .onChange(of:phase) { if phase == .active { Task { await tracker.refreshHistory() } } }
    }
    private func normalizeCompactDestination() {
        if !usesWideNavigation && !ShelfDestination.tabs.contains(destination) { destination = .library }
    }
    private var settingsButton: some View {
        Button { utilitySheet = .settings } label: {
            Label("设置",systemImage:"gearshape")
                .labelStyle(.iconOnly)
                .frame(width:UIDevice.current.userInterfaceIdiom == .phone ? 44 : 28,height:UIDevice.current.userInterfaceIdiom == .phone ? 44 : 28)
                .contentShape(Rectangle())
        }
        .overlay(alignment:.topTrailing) {
            if !AccountHealth.shared.expiredPlatforms.isEmpty {
                Image(systemName:"exclamationmark.circle.fill").font(.caption).foregroundStyle(.white,.red).allowsHitTesting(false)
            }
        }
        .accessibilityLabel(AccountHealth.shared.expiredPlatforms.isEmpty ? "设置" : "设置，登录失效：" + AccountHealth.shared.expiredPlatforms.map(\.title).joined(separator:"、"))
        .matchedTransitionSource(id:"settings",in:workZoom).help("设置").accessibilityIdentifier("sidebar.settings")
    }
    private var deliveriesButton: some View {
        Button { utilitySheet = .deliveries } label: {
            Label("同步记录",systemImage:"clock.arrow.circlepath")
                .labelStyle(.iconOnly)
                .frame(width:UIDevice.current.userInterfaceIdiom == .phone ? 44 : 28,height:UIDevice.current.userInterfaceIdiom == .phone ? 44 : 28)
                .contentShape(Rectangle())
                .overlay(alignment:.topTrailing) {
                    if tracker.deliveryErrorCount > 0 {
                        Text(String(tracker.deliveryErrorCount)).font(.caption2.bold()).foregroundStyle(.white)
                            .padding(.horizontal,5).frame(minWidth:18,minHeight:18).background(.red,in:Capsule())
                            .allowsHitTesting(false).accessibilityHidden(true)
                    }
                }
        }.matchedTransitionSource(id:"deliveries",in:workZoom).help("同步记录").accessibilityIdentifier("sidebar.deliveries")
            .accessibilityLabel("同步记录")
            .accessibilityValue("\(tracker.deliveryErrorCount) 个未处理错误")
    }
    private func page(_ item:ShelfDestination) -> some View {
        ScrollView {
            VStack(alignment:.leading,spacing:28) {
                if usesWideNavigation {
                    Text(item.title).font(.largeTitle.bold())
                        .accessibilityAddTraits(.isHeader)
                        .frame(maxWidth:.infinity,alignment:.leading)
                        .padding(.horizontal,item == .home ? contentInset : 0)
                        .padding(.top,item == .home ? 12 : 0)
                }
                switch item {
                case .home: home
                case .discover: CatalogBrowserView()
                case .library: library
                case .anilist: PlatformShelfView(source:.anilist)
                case .trakt: PlatformShelfView(source:.trakt)
                }
            }.padding(item == .home ? 0 : contentInset).frame(maxWidth:.infinity,alignment:.leading)
        }
        .background { WorkspaceBackdrop() }
        .navigationTitle(item.title).inlineNavigationTitle()
        .navigationBarBackButtonHidden(usesWideNavigation)
        .scrollEdgeEffectStyle(.soft,for:.top)
        .toolbar {
            if usesWideNavigation && item != .library {
                ToolbarItem(placement:.primaryAction) {
                    Button { Task { await refreshPage(item) } } label: {
                        ZStack {
                            Image(systemName:"arrow.clockwise").opacity(refreshing || tracker.loadingLibrary || !tracker.browsingRequests.isEmpty ? 0 : 1)
                            if refreshing || tracker.loadingLibrary || !tracker.browsingRequests.isEmpty { ProgressView() }
                        }.frame(minWidth:44,minHeight:44)
                    }.accessibilityLabel("刷新").accessibilityIdentifier("workspace.refresh").disabled(refreshing)
                }
            }
        }
        .modifier(WorkspaceUtilityToolbar { settingsButton; deliveriesButton })
        .refreshable { await refreshPage(item) }
    }
    private func refreshPage(_ item:ShelfDestination) async {
        guard refreshingPages.insert(item).inserted else { return }
        defer { refreshingPages.remove(item) }
        tracker.refreshSource = item == .anilist ? .anilist : item == .trakt ? .trakt : nil
        switch item {
        case .home:
            async let history:Void = tracker.refreshHistory()
            async let home:Void = tracker.loadHome()
            _ = await (history,home)
        case .library: await tracker.refreshLibrary()
        case .anilist,.trakt:
            let source: Catalog = item == .anilist ? .anilist : .trakt
            if tracker.platformDiscovery.contains(source) { tracker.refreshRequest = UUID() }
            else { await tracker.refreshLibrary(source:source) }
        case .discover: tracker.refreshRequest = UUID()
        }
    }
    private var home: some View {
        VStack(alignment:.leading,spacing:UIDevice.current.userInterfaceIdiom == .phone ? 12 : 36) {
            let featured = Array(MediaLanguage.merge(tracker.recent.map(\.0),tracker.homeRecommendations).prefix(5))
            if !featured.isEmpty {
                VStack(spacing:8) {
                    TabView(selection:$featuredPage) {
                        ForEach(Array(featured.enumerated()),id:\.element.id) { index, work in
                            HomeFeature(work:work) { workSource = "featured:\(work.id)"; tracker.selected = work }
                                .matchedTransitionSource(id:"featured:\(work.id)",in:workZoom)
                                .tag(index)
                        }
                    }.tabViewStyle(.page(indexDisplayMode:.never)).frame(height:featureHeight).clipShape(.rect(cornerRadius:24))
                        .overlay { RoundedRectangle(cornerRadius:24).strokeBorder(.white.opacity(0.18),lineWidth:0.5).allowsHitTesting(false) }
                        .shadow(color:.black.opacity(0.12),radius:16,y:8)
                    if featured.count > 1 {
                        HStack(spacing:0) {
                            ForEach(featured.indices,id:\.self) { index in
                                Button {
                                    withAnimation(.easeInOut(duration:0.25)) { featuredPage = index }
                                } label: {
                                    Circle().fill(Color.primary.opacity(featuredPage == index ? 0.75 : 0.20))
                                        .frame(width:6,height:6)
                                        .frame(width:28,height:28)
                                        .contentShape(.rect)
                                }.buttonStyle(.plain)
                                    .accessibilityLabel("第 \(index + 1) 页，共 \(featured.count) 页")
                                    .accessibilityAddTraits(featuredPage == index ? [.isSelected] : [])
                            }
                        }.frame(maxWidth:.infinity)
                    }
                }
                .padding(.horizontal,contentInset)
                .onChange(of:featured.map(\.id)) { _, _ in featuredPage = 0 }
            } else {
                VStack(alignment:.leading,spacing:16) { Text("发现电影与剧集").font(.largeTitle.bold()); Button("发现作品") { destination = .discover }.buttonStyle(.glassProminent) }
                    .frame(maxWidth:.infinity,alignment:.leading).padding(32).frame(height:300).background(LinearGradient(colors:[.indigo.opacity(0.25),.clear],startPoint:.topLeading,endPoint:.bottomTrailing))
            }
            VStack(alignment:.leading,spacing:36) {
                if !tracker.recent.isEmpty { homeRow("最近观看",works:tracker.recent.map(\.0),recent:true) }
                let all = tracker.backup.records.values.sorted {
                    if $0.addedAt != $1.addedAt { return ($0.addedAt ?? .distantPast) > ($1.addedAt ?? .distantPast) }
                    return $0.work.title.localizedStandardCompare($1.work.title) == .orderedAscending
                }
                homeRow("最近添加的影视",works:all.filter { $0.work.kind != .manga }.map(\.work),personal:true)
                homeRow("最近添加的书籍",works:all.filter { $0.work.kind == .manga }.map(\.work),personal:true)
                let ongoing = all.filter { ["进行中","重温中"].contains($0.status) }
                homeRow("继续观看",works:ongoing.filter { $0.work.kind != .manga }.map(\.work),personal:true)
                homeRow("继续阅读",works:ongoing.filter { $0.work.kind == .manga }.map(\.work),personal:true)
                ForEach([Catalog.tmdb,.anilist,.trakt,.bangumi,.mal]) { source in
                    homeRow(source.title + " 当前推荐",works:tracker.recommendations[source.rawValue] ?? [])
                }
                homeRow("今日随机 · 影视",works:tracker.dailyPicks(manga:false),personal:true)
                homeRow("今日随机 · 书籍",works:tracker.dailyPicks(manga:true),personal:true)
            }.padding(.horizontal,contentInset).padding(.bottom,32)
        }.padding(.top,usesWideNavigation ? 0 : ShelfLayout.pageInset)
    }
    @ViewBuilder private func homeRow(_ title:String,works:[Work],personal:Bool = false,recent:Bool = false) -> some View {
        if !works.isEmpty {
            VStack(alignment:.leading,spacing:16) {
                Text(title).font(.title2.bold()).accessibilityAddTraits(.isHeader)
                WorkShelf(works:works,personal:personal,recent:recent,horizontal:true)
            }
        }
    }
    private var records:[TrackingRecord] {
        tracker.filteredRecords(media:libraryMedia,bookFilter:bookFilter,status:libraryFilter,matching:matchingFilter,query:libraryQuery,sort:librarySort)
    }
    private var library: some View {
        VStack(alignment:.leading,spacing:18) {
            if !usesWideNavigation {
                if UIDevice.current.userInterfaceIdiom == .phone {
                    HStack(spacing:12) {
                        phonePlatformLink(.anilist)
                        phonePlatformLink(.trakt)
                    }
                } else {
                    Menu {
                        NavigationLink("AniList 片单") { phonePlatform(.anilist) }
                        NavigationLink("Trakt 片单") { phonePlatform(.trakt) }
                    } label: { Label("平台片单",systemImage:"arrow.down.square") }
                }
            }
            ShelfTabs(values:["影视","书籍"],selection:$libraryMedia,title:{ $0 }).onChange(of:libraryMedia) { _,_ in selectedIDs = []; selecting = false; matchingFilter = "" }
            if libraryMedia == "书籍" { ShelfTabs(values:BookFilter.allCases,selection:$bookFilter,title:{ $0.rawValue }) }
            HStack(spacing:10) {
                Image(systemName:"magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索资料库",text:$libraryQuery)
                if !libraryQuery.isEmpty {
                    Button { libraryQuery = "" } label: { Image(systemName:"xmark.circle.fill").foregroundStyle(.secondary) }
                        .accessibilityLabel("清除搜索")
                }
            }.padding(.horizontal,16).frame(minHeight:48).glassPanel(cornerRadius:16)

            AdaptiveControls {
                Picker("状态",selection:$libraryFilter) { ForEach(["全部","已评分","进行中","计划中","已完成","已暂停","已放弃","重温中"],id:\.self) { Text($0).tag($0) } }.pickerStyle(.menu)
                Menu {
                    Picker("匹配检视",selection:$matchingFilter) {
                        Text("全部作品").tag("")
                        Text("任一平台未匹配").tag("any")
                        if libraryMedia != "书籍" { Text("缺少集对应").tag("missingEpisodes") }
                        ForEach(Catalog.allCases.filter { libraryMedia != "书籍" || ![Catalog.tmdb,.trakt].contains($0) }) { platform in
                            Text("未关联到 " + platform.title).tag(platform.rawValue)
                        }
                    }
                } label: { Label("匹配检视",systemImage:matchingFilter.isEmpty ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill") }
                .onChange(of:matchingFilter) { _,_ in selectedIDs = [] }
                Picker("排序",selection:$librarySort) { ForEach(LibrarySort.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.menu)
            }
            .padding(12).frame(maxWidth:.infinity,alignment:.leading)
            .background(.regularMaterial,in:.rect(cornerRadius:16))
            if !matchingFilter.isEmpty {
                Text(matchingFilter == "missingEpisodes" ? "缺少集对应 · 部分对应视为已对应" : matchingFilter == "any"
                     ? (libraryMedia == "书籍" ? "任一平台未匹配 · 无条目视为已匹配" : "任一平台未匹配 · TMDB、Trakt 无条目仍视为未关联")
                     : "未关联到 " + (Catalog(rawValue:matchingFilter)?.title ?? "") + (["tmdb","trakt"].contains(matchingFilter) ? " · 无条目仍视为未关联" : " · 无条目视为已匹配"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if records.isEmpty {
                if !matchingFilter.isEmpty || !libraryQuery.isEmpty || libraryFilter != "全部" || (libraryMedia == "书籍" && bookFilter != .all) {
                    ContentUnavailableView {
                        Label("没有匹配的作品",systemImage:"magnifyingglass")
                    } description: { Text("调整搜索词或筛选条件。") } actions: {
                        Button("清除搜索与筛选") { libraryQuery = ""; libraryFilter = "全部"; bookFilter = .all; matchingFilter = "" }
                    }
                } else {
                    ContentUnavailableView("暂无\(libraryMedia)作品",systemImage:"books.vertical",description:Text("在发现页添加作品，或从平台片单导入。"))
                }
            }
            HStack {
                Text("\(records.count) 部作品").font(.subheadline).foregroundStyle(.secondary)
                if tracker.translatingTitles || tracker.resolvingBookFormats { ProgressView() }
                if selecting {
                    Button(selectedIDs.isSuperset(of:Set(records.map(\.id))) ? "取消全选" : "全选") {
                        let visible = Set(records.map(\.id))
                        if selectedIDs.isSuperset(of:visible) { selectedIDs.subtract(visible) } else { selectedIDs.formUnion(visible) }
                    }
                    Text("已选择 \(selectedIDs.count) 部").font(.caption)
                }
                Spacer()
                if !records.isEmpty { Button(selecting ? "完成" : "选择") { selecting.toggle(); selectedIDs = [] } }
            }
            if selecting {
                GlassEffectContainer {
                AdaptiveControls {
                    Menu("批量状态") {
                        ForEach(["计划中","进行中","已完成","已暂停","已放弃","重温中"],id:\.self) { status in
                            Button { tracker.updateStatus(selectedIDs,to:status) } label: { StatusMenuLabel(status:status) }
                        }
                    }
                    if let platform = Catalog(rawValue:matchingFilter) {
                        Button("将 " + platform.title + " 设为无条目") {
                            tracker.setNoEntry(selectedIDs.intersection(Set(records.map(\.id))),platform:platform)
                            selectedIDs.formIntersection(Set(records.map(\.id)))
                        }
                    }
                    Button("删除所选",role:.destructive) { deletingIDs = selectedIDs }
                }.buttonStyle(.glass).disabled(selectedIDs.isEmpty)
                }
            }
            WorkShelf(works:records.map(\.work),personal:true,selecting:selecting,selectedIDs:selectedIDs,
                      onToggle:{ work in if !selectedIDs.insert(work.id).inserted { selectedIDs.remove(work.id) } },
                      onSelect:{ work in selecting = true; selectedIDs.insert(work.id) },
                      onDelete:{ work in deletingIDs = [work.id] })
        }
    }
    private func phonePlatformLink(_ source: Catalog) -> some View {
        NavigationLink { phonePlatform(source) } label: {
            VStack(spacing:8) {
                Image("Platform-" + source.rawValue).resizable().scaledToFit()
                    .frame(width:24,height:24).accessibilityHidden(true)
                Text(source.title + " 片单").font(.subheadline.weight(.semibold))
                    .multilineTextAlignment(.center).fixedSize(horizontal:false,vertical:true)
            }
            .frame(maxWidth:.infinity,minHeight:64).padding(12)
            .background(Color(.secondarySystemGroupedBackground),in:.rect(cornerRadius:16))
            .contentShape(.rect(cornerRadius:16))
        }.buttonStyle(.plain).accessibilityIdentifier("library.platform." + source.rawValue)
    }
    private func phonePlatform(_ source:Catalog) -> some View {
        ScrollView { PlatformShelfView(source:source).padding(ShelfLayout.pageInset) }
            .background(Color(.systemGroupedBackground)).navigationTitle(source.title).inlineNavigationTitle()
            .refreshable { await tracker.refreshLibrary() }
    }
}
private struct HomeFeature: View {
    let work:Work
    let open:() -> Void
    @Environment(TrackingStore.self) private var tracker
    @State private var resolvedBackdrop: String?
    private var backdrop: String {
        resolvedBackdrop ?? ArtworkMetadataCache.shared.snapshot.value(for:work.id)?.images.first?.url ?? work.backdrop ?? ""
    }
    var body: some View {
        Button(action:open) {
            MediaHero(work:tracker.display(work),backdrop:backdrop,compact:true)
                .frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.bottom)
                .background { ArtworkAmbientBackground(address:backdrop.isEmpty ? work.image : backdrop) }
                .clipShape(.rect(cornerRadius:24))
                .contentShape(.rect(cornerRadius:24))
        }.buttonStyle(.plain)
            .task(id:work.id) { if backdrop.isEmpty, let artwork = try? await CatalogAPI.shared.artwork(work), !Task.isCancelled { resolvedBackdrop = artwork.images.first?.url }; await tracker.localize(work) }
    }
}

#if targetEnvironment(macCatalyst)
private struct MacWindowConfiguration: UIViewRepresentable {
    func makeUIView(context: Context) -> WindowView { WindowView() }
    func updateUIView(_ view: WindowView, context: Context) { view.configure() }
    final class WindowView: UIView {
        override func didMoveToWindow() { super.didMoveToWindow(); configure() }
        func configure() {
            window?.windowScene?.sizeRestrictions?.minimumSize = CGSize(width:800,height:600)
        }
    }
}
#endif
