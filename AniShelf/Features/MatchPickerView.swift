import SwiftUI

struct MatchPickerView: View {
    let work: Work
    let platform: Catalog
    var initial: Work?
    var allowsMultiple = false
    var existingIDs: Set<String> = []
    var onConfirmMany: (([Work]) -> Bool)? = nil
    var onConfirm: (Work) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(TrackingStore.self) private var tracker
    @State private var query = ""
    @State private var submittedQuery = ""
    @State private var results: [Work] = []
    @State private var chosen: Work?
    @State private var selections: [String:Work] = [:]
    @State private var page = 1
    @State private var paging = false
    @State private var hasMore = true
    @State private var terms: [String] = []
    @State private var notices: [String] = []
    @State private var loading = false
    @State private var revision = UUID()
    private func confirmImmediately(_ candidate:Work) {
        if allowsMultiple {
            if onConfirmMany?([candidate]) == true { dismiss() }
            else { notices.append("保存失败，请重试") }
        } else { onConfirm(candidate); dismiss() }
    }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing:12) {
                        Poster(work:work).frame(width:40,height:60)
                        VStack(alignment:.leading) { Text(tracker.display(work).title).font(.headline); Text("\(work.typeTitle) · \(work.year)").font(.caption).foregroundStyle(.secondary) }
                    }
                    TextField("搜索 \(platform.title)",text:$query).submitLabel(.search).onSubmit { revision = UUID() }
                    Button("搜索") { revision = UUID() }.buttonStyle(.borderless)
                    if loading { ProgressView("搜索中…") }
                    if !terms.isEmpty { Text(terms.joined(separator:" · ")).font(.caption).foregroundStyle(.secondary) }
                    ForEach(notices,id:\.self) { Text($0).font(.caption).foregroundStyle(.orange) }
                }
                Section("搜索结果") {
                    ForEach(results) { candidate in
                        HStack(spacing:0) {
                            Button { confirmImmediately(candidate) } label: {
                                HStack(spacing:12) {
                                    Poster(work:candidate).frame(width:52,height:78)
                                    VStack(alignment:.leading,spacing:5) {
                                        Text(candidate.title).font(.headline).foregroundStyle(.primary)
                                        if candidate.original != candidate.title { Text(candidate.original).font(.caption).foregroundStyle(.secondary) }
                                        Text("\(candidate.typeTitle) · \(candidate.year) · \(candidate.remoteID)").font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                }.padding(.vertical,6).contentShape(Rectangle())
                            }.buttonStyle(.borderless)
                            if allowsMultiple && existingIDs.contains(candidate.id) {
                                Text("已添加").font(.caption).foregroundStyle(.secondary)
                            } else {
                                Button {
                                    if allowsMultiple {
                                        if selections.removeValue(forKey:candidate.id) == nil { selections[candidate.id] = candidate }
                                    } else { chosen = candidate }
                                } label: {
                                    Image(systemName:(allowsMultiple ? selections[candidate.id] != nil : chosen?.id == candidate.id) ? "checkmark.circle.fill" : "circle")
                                        .frame(width:44,height:44)
                                }.buttonStyle(.borderless).accessibilityLabel("选择 \(candidate.title)")
                            }
                        }
                        .contentShape(.contextMenuPreview,.rect(cornerRadius:12))
                        .contextMenu {
                            Button("选择此项",systemImage:"checkmark") { confirmImmediately(candidate) }
                        } preview: {
                            VStack(alignment:.leading,spacing:12) {
                                Poster(work:candidate).frame(width:240,height:360)
                                Text(candidate.title).font(.headline)
                                Text(candidate.overview).font(.caption).lineLimit(6)
                            }.padding().frame(width:272)
                        }
                        .disabled(allowsMultiple && existingIDs.contains(candidate.id))
                    }
                    if hasMore && !results.isEmpty {
                        Button(paging ? "加载中…" : "加载更多") { Task { await loadMore() } }.disabled(paging || loading)
                    }
                    if results.isEmpty && !loading { Text("没有匹配作品，可以修改搜索词后重试。").foregroundStyle(.secondary) }
                }
                if allowsMultiple && !selections.isEmpty {
                    Section("已选 \(selections.count) 项") {
                        ForEach(selections.values.sorted { $0.id < $1.id }) { value in
                            HStack { Text(value.title); Spacer(); Button("取消选择") { selections[value.id] = nil }.buttonStyle(.borderless) }
                        }
                    }
                }
                if let chosen, !allowsMultiple {
                    Section("已选择") {
                        Text(chosen.title).font(.headline)
                        if let url = URL(string:chosen.url) { Link("查看平台详情",destination:url) }
                    }
                }
            }
            .navigationTitle("关联 \(platform.title)")
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement:.cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement:.confirmationAction) {
                    Button(allowsMultiple ? "添加 \(selections.count) 个条目" : "确认关联") {
                        if allowsMultiple {
                            if onConfirmMany?(selections.values.sorted { $0.id < $1.id }) == true { dismiss() }
                            else { notices.append("保存失败，请重试") }
                        } else if let chosen { onConfirm(chosen); dismiss() }
                    }.buttonStyle(.glassProminent).disabled(allowsMultiple ? selections.isEmpty : chosen == nil)
                }
            }
            .task(id:revision) {
                if query.isEmpty { query = tracker.display(work).title }
                if results.isEmpty, let initial { results = [initial]; chosen = initial }
                submittedQuery = query
                loading = true; notices = []; terms = []; page = 1; hasMore = true
                defer { if !Task.isCancelled { loading = false } }
                do {
                    let result = try await MediaSearch.shared.search(platform,kind:work.kind,query:query,original:query == tracker.display(work).title ? work.original : "",year:work.year) { partial in
                        guard !Task.isCancelled else { return }
                        results = MediaLanguage.merge(partial.works,initial.map { [$0] } ?? []); terms = partial.terms
                    }
                    try Task.checkCancellation()
                    results = MediaLanguage.merge(result.works,initial.map { [$0] } ?? []); terms = result.terms; notices = result.notices
                    if let selected = chosen, let fresh = results.first(where:{ $0.id == selected.id }) { chosen = fresh }
                } catch is CancellationError { }
                catch { if !Task.isCancelled { notices = [error.localizedDescription] } }
            }
        }.presentationDetents([.large]).presentationSizing(.form)
    }
    private func loadMore() async {
        let generation = revision
        paging = true
        defer { paging = false }
        do {
            let rows = try await CatalogAPI.shared.search(platform,kind:work.kind,query:submittedQuery,page:page + 1)
            guard revision == generation else { return }
            let before = results.count
            results = MediaLanguage.merge(results,rows); page += 1
            hasMore = !rows.isEmpty && results.count > before
        } catch { if revision == generation { notices.append(error.localizedDescription) } }
    }

}
