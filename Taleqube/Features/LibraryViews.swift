import SwiftUI

struct LibraryImportBatch: Identifiable {
    let id = UUID()
    let records: [TrackingRecord]
}

struct LibraryImportView: View {
    let records: [TrackingRecord]
    var synchronize = false
    var showsCompletion = true
    @Environment(TrackingStore.self) private var tracker
    @Environment(\.dismiss) private var dismiss
    @State private var index = 0
    @State private var selected: Work?
    @State private var candidates: [Work] = []
    @State private var busy = false
    @State private var error: String?
    @State private var manual = false
    @State private var imported = 0
    @State private var deleting = false
    @State private var stopped = false
    @State private var suggestionRevision = UUID()
    @State private var suggestionTask: Task<Void,Never>?
    @State private var matchNotes: [String:String] = [:]
    @State private var matchingPlatforms = Set<Catalog>()
    @State private var matching = false
    @State private var matchingWork: Work?
    @State private var confirmStop = false
    @State private var progressPlatform: Catalog?
    @Namespace private var matchTransition
    private var matchPlatforms: [Catalog] {
        Catalog.allCases.filter { current?.work.kind != .manga || ![.tmdb,.trakt].contains($0) }
    }
    private var current: TrackingRecord? { records.indices.contains(index) ? records[index] : nil }
    private var updating: Bool { current.map { tracker.isInLibrary($0.work) } ?? false }
    var body: some View {
        NavigationStack {
            Group {
                if let record = current {
                    ScrollView {
                        VStack(alignment:.leading,spacing:16) {
                            VStack(alignment:.leading,spacing:12) {
                                Label("平台记录",systemImage:"square.stack").font(.subheadline.bold()).foregroundStyle(.secondary)
                                comparison(record.work)
                                HStack(spacing:8) {
                                    StatusBadge(text:record.status)
                                    Text("\(record.progress) \(record.work.kind == .manga ? "话" : "集")" + (record.score.map { " · 我的评分 \(($0 * 10).formatted())" } ?? "")).font(.caption).foregroundStyle(.secondary)
                                }
                            }.padding(16).frame(maxWidth:.infinity,alignment:.leading)
                                .background(Color(.secondarySystemGroupedBackground),in:.rect(cornerRadius:20))
                            VStack(alignment:.leading,spacing:12) {
                                Label(record.work.kind == .manga ? "AniList 对应作品" : "TMDB 对应作品",systemImage:"checkmark.seal").font(.subheadline.bold()).foregroundStyle(.secondary)
                                if busy { ProgressView("查找对应作品…").frame(maxWidth:.infinity,minHeight:96) }
                                else if let selected { comparison(selected) }
                                else { Text("尚未选择对应作品").foregroundStyle(.secondary).frame(maxWidth:.infinity,minHeight:96) }
                                if let error { Text(error).font(.callout).foregroundStyle(.orange) }
                            }.padding(16).frame(maxWidth:.infinity,alignment:.leading)
                                .background(Color(.secondarySystemGroupedBackground),in:.rect(cornerRadius:20))
                        }.padding(20)
                    }
                    .background(Color(.systemGroupedBackground))
                    .id(index)
                    .safeAreaInset(edge:.top,spacing:0) { importProgressHeader }
                    .safeAreaInset(edge:.bottom) { importControls(record) }
                    .task(id:selected?.id) {
                        guard let selected else { return }
                        await matchPlatformsAutomatically(record,primary:selected)
                    }
                    .task(id:index) {
                        await suggest(record)
                    }
                    .sheet(isPresented:$manual) {
                        MatchPickerView(work:record.work,platform:LibraryIdentity.primarySource(for:record.work.kind),initial:selected) { selected = $0; error = nil }
                    }
                } else if showsCompletion {
                    ContentUnavailableView { Label("导入完成",systemImage:"checkmark.circle") } description: { Text("已处理 \(imported) 部作品。") } actions: { Button("完成") { dismiss() }.buttonStyle(.glassProminent) }
                } else {
                    Color.clear.task { dismiss() }
                }
            }
            .navigationTitle("导入资料库").inlineNavigationTitle()
            .toolbar { ToolbarItem(placement:.cancellationAction) { Button("停止导入") { if matching { confirmStop = true } else { stopped = true; dismiss() } } } }
        }.presentationDetents([.large]).presentationSizing(.form)
        .interactiveDismissDisabled(matching)
        .confirmationDialog("停止导入和进行中的匹配？",isPresented:$confirmStop,titleVisibility:.visible) {
            Button("停止",role:.destructive) { stopped = true; dismiss() }
            Button("继续匹配",role:.cancel) { }
        } message: { Text("已经保存的平台关联会保留。") }
        .sheet(item:$matchingWork) { target in
            WorkSheet(work:target,initialSection:"平台关联",observesAssociationUpdates:true)
                .frame(idealWidth:700,idealHeight:1100).presentationSizing(.fitted).presentationDetents([.large])
                .navigationTransition(.zoom(sourceID:"import-match",in:matchTransition))
        }
        .onDisappear { stopped = true; suggestionTask?.cancel(); suggestionRevision = UUID() }
        .confirmationDialog("删除此作品的来源平台记录？",isPresented:$deleting,titleVisibility:.visible) {
            Button("删除片单、观看记录与评分",role:.destructive) {
                guard let record = current else { return }
                busy = true
                Task {
                    do { try await tracker.deleteSourceRecord(record); if !stopped { advance() } }
                    catch { self.error = error.localizedDescription }
                    busy = false
                }
            }
        } message: { Text("将从 \(current?.work.source.title ?? "") 删除该作品。已导入的其他作品会保留。") }
    }
    private var importProgressHeader: some View {
        VStack(spacing:8) {
            HStack {
                Text("第 \(index+1) / \(records.count) 部").font(.caption.monospacedDigit())
                Spacer()
                Text("已导入 \(imported) 部").font(.caption).foregroundStyle(.secondary)
                Button { matchingWork = selected } label: {
                    Image(systemName:"arrow.up.forward.app")
                        .font(.system(size:16,weight:.medium))
                        .frame(width:32,height:28).contentShape(.rect)
                }.buttonStyle(.plain).foregroundStyle(Color.accentColor).disabled(selected == nil)
                    .accessibilityLabel("打开作品的平台关联")
                    .matchedTransitionSource(id:"import-match",in:matchTransition)
            }
            ProgressView(value:Double(index),total:Double(max(1,records.count)))
            HStack(alignment:.top,spacing:4) {
                ForEach(matchPlatforms) { platform in
                    let saved = selected.map { tracker.record($0) }
                    let ids = Set((saved?.platformLinks ?? []).filter { $0.target.source == platform }.map { $0.target.id }
                        + [saved?.links[platform.rawValue]?.id].compactMap { $0 })
                    let active = matchingPlatforms.contains(platform) || (busy && platform == current.map({ LibraryIdentity.primarySource(for:$0.work.kind) }))
                    let noEntry = saved?.hasNoEntry(platform) == true
                    let note = matchNotes[platform.rawValue] ?? ""
                    let partial = !active && saved?.hasPartialEpisodeMapping(platform) == true
                    let failed = !active && !partial && (note.contains("失败") || note.contains("未确认") || note.contains("未完成"))
                    Button { progressPlatform = platform } label: {
                        VStack(spacing:4) {
                            Text(platform == .mal ? "MAL" : platform.title)
                                .font(.caption.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.8)
                            HStack(spacing:4) {
                                if active { ProgressView().controlSize(.mini) }
                                else {
                                    Image(systemName:partial ? "circle.lefthalf.filled" : failed ? "exclamationmark.circle" : noEntry ? "minus.circle" : ids.isEmpty ? "circle.dotted" : "checkmark.circle.fill")
                                        .foregroundStyle(partial ? Color.yellow : failed ? Color.orange : ids.isEmpty ? Color.secondary : Color.green)
                                }
                                Text("\(ids.count)").monospacedDigit()
                            }.font(.caption)
                            Text(compactMatchStatus(note,active:active,noEntry:noEntry,count:ids.count,partial:partial))
                                .font(.caption2).foregroundStyle(.secondary)
                                .lineLimit(2).frame(minHeight:24,alignment:.top)
                        }.frame(maxWidth:.infinity).contentShape(.rect)
                    }.buttonStyle(.plain)
                        .accessibilityLabel("\(platform.title)，已匹配 \(ids.count) 个条目，\(partial ? "部分集匹配" : note)")
                }
            }
        }.padding(.horizontal,16).padding(.top,4).padding(.bottom,10)
            .background(Color(.systemGroupedBackground))
            .overlay(alignment:.bottom) { Divider() }
            .popover(item:$progressPlatform) { platform in
                VStack(alignment:.leading,spacing:10) {
                    Text(platform.title).font(.headline)
                    if !matchingPlatforms.contains(platform), let selected, tracker.record(selected).hasPartialEpisodeMapping(platform) {
                        Text("部分集匹配").font(.callout).foregroundStyle(.yellow)
                    }
                    Text(matchNotes[platform.rawValue] ?? (selected == nil ? "等待主作品匹配" : "当前关联数量见平台状态栏"))
                        .font(.callout).fixedSize(horizontal:false,vertical:true)
                }.padding(20).frame(idealWidth:320)
                    .presentationCompactAdaptation(.popover)
            }
    }
    private func compactMatchStatus(_ note:String,active:Bool,noEntry:Bool,count:Int,partial:Bool) -> String {
        if noEntry { return "无条目" }
        if active {
            let stage = note.contains("最终") ? "最终复核" : note.contains("搜索") ? "搜索中" : note.contains("详情") || note.contains("资料") ? "补充资料" : note.contains("集对应") ? "集对应" : "匹配中"
            if let range = note.range(of:#"第\s*\d+\s*/\s*\d+\s*轮"#,options:.regularExpression) {
                return stage + "\n" + note[range]
            }
            return stage
        }
        if partial { return "部分集匹配" }
        if note.contains("失败") || note.contains("未完成") { return "匹配失败" }
        if note.contains("未确认") { return "未确认" }
        return count > 0 ? "已关联" : note.isEmpty ? "等待匹配" : "未关联"
    }
    private func importRecord(_ source:TrackingRecord,primary:Work) -> TrackingRecord {
        guard selected?.id == primary.id else { return source }
        var result = source
        let saved = tracker.record(primary)
        result.links.merge(saved.links) { _,new in new }
        result.platformLinks = saved.platformLinks
        result.noEntryPlatforms = saved.noEntryPlatforms
        result.viewingUnits = saved.viewingUnits
        return result
    }
    private func matchPlatformsAutomatically(_ source:TrackingRecord,primary:Work) async {
        matching = true; matchNotes = [:]
        let platforms = matchPlatforms.filter { $0 != .tmdb }
        matchingPlatforms = Set(platforms)
        defer { matching = false; matchingPlatforms = [] }
        do {
            var seed = try LibraryIdentity.canonical(importRecord(source,primary:primary),using:primary)
            if tracker.isInLibrary(primary) { seed = tracker.record(primary) }
            guard await tracker.saveAssociationsAsync(seed) else { throw APIError.message(tracker.message ?? "关联保存失败") }
            try Task.checkCancellation()
            seed = tracker.record(primary)
            let catalog = primary.kind == .tv ? try await CatalogAPI.shared.matchingCatalog(primary) : nil
            try Task.checkCancellation()
            if let catalog { seed.links["tmdb"] = catalog.work }
            let initial = seed
            let requested = platforms.filter { seed.shouldAttemptMatching($0) }
            matchingPlatforms = Set(requested)
            try await AIRequestDeadline.run(seconds:1800) {
                try await ConcurrentPlatformMatching.run(requested,operation:{ platform in
                    try await AutomaticPlatformMatching.match(seed:initial,origin:source.work,platform:platform,catalog:catalog) { note in
                        matchNotes[platform.rawValue] = note
                    }
                },consume:{ platform,outcome in
                    defer { matchingPlatforms.remove(platform) }
                    do {
                        let result = try outcome.get()
                        let latest = tracker.record(primary)
                        // Manual edits from the opened detail sheet take precedence.
                        guard platformSnapshot(latest,platform) == platformSnapshot(initial,platform),
                              latest.links["tmdb"]?.id == initial.links["tmdb"]?.id else {
                            matchNotes[platform.rawValue] = "已保留用户更新的关联"; return
                        }
                        let applied = try result.applying(to:latest,platform:platform,catalog:catalog,replace:false)
                        guard await tracker.saveAssociationsAsync(applied.record) else { throw APIError.message(tracker.message ?? "关联保存失败") }
                        matchNotes[platform.rawValue] = applied.note
                    } catch {
                        try Task.checkCancellation()
                        matchNotes[platform.rawValue] = "匹配失败：" + error.localizedDescription
                    }
                })
            }
        } catch {
            if !Task.isCancelled {
                for platform in matchingPlatforms { matchNotes[platform.rawValue] = "匹配失败：" + error.localizedDescription }
            }
        }
    }
    private func platformSnapshot(_ record:TrackingRecord,_ platform:Catalog) -> String {
        let links = (record.platformLinks ?? []).filter { $0.target.source == platform }
        return links.map { "\($0.id)|\($0.scope.rawValue)|\($0.season)|\($0.mapping?.revision.uuidString ?? "legacy")" }.sorted().joined(separator:";")
            + (record.links[platform.rawValue]?.id ?? "") + String(record.hasNoEntry(platform))
    }
    private func importControls(_ record:TrackingRecord) -> some View {
        VStack(spacing:12) {
            AdaptiveControls {
                Button(record.work.kind == .manga ? "AI 匹配 AniList" : "AI 匹配 TMDB") {
                    suggestionTask?.cancel()
                    suggestionTask = Task { await suggest(record,forceAI:true) }
                }.buttonStyle(.glass).disabled(busy || matching)
                Button("手动匹配") { manual = true }.buttonStyle(.glass).disabled(busy || matching)
                if selected == nil {
                    Button("直接添加来源条目") { accept(exception:true) }.disabled(busy || matching)
                }
                Button("删除来源记录",role:.destructive) { deleting = true }.disabled(busy || matching)
            }
            HStack(spacing:16) {
                Button("跳过") { advance() }.frame(minHeight:44).disabled(busy || matching)
                Button(index == records.count-1 ? (updating ? "更新并完成" : "添加并完成") : (updating ? "更新并继续" : "添加并继续")) { accept(exception:false) }
                    .frame(maxWidth:.infinity,minHeight:44).buttonStyle(.glassProminent).disabled(selected == nil || busy || matching)
            }
        }.padding(16).frame(maxWidth:.infinity).background(.regularMaterial)
    }
    private func comparison(_ work:Work) -> some View {
        HStack(alignment:.top,spacing:16) {
            Poster(work:work).frame(width:72,height:108)
            VStack(alignment:.leading,spacing:6) {
                Text(work.title).font(.headline)
                if work.original != work.title { Text(work.original).font(.caption).foregroundStyle(.secondary) }
                Text("\(work.source.title) · \(work.typeTitle) · \(work.year)").font(.caption).foregroundStyle(.secondary)
                if let url = URL(string:work.url) { Link("查看平台详情",destination:url).font(.caption) }
            }
        }
    }
    private func suggest(_ record:TrackingRecord,forceAI:Bool = false) async {
        let revision = UUID(); suggestionRevision = revision
        busy = true; selected = nil; error = nil; candidates = []
        defer { if suggestionRevision == revision { busy = false } }
        let primary = LibraryIdentity.primarySource(for:record.work.kind)
        do {
            if primary == .tmdb {
                var reference = record.work; reference.title = tracker.display(record.work).title
                let candidate = try await MediaSearch.shared.matchTMDB(reference,linked:tracker.record(record.work).links[primary.rawValue] ?? record.links[primary.rawValue],forceAI:forceAI)
                try Task.checkCancellation()
                guard !stopped, revision == suggestionRevision else { return }
                selected = candidate
                if selected == nil { error = "未找到对应作品，可手动匹配。" }
            } else {
                let reference = tracker.display(record.work)
                let candidate = try await MediaSearch.shared.matchSinglePlatform(reference,platform:primary,origin:reference)
                try Task.checkCancellation()
                guard !stopped, revision == suggestionRevision else { return }
                selected = candidate
                if selected == nil { error = "未找到对应作品，可手动匹配。" }
            }
        } catch is CancellationError { }
        catch { if revision == suggestionRevision && !stopped { self.error = error.localizedDescription } }
    }
    private func advance() {
        selected = nil; matchNotes = [:]
        index += 1
    }
    private func accept(exception:Bool) {
        guard let record = current, let primary = exception ? record.work : selected else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                guard !stopped else { return }
                if var saved = tracker.libraryRecord(for:record.work) {
                    saved.links[primary.source.rawValue] = primary
                    tracker.saveAssociations(saved)
                    if let message = tracker.message { throw APIError.message(message) }
                    imported += 1; advance(); return
                }
                if synchronize {
                    let canonical = try LibraryIdentity.canonical(importRecord(record,primary:primary),using:primary,exception:exception)
                    guard await tracker.save(canonical,synchronize:true) else { error = tracker.message; return }
                } else { try tracker.admit(importRecord(record,primary:primary),using:primary,exception:exception) }
                imported += 1
                if !showsCompletion { dismiss() }
                else { advance() }
            } catch { self.error = error.localizedDescription }
        }
    }
}

struct WorkShelf: View {
    var works: [Work]
    @ScaledMetric(relativeTo:.subheadline) private var captionHeight: CGFloat = 62
    @AppStorage("shelf.cardWidth") private var preferredWidth: Double = 148
    @GestureState private var pinch: CGFloat = 1
    @Environment(\.workTransition) private var transition
    @State private var shelfID = UUID()
    @State private var availableWidth: CGFloat = 0
    private var horizontalWidth: CGFloat {
        guard availableWidth > 0 else { return liveWidth }
        let spacing = ShelfLayout.cardSpacing
        let count = max(1,Int((availableWidth + spacing) / (liveWidth + spacing)))
        return (availableWidth - CGFloat(count - 1) * spacing) / CGFloat(count)
    }
    private var liveWidth: CGFloat { min(320,max(88,preferredWidth * pinch)) }
    var personal = false
    var recent = false
    var platformRecords: [String:TrackingRecord]? = nil
    var collectionIDs: Set<String> = []
    var horizontal = false
    var selecting = false
    var selectedIDs: Set<String> = []
    var onToggle: ((Work) -> Void)? = nil
    var onSelect: ((Work) -> Void)? = nil
    var onDelete: ((Work) -> Void)? = nil
    @Environment(TrackingStore.self) private var tracker
    var body: some View {
        Group {
            if horizontal {
                ScrollView(.horizontal) {
                    LazyHStack(alignment:.top,spacing:ShelfLayout.cardSpacing) { ForEach(works) { work in card(work).frame(width:horizontalWidth) } }
                        .scrollTargetLayout()
                }.scrollIndicators(.hidden).scrollTargetBehavior(.viewAligned)
            } else {
                LazyVGrid(columns:[GridItem(.adaptive(minimum:liveWidth),spacing:ShelfLayout.cardSpacing,alignment:.top)],alignment:.leading,spacing:ShelfLayout.sectionSpacing) {
                    ForEach(works) { work in card(work) }
                }
            }
        }
        .onGeometryChange(for:CGFloat.self,of:{ $0.size.width }) { availableWidth = $0 }
        .simultaneousGesture(MagnifyGesture()
            .updating($pinch) { value,state,_ in state = value.magnification }
            .onEnded { preferredWidth = min(320,max(88,preferredWidth * $0.magnification)) })
        #if targetEnvironment(macCatalyst)
        .safeAreaInset(edge:.bottom,alignment:.trailing,spacing:4) {
            HStack(spacing:8) {
                Button { preferredWidth = max(88,preferredWidth - 24) } label: { Image(systemName:"minus.magnifyingglass") }
                    .accessibilityLabel("缩小封面").disabled(preferredWidth <= 88)
                Button { preferredWidth = min(320,preferredWidth + 24) } label: { Image(systemName:"plus.magnifyingglass") }
                    .accessibilityLabel("放大封面").disabled(preferredWidth >= 320)
            }.buttonStyle(.bordered).padding(4)
        }
        #endif
        .accessibilityAction(named:"放大封面") { preferredWidth = min(320,preferredWidth + 24) }
        .accessibilityAction(named:"缩小封面") { preferredWidth = max(88,preferredWidth - 24) }
    }
    private func open(_ work:Work) {
        transition?.open(work,"\(recent ? "recent:" : "")\(shelfID):\(work.id)")
        if transition == nil { tracker.selected = work }
    }
    private func card(_ work:Work) -> some View {
        let display = platformRecords == nil ? tracker.display(work) : tracker.platformDisplay(work)
        let title = display.title + (collectionIDs.contains(work.id) ? "（合集）" : "")
        let record = platformRecords?[work.id] ?? tracker.record(work)
        return VStack(alignment:.leading,spacing:8) {
            Button { activate(work) } label: {
                Poster(work:display).aspectRatio(2/3,contentMode:.fit)
                    .overlay(alignment:.topTrailing) {
                        if selecting {
                            Image(systemName:selectedIDs.contains(work.id) ? "checkmark.circle.fill" : "circle")
                                .font(.title2).foregroundStyle(selectedIDs.contains(work.id) ? Color.accentColor : .white)
                                .padding(8).background(.regularMaterial,in:Circle()).padding(6)
                        } else if let score = personal ? record.score : display.rating {
                            Text((score * 10).formatted(.number.precision(.fractionLength(0...1))))
                                .accessibilityLabel("\(personal ? "我的评分" : display.source.title + " 均分")，\((score * 10).formatted()) 分")
                                .font(.caption.weight(.semibold)).monospacedDigit()
                                .padding(.horizontal,8).padding(.vertical,5).background(.regularMaterial,in:Capsule()).padding(7)
                        }
                    }
                    .overlay(alignment:.topLeading) {
                        if personal || recent {
                            CoverStatusBadge(status:recent && work.kind == .movie ? "已观看" : record.status,isBook:work.kind == .manga)
                        }
                    }
                    .overlay(alignment:.bottomLeading) {
                        if record.libraryException != nil { StatusBadge(text:"待确认").background(.regularMaterial,in:Capsule()).padding(7) }
                    }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("work.open.\(work.id)")
            .modifier(WorkTransitionSource(id:"\(recent ? "recent:" : "")\(shelfID):\(work.id)",namespace:transition?.namespace))
            .contentShape(.contextMenuPreview,.rect(cornerRadius:18))
            .contextMenu {
                if tracker.isInLibrary(work) {
                    Menu("修改状态",systemImage:"checkmark.circle") {
                        ForEach(["计划中","进行中","已完成","已暂停","已放弃","重温中"],id:\.self) { status in
                            Button { tracker.updateStatus([tracker.record(work).id],to:status) } label: { StatusMenuLabel(status:status) }
                        }
                    }
                }
                if let onSelect { Button("多选",systemImage:"checkmark.circle") { onSelect(work) } }
                if let url = work.catalogURL { ShareLink(item:url) }
                if let onDelete { Button(platformRecords == nil ? "从资料库删除" : "删除",systemImage:"trash",role:.destructive) { onDelete(work) } }
            } preview: {
                Poster(work:display).frame(width:240,height:360)
            }
            .accessibilityLabel(title)
            Button { activate(work) } label: {
                VStack(alignment:.leading,spacing:4) {
                    Text(title).font(.subheadline.weight(.semibold)).lineLimit(2)
                        .frame(maxWidth:.infinity,alignment:.topLeading).truncationMode(.tail)
                    HStack(spacing:5) {
                        if recent, let row = tracker.recent.first(where:{ $0.0.id == work.id }) {
                            if work.kind == .movie { Text(work.year) }
                            else { Text("第 \(row.2) 季 · 第 \(row.1) 集") }
                        } else {
                            if !personal { Text(work.kind.title) }
                            if !work.year.isEmpty { Text(work.year) }
                        }
                    }.font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength:0)
                }.frame(height:captionHeight,alignment:.topLeading).contentShape(.rect)
            }.buttonStyle(.plain)
        }
        .accessibilityAddTraits(selecting && selectedIDs.contains(work.id) ? .isSelected : [])
        .task(id:work.id + MediaLanguage.titleIdentity(work)) { await tracker.localize(work) }
    }
    private func activate(_ work:Work) {
        if selecting { onToggle?(work) } else { open(work) }
    }
}
struct PlatformShelfView: View {
    let source: Catalog
    @Environment(TrackingStore.self) private var tracker
    @State private var section = "片单"
    @State private var media = "影视"
    @State private var query = ""
    @State private var status = "全部"
    @State private var deletingWork: Work?
    @State private var confirmingDelete = false
    @State private var deleting = false
    @State private var deleteError: String?
    @State private var importBatch: LibraryImportBatch?
    @State private var unimportedOnly = false
    @State private var selecting = false
    @State private var selectedIDs: Set<String> = []
    private var shelfGroups: [[TrackingRecord]] {
        tracker.platformShelfGroups(tracker.library[source.rawValue] ?? [],source:source)
    }
    private var collectionIDs: Set<String> {
        Set(shelfGroups.filter { $0.count > 1 }.flatMap { $0.map(\.id) })
    }
    private var selectedImports: [TrackingRecord] { pendingRecords.filter { selectedIDs.contains($0.id) } }
    private var pendingRecords: [TrackingRecord] { records.filter { tracker.libraryRecord(for:$0.work) == nil } }
    private var records: [TrackingRecord] {
        shelfGroups.compactMap { group in group.first {
            (!unimportedOnly || tracker.libraryRecord(for:$0.work) == nil) && (media == "书籍" ? $0.work.kind == .manga : $0.work.kind != .manga) && (status == "全部" || (status == "已评分" ? $0.score != nil : $0.status == status)) &&
            (query.isEmpty || tracker.platformDisplay($0.work).title.localizedCaseInsensitiveContains(query) || $0.work.title.localizedCaseInsensitiveContains(query) || $0.work.original.localizedCaseInsensitiveContains(query))
        } }
    }
    var body: some View {
        VStack(alignment:.leading,spacing:20) {
            Picker("浏览",selection:$section) { Text("片单").tag("片单"); Text("发现").tag("发现") }.pickerStyle(.segmented)
            if section == "发现" { CatalogBrowserView(source:source) }
            else {
                HStack(spacing:10) {
                    Image(systemName:"magnifyingglass").foregroundStyle(.secondary)
                    TextField("搜索片单",text:$query).textInputAutocapitalization(.never)
                    if !query.isEmpty { Button { query = "" } label: { Image(systemName:"xmark.circle.fill") }.accessibilityLabel("清除搜索") }
                }.padding(.horizontal,16).frame(minHeight:48).glassPanel(cornerRadius:16)
                LazyVGrid(columns:[GridItem(.adaptive(minimum:145),spacing:12,alignment:.leading)],alignment:.leading,spacing:12) {
                    if source != .trakt {
                        VStack(alignment:.leading,spacing:4) {
                            Text("类型").font(.caption).foregroundStyle(.secondary)
                            Picker("类型",selection:$media) { Text("动画").tag("影视"); Text("书籍").tag("书籍") }.labelsHidden()
                        }
                    }
                    VStack(alignment:.leading,spacing:4) {
                        Text("观看状态").font(.caption).foregroundStyle(.secondary)
                        Picker("观看状态",selection:$status) { ForEach(["全部","已评分","进行中","已完成","已观看","计划中","已暂停","已放弃","重温中"],id:\.self) { Text($0).tag($0) } }.labelsHidden()
                    }
                    VStack(alignment:.leading,spacing:4) {
                        Text("导入状态").font(.caption).foregroundStyle(.secondary)
                        Picker("导入状态",selection:$unimportedOnly) { Text("全部条目").tag(false); Text("仅未导入").tag(true) }.labelsHidden()
                    }
                    Button("重置筛选") { status = "全部"; media = "影视"; unimportedOnly = false }.font(.subheadline)
                }.pickerStyle(.menu)
                HStack(spacing:8) {
                    VStack(alignment:.leading,spacing:4) {
                        Text("\(records.count) 个条目").font(.caption).foregroundStyle(.secondary)
                        if status != "全部" || unimportedOnly || media == "书籍" {
                            Text(([media == "书籍" ? "书籍" : "",status == "全部" ? "" : status,unimportedOnly ? "未添加" : ""].filter { !$0.isEmpty }).joined(separator:" · "))
                                .font(.caption).foregroundStyle(Color.accentColor)
                        }
                    }
                    Spacer(minLength:8)
                    AdaptiveControls {
                        Button(selecting ? "完成选择" : "多选") { selecting.toggle(); selectedIDs = [] }
                        if selecting {
                            Button("全选") { selectedIDs = Set(pendingRecords.map(\.id)) }
                            Button("导入所选（\(selectedImports.count)）") { importBatch = LibraryImportBatch(records:selectedImports) }
                                .disabled(selectedImports.isEmpty)
                        }
                        Button("导入（\(pendingRecords.count)）") { importBatch = LibraryImportBatch(records:pendingRecords) }
                            .buttonStyle(.glass).disabled(pendingRecords.isEmpty)
                            .accessibilityHint("导入当前筛选结果中尚未添加的条目")
                    }
                }
                if let error = tracker.libraryErrors[source.rawValue] { Text(error).font(.callout).foregroundStyle(.orange) }
                if records.isEmpty && !tracker.loadingLibrary {
                    ContentUnavailableView(Credentials.read("\(source.rawValue).token").isEmpty ? "尚未连接 \(source.title)" : tracker.libraryErrors[source.rawValue] != nil ? "片单加载失败" : "没有匹配的作品",systemImage:"rectangle.stack",description:Text(Credentials.read("\(source.rawValue).token").isEmpty ? "在设置中连接账号以读取片单。" : "调整搜索与筛选，或下拉刷新。"))
                }
                WorkShelf(works:records.map(\.work),personal:true,platformRecords:Dictionary(uniqueKeysWithValues:records.map { ($0.id,$0) }),
                          collectionIDs:collectionIDs,
                          selecting:selecting,selectedIDs:selectedIDs,
                          onToggle:{ work in if !selectedIDs.insert(work.id).inserted { selectedIDs.remove(work.id) } },
                          onSelect:{ work in selecting = true; selectedIDs.insert(work.id) },
                          onDelete:{ work in deletingWork = work; confirmingDelete = true })
                    .disabled(deleting)
                if deleting { ProgressView("正在从 \(source.title) 删除…") }
                if let deleteError { Text(deleteError).font(.callout).foregroundStyle(.red) }
            }
        }
        .onChange(of:section) { _,value in
            if value == "发现" { tracker.platformDiscovery.insert(source) }
            else { tracker.platformDiscovery.remove(source) }
        }
        .onChange(of:records.map(\.id)) { _,ids in selectedIDs.formIntersection(Set(ids)) }
        .sheet(item:$importBatch) { batch in LibraryImportView(records:batch.records) }
        .confirmationDialog("从 \(source.title) 删除此作品？",isPresented:$confirmingDelete,titleVisibility:.visible) {
            Button("删除",role:.destructive) {
                guard let work = deletingWork else { return }
                deleting = true; deleteError = nil
                Task {
                    defer { deleting = false }
                    do { try await tracker.deleteSourceRecord(TrackingRecord(work:work)); deletingWork = nil }
                    catch { deleteError = error.localizedDescription }
                }
            }
            Button("取消",role:.cancel) { deletingWork = nil }
        } message: { Text("此平台上《\(deletingWork?.title ?? "")》的评分、观看／阅读状态和进度将被清空。本地资料库及其他平台记录保留。") }
    }
}

enum DiscoveryCategory: String, CaseIterable, Identifiable {
    case movie = "电影", tv = "剧集", anime = "动漫", manga = "书籍"
    var id:String { rawValue }
    var kind:WorkKind { self == .movie ? .movie : self == .manga ? .manga : .tv }
    var sources:[Catalog] {
        switch self {
        case .movie,.tv: [.tmdb,.trakt,.anilist,.bangumi]
        case .anime: [.anilist,.bangumi,.mal]
        case .manga: [.anilist,.bangumi,.mal]
        }
    }
    var defaultSource:Catalog { self == .anime || self == .manga ? .anilist : .tmdb }
}

struct ShelfTabs<Value:Hashable>: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let values:[Value]
    @Binding var selection:Value
    let title:(Value) -> String
    var body: some View {
        if typeSize.isAccessibilitySize {
            picker.pickerStyle(.menu)
        } else { picker.pickerStyle(.segmented) }
    }
    private var picker: some View {
        Picker("栏目",selection:$selection) {
            ForEach(values,id:\.self) { value in Text(title(value)).tag(value) }
        }
    }
}

struct CatalogBrowserView: View {
    var source: Catalog?
    @Environment(TrackingStore.self) private var tracker
    @State private var category:DiscoveryCategory = .tv
    @State private var chosenSource:Catalog = .tmdb
    @State private var query = ""
    @State private var submittedQuery = ""
    @State private var filters = AniListFilters()
    @State private var tmdb = TMDBFilters()
    @State private var provider = ProviderFilters()
    @State private var results: [Work] = []
    @State private var terms: [String] = []
    @State private var notices: [String] = []
    @State private var busy = false
    @State private var more = false
    @State private var page = 1
    @State private var revision = UUID()
    @FocusState private var focused: Bool
    private var catalog: Catalog { source ?? chosenSource }
    private var kind:WorkKind { category.kind }
    private var options:AniListFilters { var value = filters; value.allAnime = category == .anime; return value }
    private var providerOptions:ProviderFilters { var value = provider; value.animationOnly = category == .anime; return value }
    private var categories:[DiscoveryCategory] { DiscoveryCategory.allCases.filter { source == nil || $0.sources.contains(source!) } }
    private var cacheKey: String { "\(category.rawValue)|\(catalog.rawValue)|\(options.key)|\(tmdb.key)|\(providerOptions.key)|\(submittedQuery)" }
    private var searchKey: String { cacheKey + "|\(revision)" }
    var body: some View {
        VStack(alignment:.leading,spacing:18) {
            ShelfTabs(values:categories,selection:Binding(get:{ category },set:{ value in
                category = value; chosenSource = value.defaultSource; filters = AniListFilters(); tmdb = TMDBFilters(); provider = ProviderFilters()
            }),title:{ $0.rawValue })
            if source == nil {
                Picker("来源",selection:$chosenSource) { ForEach(category.sources) { Text($0.title).tag($0) } }.pickerStyle(.menu)
            } else { Text("来源：" + catalog.title).font(.caption).foregroundStyle(.secondary) }
            HStack {
                Image(systemName:"magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索作品",text:$query).focused($focused).submitLabel(.search).onSubmit { submit() }
                if !query.isEmpty { Button { query = ""; submit() } label: { Image(systemName:"xmark.circle.fill") }.accessibilityLabel("清除搜索") }
                Button("搜索") { submit() }.buttonStyle(.borderless)
            }.padding(.horizontal,16).frame(minHeight:48).glassPanel(cornerRadius:16)
            VStack(alignment:.leading,spacing:10) {
                if catalog == .anilist { filterControls }
                if catalog == .tmdb { tmdbControls }
                if ![Catalog.tmdb,.anilist].contains(catalog) { providerControls }
            }.padding(16).frame(maxWidth:.infinity,alignment:.leading)
                .background(.regularMaterial,in:.rect(cornerRadius:18))
            if !terms.isEmpty { Text("已搜索：" + terms.joined(separator:" · ")).font(.caption).foregroundStyle(.secondary) }
            ForEach(notices,id:\.self) { Text($0).font(.caption).foregroundStyle(.orange) }
            if !busy && results.isEmpty { ContentUnavailableView(notices.isEmpty ? "没有匹配的作品" : "作品加载失败",systemImage:"magnifyingglass",description:Text(notices.isEmpty ? "试试其他搜索词或重置筛选。" : "请检查来源配置后重试。")); if !notices.isEmpty { Button("重新加载") { revision = UUID() } } }
            WorkShelf(works:results)
            if more { Button("加载更多") { Task { await loadMore() } }.buttonStyle(.glass).disabled(busy).frame(maxWidth:.infinity) }
        }
        .task(id:searchKey) { await search() }
        .onAppear {
            if !categories.contains(category), let first = categories.first { category = first }
            if source == nil && tracker.wantsSearchFocus { focused = true; tracker.wantsSearchFocus = false }
        }
        .onChange(of:chosenSource) { _,_ in provider = ProviderFilters() }
        .onChange(of:tracker.searchFocusRequest) { _,_ in if source == nil { focused = true; tracker.wantsSearchFocus = false } }
        .onChange(of:tracker.refreshRequest) { _,_ in
            guard tracker.refreshSource == source else { return }
            tracker.browseCache[cacheKey] = nil; revision = UUID()
        }
    }
    private func submit() { submittedQuery = query.trimmingCharacters(in:.whitespacesAndNewlines); revision = UUID() }
    private var years:[Int] { Array((1900...(Calendar.current.component(.year,from:Date())+2)).reversed()) }
    private func optional(_ key:WritableKeyPath<AniListFilters,String?>) -> Binding<String> {
        Binding(get:{ filters[keyPath:key] ?? "" },set:{ filters[keyPath:key] = $0.isEmpty ? nil : $0 })
    }
    private var filterControls: some View {
        LazyVGrid(columns:[GridItem(.adaptive(minimum:150),spacing:12,alignment:.leading)],alignment:.leading,spacing:10) {
            Group {
                Picker("年份",selection:Binding(get:{ filters.year ?? 0 },set:{ filters.year = $0 == 0 ? nil : $0 })) {
                    Text("全部年份").tag(0); ForEach(years,id:\.self) { Text(String($0)).tag($0) }
                }
                if kind != .manga { Picker("季度",selection:optional(\.season)) { Text("全部季度").tag(""); Text("冬季").tag("WINTER"); Text("春季").tag("SPRING"); Text("夏季").tag("SUMMER"); Text("秋季").tag("FALL") } }
            }
            Group {
                Picker("排序",selection:$filters.sort) { ForEach(BrowseSort.allCases) { Text($0.title).tag($0) } }
                Picker("发行状态",selection:optional(\.status)) { Text("全部状态").tag(""); Text("连载中").tag("RELEASING"); Text("已完结").tag("FINISHED"); Text("未发行").tag("NOT_YET_RELEASED"); Text("已取消").tag("CANCELLED"); Text("休刊中").tag("HIATUS") }
            }
            Group {
                if kind != .movie {
                    Picker("形式",selection:optional(\.format)) {
                        Text("全部形式").tag("")
                        if kind == .manga { Text("漫画").tag("MANGA"); Text("轻小说").tag("NOVEL"); Text("短篇").tag("ONE_SHOT") }
                        else { Text("TV").tag("TV"); Text("短篇 TV").tag("TV_SHORT"); if category == .anime { Text("电影").tag("MOVIE") }; Text("OVA").tag("OVA"); Text("ONA").tag("ONA"); Text("特别篇").tag("SPECIAL"); Text("音乐").tag("MUSIC") }
                    }
                }
                Picker("题材",selection:optional(\.genre)) {
                    Text("全部题材").tag("")
                    ForEach(["动作|Action","冒险|Adventure","喜剧|Comedy","剧情|Drama","奇幻|Fantasy","恐怖|Horror","悬疑|Mystery","恋爱|Romance","科幻|Sci-Fi","日常|Slice of Life","运动|Sports","惊悚|Thriller","超自然|Supernatural","心理|Psychological","机甲|Mecha","音乐|Music","魔法少女|Mahou Shoujo"],id:\.self) { item in
                        let parts = item.components(separatedBy:"|"); Text(parts[0]).tag(parts[1])
                    }
                }
            }
            Group {
                Picker("最低评分",selection:Binding(get:{ filters.minimumScore ?? 0 },set:{ filters.minimumScore = $0 == 0 ? nil : $0 })) {
                    Text("不限评分").tag(0); ForEach([50,60,70,80,90],id:\.self) { Text("\($0) 分以上").tag($0) }
                }
                Picker("地区",selection:optional(\.country)) { Text("全部地区").tag(""); Text("日本").tag("JP"); Text("中国").tag("CN"); Text("韩国").tag("KR"); Text("台湾").tag("TW") }
                Button("重置") { filters = AniListFilters() }.font(.caption)
            }
        }.pickerStyle(.menu)
    }
    private var tmdbGenres:[(String,Int)] {
        kind == .movie ? [("动作",28),("冒险",12),("动画",16),("喜剧",35),("犯罪",80),("纪录",99),("剧情",18),("家庭",10751),("奇幻",14),("历史",36),("恐怖",27),("音乐",10402),("悬疑",9648),("爱情",10749),("科幻",878),("惊悚",53),("战争",10752),("西部",37)] : [("动作冒险",10759),("动画",16),("喜剧",35),("犯罪",80),("纪录",99),("剧情",18),("家庭",10751),("儿童",10762),("悬疑",9648),("真人秀",10764),("科幻奇幻",10765),("战争政治",10768)]
    }
    private var tmdbControls: some View {
        LazyVGrid(columns:[GridItem(.adaptive(minimum:150),spacing:12,alignment:.leading)],alignment:.leading,spacing:10) {
            Picker("年份",selection:$tmdb.year) { Text("全部年份").tag(0); ForEach(years,id:\.self) { Text(String($0)).tag($0) } }
            Group {
                Group {
                    Picker("排序",selection:$tmdb.sort) {
                        Text("人气从高到低").tag("popularity.desc"); Text("人气从低到高").tag("popularity.asc")
                        Text("评分降序").tag("vote_average.desc"); Text("评分升序").tag("vote_average.asc")
                        Text("评分人数").tag("vote_count.desc")
                        Text("最新发行").tag(kind == .movie ? "primary_release_date.desc" : "first_air_date.desc")
                        Text("最早发行").tag(kind == .movie ? "primary_release_date.asc" : "first_air_date.asc")
                    }
                    Picker("题材",selection:$tmdb.genre) { Text("全部题材").tag(0); ForEach(tmdbGenres,id:\.1) { Text($0.0).tag($0.1) } }
                }
                Group {
                    Picker("原始语言",selection:$tmdb.language) { Text("全部语言").tag(""); Text("中文").tag("zh"); Text("英语").tag("en"); Text("日语").tag("ja"); Text("韩语").tag("ko"); Text("法语").tag("fr"); Text("西班牙语").tag("es"); Text("粤语").tag("cn") }
                    Picker("最低评分",selection:$tmdb.minimumScore) { Text("不限评分").tag(0); ForEach(5...9,id:\.self) { Text("\($0 * 10) 分以上").tag($0) } }
                }
                Group {
                    Picker("评分人数",selection:$tmdb.minimumVotes) { Text("评分人数不限").tag(0); ForEach([50,100,500,1000,5000],id:\.self) { Text("至少 \($0) 人").tag($0) } }
                    if kind == .movie {
                        Picker("时长",selection:$tmdb.maximumRuntime) { Text("不限时长").tag(0); ForEach([60,90,120,150,180],id:\.self) { Text("\($0) 分钟以内").tag($0) } }
                    } else {
                        Picker("状态",selection:$tmdb.status) { Text("全部状态").tag(""); Text("播出中").tag("0"); Text("计划中").tag("1"); Text("制作中").tag("2"); Text("已完结").tag("3"); Text("已取消").tag("4"); Text("试播").tag("5") }
                    }
                }
            }.disabled(!submittedQuery.isEmpty)
            Button("重置筛选") { tmdb = TMDBFilters() }.font(.caption)
        }.pickerStyle(.menu)
    }
    private var providerControls: some View {
        LazyVGrid(columns:[GridItem(.adaptive(minimum:150),spacing:12,alignment:.leading)],alignment:.leading,spacing:10) {
            if catalog == .mal {
                Group {
                    if provider.year > 0 && kind != .manga {
                        Picker("季度排序",selection:$provider.sort) { Text("评分").tag(""); Text("人气").tag("bypopularity") }
                    } else {
                    Picker("榜单",selection:$provider.sort) {
                        Text("评分榜").tag(""); Text("人气榜").tag("bypopularity"); Text("收藏榜").tag("favorite")
                        if kind != .manga { Text("正在播出").tag("airing"); Text("即将播出").tag("upcoming"); Text("TV").tag("tv"); Text("OVA").tag("ova"); Text("电影").tag("movie"); Text("特别篇").tag("special") }
                        else { Text("漫画").tag("manga"); Text("小说").tag("novels"); Text("短篇").tag("oneshots"); Text("同人志").tag("doujin"); Text("韩漫").tag("manhwa"); Text("华语漫画").tag("manhua") }
                    }
                    }
                    if kind != .manga { providerYearAndSeason }
                }.disabled(!submittedQuery.isEmpty)
            } else {
                Group {
                    Picker("年份",selection:$provider.year) { Text("全部年份").tag(0); ForEach(years,id:\.self) { Text(String($0)).tag($0) } }
                    Picker("排序",selection:$provider.sort) {
                        if catalog == .trakt { Text("人气").tag(""); Text("正在流行").tag("trending"); Text("备受期待").tag("anticipated"); Text("观看最多").tag("watched/weekly"); Text("播放最多").tag("played/weekly") }
                        else { Text("相关程度").tag(""); Text("收藏人数").tag("heat"); Text("排名").tag("rank"); Text("评分").tag("score") }
                    }
                }
                if catalog == .bangumi {
                    if kind != .manga { providerSeason.disabled(provider.year == 0) }
                    TextField("题材标签",text:$provider.genre).textFieldStyle(.roundedBorder)
                    Picker("最低评分",selection:$provider.minimumScore) { Text("不限评分").tag(0); ForEach(5...9,id:\.self) { Text("\($0 * 10) 分以上").tag($0) } }
                } else {
                    Picker("题材",selection:$provider.genre) {
                        Text("全部题材").tag(""); Text("动作").tag("action"); Text("冒险").tag("adventure"); Text("动画").tag("animation"); Text("喜剧").tag("comedy"); Text("犯罪").tag("crime"); Text("纪录").tag("documentary"); Text("剧情").tag("drama"); Text("奇幻").tag("fantasy"); Text("科幻").tag("science-fiction"); Text("悬疑").tag("mystery"); Text("爱情").tag("romance"); Text("惊悚").tag("thriller")
                    }
                }
            }
            Button("重置筛选") { provider = ProviderFilters() }.font(.caption)
        }.pickerStyle(.menu)
        .onChange(of:provider.year) { _,year in
            guard catalog == .mal else { return }
            provider.sort = ""
            if year > 0 && provider.season.isEmpty {
                let quarter = (Calendar.current.component(.month,from:Date()) - 1) / 3
                provider.season = ["WINTER","SPRING","SUMMER","FALL"][quarter]
            }
        }
    }
    private var providerYearAndSeason: some View {
        Group {
            Picker("季度年份",selection:$provider.year) { Text("全部年份").tag(0); ForEach(years,id:\.self) { Text(String($0)).tag($0) } }
            providerSeason.disabled(provider.year == 0)
        }
    }
    private var providerSeason: some View {
        Picker("季度",selection:$provider.season) { if catalog != .mal { Text("全部季度").tag("") }; Text("冬季").tag("WINTER"); Text("春季").tag("SPRING"); Text("夏季").tag("SUMMER"); Text("秋季").tag("FALL") }
    }
    private func fetch(_ next:Int) async throws -> (works:[Work],hasNext:Bool) {
        if catalog == .anilist { return try await CatalogAPI.shared.anilistPage(kind:kind,query:submittedQuery,page:next,filters:options) }
        if catalog == .tmdb { return try await CatalogAPI.shared.tmdbPage(kind:kind,query:submittedQuery,page:next,filters:tmdb) }
        let works = try await CatalogAPI.shared.search(catalog,kind:kind,query:submittedQuery,page:next,provider:providerOptions)
        return (works,!works.isEmpty)
    }
    private func search() async {
        let key = cacheKey
        if let cached = tracker.browseCache[key] {
            results = cached.works; terms = cached.terms; notices = cached.notices; more = cached.more; page = cached.page
            busy = false; return
        }
        let request = UUID(); tracker.browsingRequests.insert(request)
        busy = true; results = []; notices = []; terms = []; page = 1; more = false
        defer { tracker.browsingRequests.remove(request); if !Task.isCancelled { busy = false } }
        do {
            let data = try await fetch(1)
            try Task.checkCancellation(); results = MediaLanguage.merge([],data.works); more = data.hasNext
            // Enrich submitted searches with evidenced aliases, retaining the first page for pagination.
            if !submittedQuery.isEmpty {
                let data = try await MediaSearch.shared.search(catalog,kind:kind,query:submittedQuery,filters:options,provider:providerOptions,seed:catalog == .tmdb ? nil : data.works)
                try Task.checkCancellation()
                // TMDB search years must also apply to alias results.
                let extra = data.works.filter { catalog != .tmdb || tmdb.year == 0 || $0.year == String(tmdb.year) }
                results = MediaLanguage.merge(results,extra); terms = data.terms; notices = data.notices
            }
            tracker.browseCache[key] = (results,terms,notices,more,page)
        } catch is CancellationError { }
        catch { if !Task.isCancelled { notices = [error.localizedDescription] } }
    }
    private func loadMore() async {
        guard !busy, more else { return }
        let key = searchKey; busy = true; defer { if key == searchKey { busy = false } }
        do {
            let data = try await fetch(page+1)
            guard key == searchKey else { return }
            let merged = MediaLanguage.merge(results,data.works)
            more = data.hasNext; results = merged; page += 1
            tracker.browseCache[cacheKey] = (results,terms,notices,more,page)
        } catch { if key == searchKey { notices = [error.localizedDescription] } }
    }
}

/// Menus keep their intrinsic width; large text and narrow columns stack them.
struct AdaptiveControls<Content:View>: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let content:Content
    init(@ViewBuilder content:() -> Content) { self.content = content() }
    var body: some View {
        if typeSize.isAccessibilitySize { VStack(alignment:.leading,spacing:12) { content } }
        else {
            ViewThatFits(in:.horizontal) {
                HStack(spacing:16) { content }.fixedSize(horizontal:true,vertical:false)
                VStack(alignment:.leading,spacing:12) { content }
            }
        }
    }
}
