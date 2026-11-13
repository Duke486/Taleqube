import SwiftUI

struct MediaDetailView: View {
    @Environment(AppStore.self) private var store
    let media: Media
    @State private var entry: EntryValue?
    @State private var loadingEntry = false
    @State private var entryError: String?
    @State private var showEditor = false
    @State private var saved = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                hero
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 28) {
                        synopsis.frame(minWidth: 290, maxWidth: .infinity)
                        information.frame(width: 210)
                    }
                    VStack(alignment: .leading, spacing: 28) { synopsis; information }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 40)
            }
            .frame(maxWidth: 900)
            .frame(maxWidth: .infinity)
        }
        .background { WorkspaceBackdrop() }
        .navigationTitle(media.title.display)
        .inlineNavigationTitle()
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if let url = media.siteUrl.flatMap(URL.init(string:)) {
                    ShareLink(item: url) { Label("分享", systemImage: "square.and.arrow.up") }
                    Link(destination: url) { Label("在 AniList 打开", systemImage: "arrow.up.right.square") }
                }
            }
        }
        .task(id: store.viewer?.id) { await fetchEntry() }
        .sheet(isPresented: $showEditor) {
            EntryEditor(media: media, initial: entry) { value in
                entry = value; store.apply(value, to: media); saved = true
            }
        }
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 22) {
            ZStack(alignment: .bottomLeading) {
                if let banner = media.bannerImage.flatMap(URL.init(string:)) {
                    CoverImage(url: banner)
                } else { LinearGradient(colors: [.indigo.opacity(0.7), .purple.opacity(0.35), .canvas], startPoint: .topLeading, endPoint: .bottomTrailing) }
                LinearGradient(colors: [.clear, Color.canvas], startPoint: .top, endPoint: .bottom)
            }.frame(height: 160).accessibilityHidden(true)
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 20) {
                    heroCover
                    heroTitle.frame(minWidth: 220, maxWidth: .infinity, alignment: .leading)
                }
                VStack(alignment: .leading, spacing: 16) { heroCover; heroTitle }
            }.padding(.horizontal, 24)
            HStack(spacing: 18) {
                metric(media.averageScore.map { "\($0)%" } ?? "—", label: "社区评分")
                Divider().frame(height: 32)
                metric(media.total.map(String.init) ?? "—", label: "总\(media.unit)数")
                Divider().frame(height: 32)
                metric(media.seasonYear.map(String.init) ?? "—", label: "年份")
                Spacer(minLength: 0)
            }.padding(.horizontal, 24)
            tracking.padding(.horizontal, 24)
        }
    }

    private var heroCover: some View {
        CoverImage(url: media.coverURL).frame(width: 112, height: 160)
            .clipShape(.rect(cornerRadius: 12))
            .shadow(color: .black.opacity(0.12), radius: 12, y: 6)
    }
    private var heroTitle: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(media.type == .manga ? "书籍" : "动画")
                .font(.caption.bold()).tracking(2).foregroundStyle(.secondary)
            Text(media.title.display).font(.title2.bold()).fixedSize(horizontal: false, vertical: true)
            if !media.title.subtitle.isEmpty {
                Text(media.title.subtitle).font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func metric(_ value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value).font(.title3.weight(.semibold)).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }
    private var tracking: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let entry {
                HStack {
                    StatusBadge(text:entry.status.title)
                    Spacer()
                    Text("\(entry.progress) / \(media.total.map(String.init) ?? "—") \(media.unit)")
                        .font(.subheadline).monospacedDigit().foregroundStyle(.secondary)
                }
                if let total = media.total, total > 0 {
                    ProgressView(value: Double(min(entry.progress, total)), total: Double(total)).tint(.indigo)
                }
            }
            if let entryError {
                Text(entryError).font(.caption).foregroundStyle(.red)
                Button("重新读取片单状态") { Task { await fetchEntry() } }.font(.caption)
            }
            HStack {
                Button {
                    if store.viewer == nil { store.showingSettings = true } else { showEditor = true }
                } label: {
                    Label(store.viewer == nil ? "登录后加入片单" : entry == nil ? "加入我的片单" : "更新进度",
                          systemImage: entry == nil ? "plus" : "slider.horizontal.3")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .disabled(loadingEntry || (store.viewer != nil && entryError != nil))
                if loadingEntry { ProgressView().controlSize(.small) }
                if saved { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).accessibilityLabel("已同步到 AniList") }
            }
        }
        .padding(16)
        .glassPanel()
    }
    private var synopsis: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("简介").font(.headline)
            Text(cleanDescription).font(.body).foregroundStyle(.secondary).lineSpacing(6).textSelection(.enabled)
            if let genres = media.genres, !genres.isEmpty {
                Text(genres.joined(separator: "  ·  ")).font(.caption.weight(.medium)).foregroundStyle(.indigo)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private var information: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("作品资料").font(.headline)
            info("发行状态", media.releaseStatus)
            info("形式", media.format?.replacingOccurrences(of: "_", with: " ") ?? "—")
            info("罗马字标题", media.title.romaji ?? "—")
            info("数据来源", "AniList")
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .glassPanel()
    }
    private func info(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.subheadline).textSelection(.enabled)
        }
    }
    private var cleanDescription: String {
        guard let text = media.description, !text.isEmpty else { return "这部作品暂时没有简介。" }
        return text.replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&#039;", with: "'")
            .replacingOccurrences(of: "&nbsp;", with: " ").replacingOccurrences(of: "&amp;", with: "&")
    }
    private func fetchEntry() async {
        entry = nil; entryError = nil; saved = false
        guard store.viewer != nil, let token = store.auth.token else { return }
        loadingEntry = true
        defer { loadingEntry = false }
        do {
            let value = try await AniListAPI.shared.entry(mediaID: media.id, token: token)
            try Task.checkCancellation()
            guard store.auth.token == token else { return }
            entry = value
        } catch is CancellationError { }
        catch let failure as URLError where failure.code == .cancelled { }
        catch {
            if case APIError.unauthorized = error { store.handle(error,token:token) }
            entryError = error.localizedDescription
        }
    }
}

struct EntryEditor: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let media: Media
    let onSave: (EntryValue) -> Void
    @State private var status: ListStatus
    @State private var progress: Int
    @State private var score: Double
    @State private var saving = false
    @State private var error: String?

    init(media: Media, initial: EntryValue?, onSave: @escaping (EntryValue) -> Void) {
        self.media = media; self.onSave = onSave
        _status = State(initialValue: initial?.status ?? .planning)
        _progress = State(initialValue: initial?.progress ?? 0)
        _score = State(initialValue: initial?.score ?? 0)
    }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 14) {
                        CoverImage(url: media.coverURL).frame(width: 48, height: 68).clipShape(.rect(cornerRadius: 6))
                        Text(media.title.display).font(.headline)
                    }
                }
                Section("片单状态") {
                    Picker("状态", selection: $status) {
                        ForEach(ListStatus.allCases) { Text($0.title).tag($0) }
                    }
                    LabeledContent("进度") {
                        TextField("集数 / 话数", value: $progress, format: .number.grouping(.never))
                            .multilineTextAlignment(.trailing)
                            .frame(minWidth: 80, maxWidth: 140)
                            .accessibilityLabel("已看或已读数量")
                            #if os(iOS)
                            .keyboardType(.numberPad)
                            #endif
                    }
                    Stepper(value: $progress, in: 0...max(media.total ?? 99999, progress)) {
                        LabeledContent("已看 / 已读", value: "\(progress) \(media.unit)")
                    }
                    if let total = media.total, total > 0 {
                        Button("标记全部完成（\(total)\(media.unit)）") { progress = total; status = .completed }
                    }
                }
                Section {
                    LabeledContent("我的评分", value: score == 0 ? "未评分" : "\(Int(score)) / 100")
                    Slider(value: $score, in: 0...100, step: 1).accessibilityLabel("我的评分")
                } footer: { Text("保存后立即同步到你的 AniList 账号。") }
                if let error { Section { Text(error).foregroundStyle(.red) } }
            }
            .scrollContentBackground(.hidden)
            .background { WorkspaceBackdrop() }
            .navigationTitle("编辑片单")
            .inlineNavigationTitle()
            .disabled(saving)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.buttonStyle(.glass).disabled(saving) }
                ToolbarItem(placement: .confirmationAction) {
                    Button { Task { await save() } } label: {
                        if saving { ProgressView() } else { Text("保存").bold() }
                    }.buttonStyle(.glassProminent).disabled(saving || store.auth.token == nil)
                        .keyboardShortcut(.return, modifiers: .command)
                }
            }
        }
        .onChange(of: progress) { _, value in
            progress = min(max(0, value), media.total ?? 99999)
        }
        .presentationSizing(.form)
        .interactiveDismissDisabled(saving)
        .presentationDetents([.large])
    }
    private func save() async {
        guard let token = store.auth.token else { return }
        saving = true; error = nil
        defer { saving = false }
        do {
            let value = try await AniListAPI.shared.save(mediaID: media.id, status: status, progress: progress, score: score, token: token)
            guard store.auth.token == token else { dismiss(); return }
            onSave(value); dismiss()
        } catch {
            if case APIError.unauthorized = error { store.handle(error,token:token) }
            self.error = error.localizedDescription
        }
    }
}
