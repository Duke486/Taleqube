import SwiftUI
import UIKit

extension Media {
    var catalogWork: Work {
        Work(source:.anilist,remoteID:String(id),kind:type == .manga ? .manga : format == "MOVIE" ? .movie : .tv,
             title:title.display,original:title.native ?? "",overview:description ?? "",image:coverURL?.absoluteString ?? "",
             year:seasonYear.map(String.init) ?? "",rating:averageScore.map { Double($0)/10 },url:siteUrl ?? "",
             backdrop:bannerImage,format:format,episodeCount:episodes,volumeCount:volumes,chapterCount:chapters)
    }
}

struct BookDetailSections: View {
    @Environment(\.browserTheme) private var theme
    let details: BookDetails
    let owner: String
    let work: Work
    @State private var peopleSheet: BookPeopleRoute?
    @State private var person: BookPersonRoute?
    @State private var related: Work?
    @State private var filter = "全部"
    @Namespace private var transition
    private var relations: [BookDetails.Relation] {
        var seen = Set<Int>()
        return (details.relations?.edges ?? []).filter { seen.insert($0.id).inserted && (filter == "全部" || (filter == "书籍" ? $0.node.type == .manga : $0.node.type == .anime)) }
    }
    var body: some View {
        VStack(alignment:.leading,spacing:24) {
            if let genres = details.genres, !genres.isEmpty {
                Text(genres.prefix(5).joined(separator:" · ")).font(.subheadline).foregroundStyle(.secondary)
            }
            if let characters = details.characters, !characters.edges.isEmpty {
                HStack {
                    Text("角色").font(.headline); Spacer()
                    Button("全部角色") { peopleSheet = BookPeopleRoute(staff:false) }.font(.subheadline)
                }
                ScrollView(.horizontal) {
                    LazyHStack(alignment:.top,spacing:12) {
                        ForEach(characters.edges.prefix(12)) { edge in
                            Button { person = BookPersonRoute(edge:edge,staff:false) } label: {
                                VStack(alignment:.leading,spacing:6) {
                                    BookPersonImage(person:edge.node,owner:owner).frame(width:96,height:128).clipShape(.rect(cornerRadius:12))
                                    Text(edge.node.displayName).font(.subheadline).lineLimit(2)
                                    Text(edge.roleTitle).font(.caption).foregroundStyle(.secondary)
                                }.frame(width:96,alignment:.leading)
                            }.buttonStyle(.plain).matchedTransitionSource(id:edge.id,in:transition)
                        }
                    }
                }.scrollIndicators(.hidden)
            }
            if let staff = details.staff, !staff.edges.isEmpty {
                HStack {
                    Text("创作者").font(.headline); Spacer()
                    Button("全部创作者") { peopleSheet = BookPeopleRoute(staff:true) }.font(.subheadline)
                }
                LazyVGrid(columns:[GridItem(.adaptive(minimum:220),alignment:.leading)],alignment:.leading,spacing:16) {
                    ForEach(staff.edges.prefix(4)) { edge in
                        Button { person = BookPersonRoute(edge:edge,staff:true) } label: { BookPersonRow(edge:edge,owner:owner) }
                            .buttonStyle(.plain).matchedTransitionSource(id:edge.id,in:transition)
                    }
                }
            }
            if !(details.relations?.edges.isEmpty ?? true) {
                Text("关联作品").font(.headline)
                if (details.relations?.edges.count ?? 0) > 6 {
                    Picker("关联类型",selection:$filter) { ForEach(["全部","书籍","动画"],id:\.self) { Text($0).tag($0) } }.pickerStyle(.segmented)
                }
                ScrollView(.horizontal) {
                    LazyHStack(alignment:.top,spacing:12) {
                        ForEach(relations) { relation in
                            Button { related = relation.node.catalogWork } label: {
                                VStack(alignment:.leading,spacing:6) {
                                    Poster(work:relation.node.catalogWork).frame(width:120,height:180)
                                    Text(relation.title).font(.caption).foregroundStyle(.secondary)
                                    Text(relation.node.title.display).font(.subheadline).lineLimit(2)
                                }.frame(width:120,alignment:.leading)
                            }.buttonStyle(.plain).matchedTransitionSource(id:relation.node.catalogWork.id,in:transition)
                        }
                    }
                }.scrollIndicators(.hidden)
            }
            VStack(alignment:.leading,spacing:12) {
                Text("书籍资料").font(.headline)
                if let date = details.startDate?.display, !date.isEmpty { LabeledContent("开始发行",value:date) }
                if let date = details.endDate?.display, !date.isEmpty { LabeledContent("完结日期",value:date) }
                if let n = details.volumes, n > 0 { LabeledContent("总卷数",value:"\(n) 卷") }
                if let n = details.chapters, n > 0 { LabeledContent("总话数",value:"\(n) 话") }
                if let name = details.title.native { LabeledContent("原名",value:name) }
                if let names = details.synonyms, !names.isEmpty {
                    DisclosureGroup("别名") { Text(names.joined(separator:"\n")).frame(maxWidth:.infinity,alignment:.leading).textSelection(.enabled) }
                }
            }.font(.subheadline)
            if let links = details.externalLinks, !links.isEmpty {
                VStack(alignment:.leading,spacing:12) {
                    Text("外部链接").font(.headline)
                    PlatformRatingLayout(spacing:8) {
                    ForEach(links) { link in
                        if let url = link.url.flatMap(URL.init(string:)), ["http","https"].contains(url.scheme ?? "") {
                            Link(destination:url) {
                                Label(link.site,systemImage:"arrow.up.right").font(.caption.weight(.medium))
                                    .foregroundStyle(theme?.accent.color ?? .accentColor)
                                    .padding(.horizontal,10).padding(.vertical,7)
                                    .background(theme?.raised.color ?? Color.secondary.opacity(0.12),in:Capsule())
                            }.buttonStyle(.plain)
                        }
                    }
                    }
                }
            }
        }
        .sheet(item:$peopleSheet) { route in
            BookPeopleView(id:details.id,staff:route.staff,initial:route.staff ? details.staff : details.characters,owner:owner,work:work)
        }
        .sheet(item:$person) { route in
            BookPersonView(route:route,owner:owner,work:work).navigationTransition(.zoom(sourceID:route.edge.id,in:transition))
        }
        .sheet(item:$related) { target in
            WorkSheet(work:target).frame(idealWidth:700,idealHeight:1100).presentationSizing(.fitted).presentationDetents([.large]).navigationTransition(.zoom(sourceID:target.id,in:transition))
        }
    }
}

private struct BookPeopleRoute: Identifiable { let staff:Bool; var id:Bool { staff } }
private struct BookPersonRoute: Identifiable { let edge:BookDetails.PersonEdge; let staff:Bool; var id:String { "\(staff):\(edge.id)" } }
private struct BookPersonImage: View {
    let person:BookDetails.Person; let owner:String
    var body:some View {
        if let address = person.image?.large, !address.isEmpty {
            CachedArtwork(address:address,cacheOwner:owner)
        } else {
            Rectangle().fill(.quaternary).overlay { Image(systemName:"person.crop.rectangle").font(.title).foregroundStyle(.secondary) }
        }
    }
}
private struct BookPersonRow: View {
    let edge:BookDetails.PersonEdge; let owner:String
    var body:some View {
        HStack(spacing:12) {
            BookPersonImage(person:edge.node,owner:owner).frame(width:52,height:64).clipShape(.rect(cornerRadius:10))
            VStack(alignment:.leading,spacing:4) {
                Text(edge.node.displayName).font(.subheadline.weight(.medium))
                Text(edge.roleTitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength:0)
        }.frame(maxWidth:.infinity,alignment:.leading)
    }
}
private struct BookPeopleView: View {
    let id:Int; let staff:Bool; let initial:BookDetails.People?; let owner:String; let work:Work
    @Environment(\.dismiss) private var dismiss
    @State private var edges:[BookDetails.PersonEdge] = []
    @State private var page = 1
    @State private var more = false
    @State private var loading = false
    @State private var error:String?
    @State private var selected:BookPersonRoute?
    @Namespace private var transition
    var body:some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns:[GridItem(.adaptive(minimum:220),alignment:.leading)],alignment:.leading,spacing:16) {
                    ForEach(edges) { edge in
                        Button { selected = BookPersonRoute(edge:edge,staff:staff) } label: { BookPersonRow(edge:edge,owner:owner) }
                            .buttonStyle(.plain).matchedTransitionSource(id:edge.id,in:transition)
                    }
                }
                if let error { Text(error).foregroundStyle(.red).font(.caption) }
                if more { Button(loading ? "加载中…" : "加载更多") { Task { await load() } }.disabled(loading).padding() }
            }.padding(20).navigationTitle(staff ? "创作者" : "角色").inlineNavigationTitle()
                .toolbar { ToolbarItem(placement:.confirmationAction) { Button("完成") { dismiss() } } }
        }.onAppear { if edges.isEmpty { edges = initial?.edges ?? []; more = initial?.pageInfo?.hasNextPage == true } }
            .sheet(item:$selected) { route in BookPersonView(route:route,owner:owner,work:work).navigationTransition(.zoom(sourceID:route.edge.id,in:transition)) }
            .presentationDetents([.large])
    }
    private func load() async {
        loading = true; error = nil; defer { loading = false }
        do {
            var result = try await AniListAPI.shared.bookPeople(id:id,staff:staff,page:page+1)
            do { result = try await Intelligence.shared.translatedPeople(result,work:work) } catch is CancellationError { throw CancellationError() } catch { self.error = "资料翻译失败：" + error.localizedDescription }
            try Task.checkCancellation()
            var seen = Set(edges.map(\.id)); edges += result.edges.filter { seen.insert($0.id).inserted }
            page += 1; more = result.pageInfo?.hasNextPage == true
        } catch { self.error = error.localizedDescription }
    }
}
private struct BookPersonView: View {
    let route:BookPersonRoute; let owner:String; let work:Work
    @Environment(\.dismiss) private var dismiss
    @State private var translatedEdge:BookDetails.PersonEdge?
    @State private var works:[Media] = []
    @State private var page = 0
    @State private var more = true
    @State private var loading = false
    @State private var error:String?
    @State private var selected:Work?
    @Namespace private var transition
    var body:some View {
        let edge = translatedEdge ?? route.edge
        NavigationStack {
            ScrollView {
                VStack(alignment:.leading,spacing:20) {
                    HStack(alignment:.top,spacing:16) {
                        BookPersonImage(person:edge.node,owner:owner).frame(width:120,height:160).clipShape(.rect(cornerRadius:14))
                        VStack(alignment:.leading,spacing:8) {
                            Text(edge.node.displayName).font(.title2.bold())
                            Text(edge.roleTitle).foregroundStyle(.secondary)
                        }
                    }
                    if let description = edge.node.description, !description.isEmpty {
                        Text(MediaLanguage.plainText(description.replacingOccurrences(of:"~!",with:"").replacingOccurrences(of:"!~",with:""))).textSelection(.enabled)
                    }
                    if !works.isEmpty {
                        Text(route.staff ? "参与作品" : "登场作品").font(.headline)
                        LazyVGrid(columns:[GridItem(.adaptive(minimum:120),alignment:.top)],alignment:.leading,spacing:16) {
                            ForEach(works) { media in
                                Button { selected = media.catalogWork } label: {
                                    VStack(alignment:.leading,spacing:6) { Poster(work:media.catalogWork).aspectRatio(2/3,contentMode:.fit); Text(media.title.display).font(.subheadline).lineLimit(2) }
                                }.buttonStyle(.plain).matchedTransitionSource(id:media.catalogWork.id,in:transition)
                            }
                        }
                    }
                    if let error { Text(error).font(.caption).foregroundStyle(.red) }
                    if more { Button(loading ? "加载中…" : error == nil ? "加载更多作品" : "重试") { Task { await load() } }.disabled(loading) }
                }.padding(20)
            }.navigationTitle(route.staff ? "创作者资料" : "角色资料").inlineNavigationTitle()
                .toolbar { ToolbarItem(placement:.confirmationAction) { Button("完成") { dismiss() } } }
        }.task {
            do {
                let people = try await Intelligence.shared.translatedPeople(.init(edges:[route.edge]),work:work)
                try Task.checkCancellation(); translatedEdge = people.edges.first
            } catch is CancellationError { return } catch { self.error = error.localizedDescription }
            if page == 0 { await load() }
        }
            .sheet(item:$selected) { target in WorkSheet(work:target).frame(idealWidth:700,idealHeight:1100).presentationSizing(.fitted).presentationDetents([.large]).navigationTransition(.zoom(sourceID:target.id,in:transition)) }
            .presentationDetents([.large])
    }
    private func load() async {
        guard !loading else { return }; loading = true; error = nil; defer { loading = false }
        do {
            let result = try await AniListAPI.shared.personWorks(id:route.edge.node.id,staff:route.staff,page:page+1)
            try Task.checkCancellation()
            var media = result.media
            do { media = try await Intelligence.shared.translatedRelated(media,work:work) } catch is CancellationError { throw CancellationError() } catch { self.error = "资料翻译失败：" + error.localizedDescription }
            var seen = Set(works.map(\.id)); works += media.filter { seen.insert($0.id).inserted }
            page += 1; more = result.hasNextPage
        } catch is CancellationError {} catch { self.error = error.localizedDescription }
    }
}

struct ScreenCreditsSection: View {
    @Environment(\.browserTheme) private var theme
    let work:Work
    @State private var credits = ScreenCredits()
    @State private var selected:ScreenPerson?
    @State private var selectedCreditGroup = "cast"
    @State private var error:String?
    @State private var revision = 0
    @State private var loading = false
    @Namespace private var transition
    var body:some View {
        VStack(alignment:.leading,spacing:20) {
            if !credits.cast.isEmpty {
                Text("演员与角色").font(.headline)
                people(credits.cast,cast:true)
            }
            if !credits.crew.isEmpty {
                Text("主创").font(.headline)
                people(credits.crew,cast:false)
            }
            if !credits.facts.isEmpty {
                LazyVGrid(columns:[GridItem(.flexible(),alignment:.topLeading),GridItem(.flexible(),alignment:.topLeading)],alignment:.leading,spacing:16) {
                    ForEach(["类型","首播","制作公司","播出平台"].filter { credits.facts[$0] != nil },id:\.self) { key in
                        VStack(alignment:.leading,spacing:5) {
                            Text(key).font(.caption).foregroundStyle(theme?.secondary.color ?? .secondary)
                            Text(credits.facts[key] ?? "").foregroundStyle(theme?.primary.color ?? .primary).font(.subheadline).lineLimit(2).truncationMode(.tail)
                        }.frame(maxWidth:.infinity,alignment:.topLeading)
                    }
                }
                .padding(16)
                .background(theme?.card.color ?? Color.secondary.opacity(0.08),in:.rect(cornerRadius:16))
            }
            if loading { ProgressView("加载演职员资料…") }
            if let error { Text(error).font(.caption).foregroundStyle(.secondary); Button("重试演职员资料") { revision += 1 }.font(.caption) }
        }
        .task(id:revision) {
            loading = true; error = nil; defer { loading = false }
            do {
                let value = try await CatalogAPI.shared.screenCredits(work)
                try Task.checkCancellation(); credits = value
                credits = try await Intelligence.shared.translatedCredits(value,work:work); error = nil
            } catch is CancellationError {} catch { self.error = error.localizedDescription }
        }
        .sheet(item:$selected) { person in
            ScreenPersonView(person:person,work:work).navigationTransition(.zoom(sourceID:"\(selectedCreditGroup)-\(person.id)",in:transition))
        }
    }
    private func people(_ people:[ScreenPerson],cast:Bool) -> some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment:.top,spacing:14) {
                ForEach(people) { person in
                    Button { selectedCreditGroup = cast ? "cast" : "crew"; selected = person } label: {
                        VStack(alignment:.leading,spacing:6) {
                            CachedArtwork(address:person.image,cacheOwner:work.id)
                                .frame(width:cast ? 104 : 72,height:cast ? 140 : 96)
                                .clipShape(.rect(cornerRadius:10))
                            Text(person.name).font(.subheadline.weight(.medium)).lineLimit(1).truncationMode(.tail)
                            if cast { ScreenRoleCaption(text:person.role) }
                        }.frame(width:cast ? 104 : 72,alignment:.leading)
                    }.buttonStyle(.plain)
                        .matchedTransitionSource(id:"\(cast ? "cast" : "crew")-\(person.id)",in:transition)
                }
            }
        }.scrollIndicators(.hidden)
    }
}

// Keep the second line half-width without clipping glyphs or the truncation ellipsis.
private struct ScreenRoleCaption: UIViewRepresentable {
    let text:String
    @ScaledMetric(relativeTo:.caption) private var fontSize:CGFloat = 12
    func makeUIView(context:Context) -> UITextView {
        let view = UITextView()
        view.backgroundColor = .clear
        view.isEditable = false
        view.isSelectable = false
        view.isScrollEnabled = false
        view.isUserInteractionEnabled = false
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.textContainer.maximumNumberOfLines = 2
        view.textContainer.lineBreakMode = .byTruncatingTail
        view.setContentCompressionResistancePriority(.defaultLow,for:.horizontal)
        return view
    }
    func updateUIView(_ view:UITextView,context:Context) {
        view.font = .systemFont(ofSize:fontSize)
        view.textColor = .secondaryLabel
        view.text = text
        view.accessibilityLabel = text
    }
    func sizeThatFits(_ proposal:ProposedViewSize,uiView:UITextView,context:Context) -> CGSize? {
        let width = proposal.width ?? 104
        let lineHeight = uiView.font?.lineHeight ?? 15
        uiView.textContainer.size = CGSize(width:width,height:ceil(lineHeight * 2))
        uiView.textContainer.exclusionPaths = [UIBezierPath(rect:CGRect(x:width / 2,y:lineHeight,width:width / 2,height:lineHeight))]
        return CGSize(width:width,height:ceil(lineHeight * 2))
    }
}
private struct ScreenPersonView: View {
    let person:ScreenPerson
    let work:Work
    @Environment(\.dismiss) private var dismiss
    @State private var biography = ScreenBiography(text:"",works:[])
    @State private var error:String?
    @State private var loading = false
    @State private var revision = 0
    @State private var selected:Work?
    @Namespace private var transition
    var body:some View {
        NavigationStack {
            ScrollView {
                VStack(alignment:.leading,spacing:20) {
                    HStack(alignment:.top,spacing:16) {
                        CachedArtwork(address:person.image,cacheOwner:work.id).frame(width:120,height:160).clipShape(.rect(cornerRadius:12))
                        VStack(alignment:.leading,spacing:8) { Text(person.name).font(.title2.bold()); Text(person.role).foregroundStyle(.secondary) }
                    }
                    if !biography.text.isEmpty { Text("人物简介").font(.headline); Text(biography.text).textSelection(.enabled) }
                    if !biography.works.isEmpty {
                        Text("参与作品").font(.headline)
                        LazyVGrid(columns:[GridItem(.adaptive(minimum:120),alignment:.top)],alignment:.leading,spacing:16) {
                            ForEach(biography.works) { item in
                                Button { selected = item } label: {
                                    VStack(alignment:.leading,spacing:6) { Poster(work:item).aspectRatio(2/3,contentMode:.fit); Text(item.title).font(.subheadline).lineLimit(2) }
                                }.buttonStyle(.plain).matchedTransitionSource(id:item.id,in:transition)
                            }
                        }
                    }
                    if loading { ProgressView() }
                    if let error { Text(error).font(.caption).foregroundStyle(.secondary); Button("重试") { revision += 1 } }
                }.padding(20)
            }.navigationTitle("演职员资料").inlineNavigationTitle()
                .toolbar { ToolbarItem(placement:.confirmationAction) { Button("完成") { dismiss() } } }
        }.presentationDetents([.large])
            .task(id:revision) {
                loading = true; error = nil; defer { loading = false }
                do {
                    var value = try await CatalogAPI.shared.screenBiography(id:person.id)
                    try Task.checkCancellation(); biography = value
                    var fields = ["biography":value.text]
                    for item in value.works { fields[item.id] = item.title }
                    var context = work; context.overview += "\nPerson: \(person.name); role: \(person.role)"
                    let texts = try await Intelligence.shared.translateMetadata(fields,work:context)
                    value.text = texts["biography"] ?? value.text
                    for i in value.works.indices { value.works[i].title = texts[value.works[i].id] ?? value.works[i].title }
                    try Task.checkCancellation(); biography = value; error = nil
                } catch is CancellationError {} catch { self.error = error.localizedDescription }
            }
            .sheet(item:$selected) { target in
                WorkSheet(work:target).frame(idealWidth:700,idealHeight:1100).presentationSizing(.fitted).presentationDetents([.large]).navigationTransition(.zoom(sourceID:target.id,in:transition))
            }
    }
}
