import SwiftUI

struct CachedArtwork: View {
    let address: String
    @Environment(\.displayScale) private var displayScale
    var fit = false
    var fullResolution = false
    var progressive = false
    var topBlurExtension: CGFloat? = nil
    var fullyBlurred = false
    var cacheOwner:String?
    var retention:ArtworkRetention = .standard
    var background: Color = Color(.secondarySystemFill)
    var imageCornerRadius: CGFloat = 0
    @State private var image: UIImage?
    @State private var failed = false
    @State private var loadedAddress: String?
    private var displayedImage: UIImage? {
        loadedAddress == address ? image : nil
    }
    var body: some View {
        GeometryReader { proxy in
            ZStack {
                background
                if let image = displayedImage {
                    if fullyBlurred {
                        Image(uiImage:image).resizable().scaledToFill()
                            .frame(width:proxy.size.width,height:proxy.size.height).clipped()
                            .blur(radius:ArtworkTransition.topBlurRadius,opaque:true)
                    }
                    else if let topBlurExtension { TopExtendedArtwork(image:image,extensionHeight:topBlurExtension) }
                    else if progressive { ProgressiveArtwork(image:image) }
                    else {
                        Image(uiImage:image).resizable().aspectRatio(contentMode:fit ? .fit : .fill)
                            .clipShape(.rect(cornerRadius:imageCornerRadius))
                    }
                } else if failed || address.isEmpty {
                    Image(systemName:"photo").font(.title).foregroundStyle(.secondary)
                } else { ProgressView() }
            }.frame(width:proxy.size.width,height:proxy.size.height).clipped()
            .task(id:"\(address)|\((fullResolution ? 0 : PosterCache.pixelBucket(Int(max(proxy.size.width,proxy.size.height) * displayScale))))") {
                failed = false
                guard !address.isEmpty else { return }
                do {
                    let cached = try await PosterCache.shared.image(for:address,owner:cacheOwner,retention:retention,maxPixelSize:(fullResolution ? 0 : PosterCache.pixelBucket(Int(max(proxy.size.width,proxy.size.height) * displayScale))))
                    try Task.checkCancellation()
                    var transaction = Transaction(); transaction.disablesAnimations = true
                    withTransaction(transaction) { image = cached; loadedAddress = address }
                } catch { if !Task.isCancelled { failed = true } }
            }
        }

    }
}
struct MediaHero: View {
    let work: Work
    var backdrop: String
    var showsRating = true
    var compact = false
    var immersive = false
    var topBleed: CGFloat = 0
    var matchingTMDB = false
    var matchWithAI: (() -> Void)? = nil
    var matchManually: (() -> Void)? = nil
    var theme: ArtworkTheme? = nil
    var editTitle: (() -> Void)? = nil
    var findTitle: (() -> Void)? = nil
    var titleBusy = false
    var infuseAction: (() -> Void)? = nil
    @State private var heroWidth: CGFloat = 440
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var palette = ArtworkPalette.neutral
    private var banner: String { backdrop.isEmpty ? (work.backdrop ?? "") : backdrop }
    private var colorSource: String { banner.isEmpty ? work.image : banner }
    private var surface: Color { theme?.canvas.color ?? palette.color(dark:scheme == .dark,intensity:immersive ? 1.25 : 1) }
    var body: some View {
        Group {
            if immersive { layeredHero }
            else if compact { compactHero }
            else { standardHero }
        }
        .animation(.easeInOut(duration:0.5),value:palette)
        .task(id:colorSource) {
            guard theme == nil else { return }
            palette = .neutral
            guard !colorSource.isEmpty, let data = try? await PosterCache.shared.data(for:colorSource,owner:work.id,retention:.preferred) else { return }
            let sampled = await Task.detached(priority:.utility) { ArtworkPalette.extract(data) }.value
            guard !Task.isCancelled else { return }; palette = sampled
        }
    }
    private var layeredHero: some View {
        let phoneBook = UIDevice.current.userInterfaceIdiom == .phone && work.kind == .manga
        let coverWidth: CGFloat = phoneBook ? min(144,max(120,heroWidth * 0.34)) : (UIDevice.current.userInterfaceIdiom == .phone ? (heroWidth < 390 ? 88 : 104) : (heroWidth < 360 ? 104 : 120) * (work.kind == .manga ? 1.4 : 1.2))
        let coverHeight = coverWidth * 1.5
        let coverOverlap = coverHeight * (phoneBook ? 0.30 : 0.5)
        let edge = work.kind == .manga ? (banner.isEmpty ? min(160,max(130,heroWidth * 0.24)) : min(220,max(160,heroWidth * 0.35))) : min(300,max(180,heroWidth * 0.5))
        return VStack(alignment:.leading,spacing:16) {
        HStack(alignment:.top,spacing:16) {
            Poster(work:work).frame(width:coverWidth,height:coverHeight)
                .shadow(color:.black.opacity(scheme == .dark ? 0.48 : 0.26),radius:14,x:0,y:12)
                .shadow(color:.black.opacity(0.12),radius:3,x:0,y:3)
            Group {
                if UIDevice.current.userInterfaceIdiom == .phone {
                    heroTitle
                } else if heroWidth >= 580 {
                    HStack(alignment:.center,spacing:16) {
                        heroTitle.frame(maxWidth:.infinity,alignment:.leading)
                        infuseControl
                    }
                } else {
                    VStack(alignment:.leading,spacing:14) {
                        heroTitle
                        infuseControl.frame(maxWidth:.infinity,alignment:.trailing)
                    }
                }
            }
                // Keep wrapped titles below the artwork and its controls.
                .padding(.top,coverOverlap + 8)
                .frame(maxWidth:.infinity,alignment:.leading)
        }
        if UIDevice.current.userInterfaceIdiom == .phone { infuseControl }
        }
        .padding(.horizontal,ShelfLayout.pageInset)
        .padding(.top,edge - coverOverlap)
        .frame(maxWidth:.infinity,alignment:.leading)
        .overlay(alignment:.topTrailing) {
            matchingControls
                .padding(.trailing,ShelfLayout.pageInset)
                .padding(.top,edge - 44 - 8)
        }
        .background(alignment:.top) {
            GeometryReader { geometry in
                CachedArtwork(address:colorSource,topBlurExtension:topBleed,
                              fullyBlurred:work.kind == .manga && banner.isEmpty,cacheOwner:work.id,retention:.preferred)
                    .frame(width:geometry.size.width,height:edge + topBleed)
                    .background(alignment:.bottom) {
                        Color.black.opacity(scheme == .dark ? 0.20 : 0.12)
                            .frame(height:2).blur(radius:3).offset(y:3)
                    }
                .offset(y:-topBleed)
            }.allowsHitTesting(false).accessibilityHidden(true)
        }
        .onGeometryChange(for:CGFloat.self,of:{ $0.size.width },action:{ heroWidth = $0 })
    }
    @ViewBuilder private var infuseControl: some View {
        if let infuseAction {
            Button(action:infuseAction) {
                Label("Infuse观看",systemImage:"play.fill").font(.subheadline.weight(.semibold))
                    .padding(.horizontal,16)
                    .frame(maxWidth:UIDevice.current.userInterfaceIdiom == .phone ? .infinity : nil,minHeight:UIDevice.current.userInterfaceIdiom == .phone ? 52 : 44)
            }.buttonStyle(.plain).foregroundStyle(theme?.accent.color ?? .primary)
                .glassEffect(.regular.tint((theme?.accent.color ?? .clear).opacity(0.18)).interactive(),in:.capsule)
        }
    }
    @ViewBuilder private var matchingControls: some View {
        if matchWithAI != nil || matchManually != nil {
            GlassEffectContainer(spacing:12) {
                HStack(spacing:12) {
                    if let matchWithAI {
                        Button(action:matchWithAI) {
                            Group {
                                if matchingTMDB { ProgressView().controlSize(.small) }
                                else { Text("AI").font(.system(size:15,weight:.semibold,design:.rounded)) }
                            }.frame(width:44,height:44)
                        }
                        .modifier(HeroGlassControl(opaque:reduceTransparency))
                        .disabled(matchingTMDB)
                        .accessibilityLabel(matchingTMDB ? "正在匹配 TMDB" : "AI 匹配 TMDB")
                        .help("AI 匹配 TMDB")
                    }
                    if let matchManually {
                        Button(action:matchManually) {
                            Image(systemName:"pencil").font(.system(size:17,weight:.medium))
                                .frame(width:44,height:44)
                        }
                        .modifier(HeroGlassControl(opaque:reduceTransparency))
                        .accessibilityLabel("手动匹配 TMDB")
                        .help("手动匹配 TMDB")
                    }
                }
            }
        }
    }
    private var compactHero: some View {
        GeometryReader { proxy in
            let phone = UIDevice.current.userInterfaceIdiom == .phone
            let colors = palette.theme(systemDark:scheme == .dark)
            let coverWidth: CGFloat = phone ? 100 : 64
            let informationWidth = min(360, max(180, proxy.size.width * 0.32))
            ZStack(alignment:.topLeading) {
                // Extend the same artwork under the information, then soften it into its sampled canvas.
                colors.canvas.color
                CachedArtwork(address:colorSource,fullyBlurred:true,cacheOwner:work.id,retention:.preferred)
                    .overlay(colors.canvas.color.opacity(0.82))
                if phone {
                    CachedArtwork(address:colorSource,cacheOwner:work.id,retention:.preferred)
                        .frame(height:proxy.size.height * 0.68)
                        .mask {
                            LinearGradient(stops:[.init(color:.white,location:0),.init(color:.white,location:0.65),.init(color:.clear,location:1)],startPoint:.top,endPoint:.bottom)
                        }
                    HStack(alignment:.bottom,spacing:16) {
                        Poster(work:work).frame(width:coverWidth,height:coverWidth * 1.5)
                            .shadow(color:.black.opacity(0.20),radius:10,y:5)
                        heroTitle
                            .frame(maxWidth:.infinity,alignment:.leading)
                    }
                    .padding(20)
                    .frame(maxHeight:.infinity,alignment:.bottom)
                } else {
                    CachedArtwork(address:colorSource,cacheOwner:work.id,retention:.preferred)
                        .frame(width:proxy.size.width - informationWidth * 0.65,height:proxy.size.height)
                        .mask {
                            LinearGradient(stops:[.init(color:.clear,location:0),.init(color:.white,location:0.28),.init(color:.white,location:1)],startPoint:.leading,endPoint:.trailing)
                        }
                        .frame(maxWidth:.infinity,alignment:.trailing)
                    VStack(alignment:.leading,spacing:16) {
                        Poster(work:work).frame(width:coverWidth,height:coverWidth * 1.5)
                        heroTitle
                    }
                    .padding(24)
                    .frame(width:informationWidth,height:proxy.size.height,alignment:.leading)
                }
            }
            .environment(\.colorScheme,palette.usesDarkAppearance(systemDark:scheme == .dark) ? .dark : .light)
            .frame(width:proxy.size.width,height:proxy.size.height)
            .clipped()
        }
    }

    private var standardHero: some View {
        ZStack(alignment:.bottomLeading) {
            GeometryReader { proxy in
                ZStack {
                    surface
                    if !banner.isEmpty { CachedArtwork(address:banner,progressive:immersive,cacheOwner:work.id,retention:.preferred) }
                    else if !work.image.isEmpty {
                        CachedArtwork(address:work.image,cacheOwner:work.id,retention:.preferred).scaleEffect(1.35).blur(radius:48,opaque:true)
                        Color.black.opacity(0.38)
                    }
                    LinearGradient(stops:[.init(color:.clear,location:0),.init(color:surface.opacity(0.25),location:0.48),.init(color:surface.opacity(0.85),location:0.82),.init(color:surface,location:1)],startPoint:.top,endPoint:.bottom)
                }.frame(width:proxy.size.width,height:proxy.size.height).clipped()
            }
            ViewThatFits(in:.horizontal) {
                HStack(alignment:.bottom,spacing:16) {
                    heroCover
                    heroTitle.frame(minWidth:140,maxWidth:.infinity,alignment:.leading)
                }
                VStack(alignment:.leading,spacing:12) { heroCover; heroTitle }
            }.padding(ShelfLayout.pageInset)
                .padding(.top,banner.isEmpty ? 16 : 100)
        }.frame(minHeight:banner.isEmpty ? 200 : 300).clipped()

    }
    private var heroCover: some View {
        Poster(work:work).frame(width:88,height:132).shadow(color:.black.opacity(scheme == .dark ? 0.3 : 0.14),radius:16,y:8)
    }
    private var heroTitle: some View {
        VStack(alignment:.leading,spacing:8) {
            if UIDevice.current.userInterfaceIdiom == .phone {
                Text(work.title).font(.title2.bold()).lineLimit(compact && UIDevice.current.userInterfaceIdiom == .phone ? 1 : (compact ? 3 : nil)).truncationMode(.tail).fixedSize(horizontal:false,vertical:true)
                if editTitle != nil || findTitle != nil {
                    HStack(spacing:8) {
                        if let editTitle { Button(action:editTitle) { Image(systemName:"pencil").frame(width:44,height:44) }.accessibilityLabel("编辑中文名") }
                        if let findTitle { Button(action:findTitle) { Image(systemName:"sparkles").frame(width:44,height:44) }.disabled(titleBusy).accessibilityLabel("AI 查找中文名") }
                    }.buttonStyle(.plain)
                }
            } else {
            HStack(alignment:.firstTextBaseline,spacing:4) {
                Text(work.title).font(.title2.bold()).lineLimit(compact && UIDevice.current.userInterfaceIdiom == .phone ? 1 : (compact ? 3 : nil)).truncationMode(.tail).fixedSize(horizontal:false,vertical:true)
                if let editTitle { Button(action:editTitle) { Image(systemName:"pencil").font(.system(size:15)).frame(width:32,height:44) }.buttonStyle(.plain).accessibilityLabel("编辑中文名") }
                if let findTitle { Button(action:findTitle) { Image(systemName:"sparkles").font(.system(size:15)).frame(width:32,height:44) }.buttonStyle(.plain).disabled(titleBusy).accessibilityLabel("AI 查找中文名") }
            }
            }
            if !work.original.isEmpty && work.original != work.title { Text(work.original).font(.caption).foregroundStyle(theme?.secondary.color ?? Color.secondary).lineLimit(compact ? 1 : 2) }
            Text([work.kind.title,work.year].filter { !$0.isEmpty }.joined(separator:" · ")).font(.subheadline).foregroundStyle(theme?.secondary.color ?? Color.secondary)
            if showsRating, let rating = work.rating { Label("\(work.source.title) \((rating * 10).formatted(.number.precision(.fractionLength(0...1))))",systemImage:"star.fill").font(.caption.bold()) }
        }.foregroundStyle(.primary)
    }

}

private struct HeroGlassControl: ViewModifier {
    let opaque: Bool
    func body(content: Content) -> some View {
        if opaque {
            content.buttonStyle(.plain).foregroundStyle(.primary)
                .background(Color(.secondarySystemBackground),in:Circle())
                .contentShape(Circle())
        } else {
            content.buttonStyle(.plain).foregroundStyle(.primary)
                .glassEffect(.regular.interactive(),in:Circle())
                .contentShape(Circle())
        }
    }
}
// Native sheets own their material, shadow, safe areas and presentation transition.
private struct BrowserThemeKey: EnvironmentKey {
    static let defaultValue: ArtworkTheme? = nil
}
extension EnvironmentValues {
    var browserTheme: ArtworkTheme? {
        get { self[BrowserThemeKey.self] }
        set { self[BrowserThemeKey.self] = newValue }
    }
}
struct MediaBrowserTheme: ViewModifier {
    let theme: ArtworkTheme
    func body(content: Content) -> some View {
        content
            .environment(\.browserTheme,theme)
            .environment(\.colorScheme,theme.dark ? .dark : .light)
            .preferredColorScheme(theme.dark ? .dark : .light)
            .foregroundStyle(theme.primary.color,theme.secondary.color)
            .tint(theme.accent.color)
            .accentColor(theme.accent.color)
            .presentationBackground {
                Rectangle().fill(.ultraThinMaterial)
                    .overlay(theme.canvas.color.opacity(0.08))
                    .environment(\.colorScheme,theme.dark ? .dark : .light)
            }
    }
}

private enum MediaBrowserLayout {
    static let inset: CGFloat = 20
    static let contentWidth: CGFloat = 800
    static let imageRadius: CGFloat = 10
}

private struct MediaBrowserPanel<Item: Identifiable, Page: View>: View where Item.ID == String {
    let title: String
    let items: [Item]
    let previousLabel: String
    let nextLabel: String
    let imageCacheOwner: String?
    @ViewBuilder let page: (Item, CGSize, @escaping (GalleryImage) -> Void) -> Page
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var selection: String?
    @Environment(\.browserTheme) private var theme
    @State private var fullScreenImage: GalleryImage?
    @Namespace private var imageTransition

    init(title: String, items: [Item], initialID: String,
         previousLabel: String, nextLabel: String, imageCacheOwner:String? = nil,
         @ViewBuilder page: @escaping (Item, CGSize, @escaping (GalleryImage) -> Void) -> Page) {
        self.title = title; self.items = items
        self.previousLabel = previousLabel; self.nextLabel = nextLabel
        self.imageCacheOwner = imageCacheOwner
        self.page = page
        _selection = State(initialValue:items.first(where:{ $0.id == initialID })?.id ?? items.first?.id)
    }

    private var index: Int { items.firstIndex(where:{ $0.id == selection }) ?? 0 }

    var body: some View {
        panel
            .frame(idealWidth:860,idealHeight:760)
            .presentationSizing(.form)
            .presentationDetents([.fraction(0.9),.large])
            .presentationDragIndicator(.visible)
            .fullScreenCover(item:$fullScreenImage) { image in
                FullScreenArtwork(address:image.url,caption:image.caption,cacheOwner:imageCacheOwner)
                    .navigationTransition(.zoom(sourceID:image.url,in:imageTransition))
            }
        .onChange(of:items.map(\.id)) { _,ids in
            if !ids.contains(selection ?? "") { selection = ids.first }
        }
        .accessibilityAction(named:Text(previousLabel)) { move(-1) }
        .accessibilityAction(named:Text(nextLabel)) { move(1) }
    }

    private var panel: some View {
        VStack(spacing:0) {
            HStack(spacing:16) {
                Text(title).font(.headline).accessibilityAddTraits(.isHeader)
                Spacer(minLength:12)
                Button("完成") { dismiss() }
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(minWidth:44,minHeight:44)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal,MediaBrowserLayout.inset)
            .padding(.top,12)
            .padding(.bottom,4)

            Divider().padding(.horizontal,MediaBrowserLayout.inset)

            if items.isEmpty {
                ContentUnavailableView("暂无内容",systemImage:"photo.on.rectangle")
                    .frame(maxWidth:.infinity,maxHeight:.infinity)
            } else {
                GeometryReader { geometry in
                    ScrollView(.horizontal) {
                        LazyHStack(spacing:0) {
                            ForEach(Array(items.enumerated()),id:\.element.id) { number,item in
                                ScrollView(.vertical) {
                                    if abs(number - index) <= 1 {
                                        page(item,geometry.size) { fullScreenImage = $0 }
                                            .environment(\.artworkTransition,imageTransition)
                                            .padding(MediaBrowserLayout.inset)
                                            .frame(maxWidth:MediaBrowserLayout.contentWidth,alignment:.leading)
                                            .frame(maxWidth:.infinity,alignment:.top)
                                    }
                                }
                                .scrollIndicators(.hidden)
                                .frame(width:geometry.size.width,height:geometry.size.height)
                                .contentShape(.rect)
                                .clipped()
                                .id(item.id)
                                .accessibilityHidden(number != index)
                            }
                        }.scrollTargetLayout()
                    }
                    .scrollTargetBehavior(.paging)
                    .scrollPosition(id:$selection)
                    .scrollIndicators(.hidden)
                    .contentShape(.rect)
                    .clipped()
                }
            }

            Divider().padding(.horizontal,MediaBrowserLayout.inset)

            HStack(spacing:24) {
                Button { move(-1) } label: {
                    Image(systemName:"chevron.left").frame(width:44,height:44).contentShape(.rect)
                }
                .disabled(items.isEmpty || index == 0)
                .accessibilityLabel(previousLabel)
                .keyboardShortcut(.leftArrow,modifiers:[])
                Text("\(items.isEmpty ? 0 : index + 1) / \(items.count)")
                    .font(.subheadline.monospacedDigit()).foregroundStyle(theme?.secondary.color ?? .secondary)
                    .frame(minWidth:72)
                    .accessibilityLabel("共 \(items.count) 项，当前第 \(items.isEmpty ? 0 : index + 1) 项")
                Button { move(1) } label: {
                    Image(systemName:"chevron.right").frame(width:44,height:44).contentShape(.rect)
                }
                .disabled(index + 1 >= items.count)
                .accessibilityLabel(nextLabel)
                .keyboardShortcut(.rightArrow,modifiers:[])
            }
            .font(.body.weight(.medium))
            .frame(maxWidth:.infinity)
            .padding(.vertical,8)
        }
        .buttonStyle(.plain)
        .foregroundStyle(theme?.primary.color ?? .primary,theme?.secondary.color ?? .secondary)
        .frame(maxWidth:.infinity,maxHeight:.infinity)


    }

    private func move(_ offset: Int) {
        guard items.indices.contains(index + offset) else { return }
        withAnimation(reduceMotion ? nil : .easeInOut(duration:0.25)) {
            selection = items[index + offset].id
        }
    }
}

struct GalleryViewer: View {
    let images: [GalleryImage]
    let initial: String
    var cacheOwner:String?

    var body: some View {
        MediaBrowserPanel(title:"剧照",items:images,initialID:initial,
                          previousLabel:"上一张",nextLabel:"下一张",imageCacheOwner:cacheOwner) { image,size,showImage in
            VStack(alignment:.leading,spacing:20) {
                BrowserArtworkPreview(address:image.url,caption:image.caption.isEmpty ? "剧照" : image.caption,cacheOwner:cacheOwner,showImage:showImage)
                    .frame(height:max(180,size.height - 2 * MediaBrowserLayout.inset - 64))
                if !image.caption.isEmpty {
                    Text(image.caption).font(.subheadline).foregroundStyle(.secondary)
                        .fixedSize(horizontal:false,vertical:true).textSelection(.enabled)
                }
            }
        }
    }
}

private struct ArtworkTransitionKey: EnvironmentKey { static let defaultValue: Namespace.ID? = nil }
private extension EnvironmentValues {
    var artworkTransition: Namespace.ID? {
        get { self[ArtworkTransitionKey.self] }
        set { self[ArtworkTransitionKey.self] = newValue }
    }
}
private struct BrowserArtworkPreview: View {
    let address: String
    let caption: String
    var cacheOwner:String?
    let showImage: (GalleryImage) -> Void
    @Environment(\.artworkTransition) private var transition

    var body: some View {
        Button { showImage(GalleryImage(url:address,caption:caption)) } label: {
            CachedArtwork(address:address,fit:true,fullResolution:true,cacheOwner:cacheOwner,background:.clear,
                          imageCornerRadius:MediaBrowserLayout.imageRadius)
        }
        .buttonStyle(.plain)
        .modifier(WorkTransitionSource(id:address,namespace:transition))
        .accessibilityLabel(caption)
        .accessibilityHint("点击全屏查看图片")
    }
}

private struct FullScreenArtwork: View {
    let address: String
    let caption: String
    var cacheOwner:String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            ZoomableArtwork(address:address,cacheOwner:cacheOwner)
                .accessibilityLabel(caption)
                .accessibilityHint("双指缩放，双击放大或还原")
        }
        .overlay(alignment:.topTrailing) {
            Button { dismiss() } label: {
                Image(systemName:"xmark").font(.body.weight(.semibold))
                    .frame(width:44,height:44)
            }
            .buttonStyle(.glass)
            .accessibilityLabel("关闭全屏图片")
            .keyboardShortcut(.cancelAction)
            .padding(16)
        }
        .environment(\.colorScheme,.dark)
        .presentationBackground(.black)
    }
}

private struct ZoomableArtwork: View {
    let address: String
    var cacheOwner:String?
    @State private var scale: CGFloat = 1
    @GestureState private var magnification: CGFloat = 1
    @State private var offset: CGSize = .zero
    @GestureState private var drag: CGSize = .zero
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        GeometryReader { geometry in
            let zoom = min(4,max(1,scale * magnification))
            CachedArtwork(address:address,fit:true,fullResolution:true,cacheOwner:cacheOwner,background:.clear)
                .scaleEffect(zoom)
                .offset(x:clamp(offset.width + drag.width,limit:geometry.size.width * (zoom-1)/2),
                        y:clamp(offset.height + drag.height,limit:geometry.size.height * (zoom-1)/2))
                .gesture(MagnifyGesture().updating($magnification) { value,state,_ in state = value.magnification }
                    .onEnded { scale = min(4,max(1,scale * $0.magnification)); if scale == 1 { offset = .zero } })
                .simultaneousGesture(DragGesture().updating($drag) { value,state,_ in if scale > 1 { state = value.translation } }
                    .onEnded { value in
                        if scale <= 1 {
                            if value.translation.height > 100 && abs(value.translation.height) > abs(value.translation.width) * 1.5 { dismiss() }
                            return
                        }
                        offset = CGSize(width:clamp(offset.width + value.translation.width,limit:geometry.size.width * (scale-1)/2),
                                        height:clamp(offset.height + value.translation.height,limit:geometry.size.height * (scale-1)/2))
                    })
                .onTapGesture(count:2) { withAnimation { scale = scale > 1 ? 1 : 2; offset = .zero } }
                .clipped()
        }
        #if targetEnvironment(macCatalyst)
        .overlay(alignment:.bottom) {
            HStack {
                Button { scale = max(1,scale - 0.5); if scale == 1 { offset = .zero } } label: { Image(systemName:"minus.magnifyingglass") }
                    .accessibilityLabel("缩小图片").disabled(scale <= 1)
                Button("还原") { scale = 1; offset = .zero }
                Button { scale = min(4,scale + 0.5) } label: { Image(systemName:"plus.magnifyingglass") }
                    .accessibilityLabel("放大图片").disabled(scale >= 4)
            }.buttonStyle(.glass).padding(20)
        }
        #endif
    }
    private func clamp(_ value:CGFloat,limit:CGFloat) -> CGFloat { min(limit,max(-limit,value)) }
}

struct EpisodeStrip: View {
    let episodes: [MediaEpisode]
    var cacheOwner:String?
    var transitionNamespace: Namespace.ID
    var play: ((MediaEpisode) -> Void)? = nil
    let select: (MediaEpisode) -> Void
    @State private var window: Range<Int> = 0..<0
    @State private var width: CGFloat = 0
    @State private var offset: CGFloat = 0
    @AppStorage(UIDevice.current.userInterfaceIdiom == .phone ? "shelf.phoneEpisodeWidth" : "shelf.episodeWidth")
    private var preferredWidth: Double = UIDevice.current.userInterfaceIdiom == .phone ? 190 : 220
    @GestureState private var pinch: CGFloat = 1
    private var cardWidth: CGFloat {
        let desired = min(440,max(120,preferredWidth * pinch))
        guard width > 0 else { return desired }
        if UIDevice.current.userInterfaceIdiom == .phone { return min(desired,width) }
        let count = max(1,Int((width + 14) / (desired + 14)))
        return (width - CGFloat(count - 1) * 14) / CGFloat(count)
    }
    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment:.top,spacing:14) {
                ForEach(Array(episodes.enumerated()),id:\.element.id) { index,episode in
                    Button { select(episode) } label: {
                        VStack(alignment:.leading,spacing:6) {
                            if window.contains(index) {
                                CachedArtwork(address:episode.image,cacheOwner:cacheOwner).frame(width:cardWidth,height:cardWidth * 9 / 16).clipShape(.rect(cornerRadius:12))
                                Text("第 \(episode.number) 集").font(.caption).foregroundStyle(.secondary)
                                Text(episode.title).font(.subheadline.weight(.semibold)).lineLimit(2).foregroundStyle(.primary)
                                Text(MediaLanguage.plainText(episode.overview)).font(.subheadline).lineLimit(3).foregroundStyle(.secondary)
                            } else {
                                RoundedRectangle(cornerRadius:12).fill(.quaternary).frame(width:cardWidth,height:cardWidth * 9 / 16)
                                Color.clear.frame(height:110)
                            }
                        }.frame(width:cardWidth,alignment:.topLeading).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                        .overlay(alignment:.topTrailing) {
                            if let play, window.contains(index) {
                                Button { play(episode) } label: {
                                    Image(systemName:"play.fill").font(.system(size:14,weight:.semibold)).frame(width:36,height:36)
                                        .glassEffect(.regular.interactive(),in:.circle)
                                        .frame(width:44,height:44)
                                }.buttonStyle(.plain).foregroundStyle(.primary)
                                    .offset(x:-2,y:cardWidth * 9 / 16 - 46)
                                    .accessibilityLabel("在 Infuse 中打开第 \(episode.number) 集")
                            }
                        }
                        .id(episode.id)
                        .matchedTransitionSource(id:episode.id,in:transitionNamespace)
                        .accessibilityLabel("第 \(episode.number) 集，\(episode.title)")
                }
            }.padding(.bottom,20).scrollTargetLayout()
        }
        .simultaneousGesture(MagnifyGesture().updating($pinch) { value,state,_ in state = value.magnification }
            .onEnded { preferredWidth = min(440,max(120,preferredWidth * $0.magnification)) })
        #if targetEnvironment(macCatalyst)
        .safeAreaInset(edge:.bottom,alignment:.trailing,spacing:0) {
            HStack {
                Button { preferredWidth = max(120,preferredWidth - 24) } label: { Image(systemName:"minus.magnifyingglass") }
                    .accessibilityLabel("缩小剧集封面").disabled(preferredWidth <= 120)
                Button { preferredWidth = min(440,preferredWidth + 24) } label: { Image(systemName:"plus.magnifyingglass") }
                    .accessibilityLabel("放大剧集封面").disabled(preferredWidth >= 440)
            }.buttonStyle(.bordered)
        }
        #endif
        .onChange(of:cardWidth) { _,_ in updateWindow() }
        .scrollIndicators(.visible)
        .onGeometryChange(for:CGFloat.self,of:{ $0.size.width }) { value in
            width = value; updateWindow()
        }
        .onScrollGeometryChange(for:CGFloat.self,of:{ $0.contentOffset.x }) { _,value in
            offset = value; updateWindow()
        }
        .onChange(of:episodes) { _,_ in updateWindow() }
        .task(id:window) {
            // Scroll gestures cancel stale prefetch work before the next request.
            do { try await Task.sleep(for:.milliseconds(100)) } catch { return }
            for index in window where episodes.indices.contains(index) {
                guard !Task.isCancelled else { return }
                let address = episodes[index].image
                if !address.isEmpty { _ = try? await PosterCache.shared.data(for:address,owner:cacheOwner) }
            }
        }
    }
    private func updateWindow() { window = EpisodeWindow.range(offset:Double(offset),viewport:Double(width),count:episodes.count,cardWidth:Double(cardWidth)) }
}

struct EpisodeGallery: View {
    @Environment(\.browserTheme) private var theme
    let episodes: [MediaEpisode]
    let initialID: String
    var cacheOwner:String?
    var play: ((MediaEpisode) -> Void)? = nil

    var body: some View {
        MediaBrowserPanel(title:"剧集详情",items:episodes,initialID:initialID,
                          previousLabel:"上一集",nextLabel:"下一集",imageCacheOwner:cacheOwner) { episode,_,showImage in
            VStack(alignment:.leading,spacing:20) {
                BrowserArtworkPreview(address:episode.image,caption:"第 \(episode.number) 集剧照",cacheOwner:cacheOwner,showImage:showImage)
                    .aspectRatio(16/9,contentMode:.fit)
                (UIDevice.current.userInterfaceIdiom == .phone ? AnyLayout(VStackLayout(alignment:.leading,spacing:16)) : AnyLayout(HStackLayout(alignment:.center,spacing:16))) {
                VStack(alignment:.leading,spacing:8) {
                    Text(String(format:"S%02dE%02d",episode.season,episode.number))
                        .font(.subheadline).foregroundStyle(theme?.secondary.color ?? .secondary)
                    Text(episode.title).font(.title2.bold())
                        .fixedSize(horizontal:false,vertical:true)
                        .accessibilityAddTraits(.isHeader)
                }
                if UIDevice.current.userInterfaceIdiom != .phone { Spacer(minLength:0) }
                if let play {
                    Button { play(episode) } label: {
                        Label("在 Infuse 中打开",systemImage:"play.fill").font(.headline).padding(.horizontal,20).frame(maxWidth:UIDevice.current.userInterfaceIdiom == .phone ? .infinity : nil,minHeight:52)
                    }.buttonStyle(.plain).glassEffect(.regular.interactive(),in:.rect(cornerRadius:18)).fixedSize(horizontal:UIDevice.current.userInterfaceIdiom != .phone,vertical:true)
                }
                }
                Text(episode.overview.isEmpty ? "暂无简介" : MediaLanguage.plainText(episode.overview))
                    .font(.body).lineSpacing(5)
                    .fixedSize(horizontal:false,vertical:true).textSelection(.enabled)
            }
        }
    }
}
