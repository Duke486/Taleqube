import SwiftUI

struct MappingEditorView: View {
    let association: PlatformAssociation
    let tmdb: Work
    let units: [ViewingUnit]
    var onSave: (ContentMapping,AssociationScope) -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var selectedSeasons = Set<Int>()
    @State private var whole = false
    @State private var overall = false
    @State private var complete = false
    @State private var count = ""
    @State private var rows: [EpisodeCorrespondence] = []
    @State private var platformFirst = 1
    @State private var tmdbSeason = 1
    @State private var tmdbFirst = 1
    @State private var length = 1
    @State private var mode = "连续一对一"
    @State private var error: String?
    @State private var loading = false
    var body: some View {
        NavigationStack {
            Form {
                Section(association.target.title) {
                    Toggle("整部条目",isOn:$whole)
                    ForEach(units) { unit in
                        Toggle(unit.title,isOn:Binding(get:{ selectedSeasons.contains(unit.season) },set:{ enabled in
                            if enabled { selectedSeasons.insert(unit.season) } else { selectedSeasons.remove(unit.season) }
                        }))
                    }
                    Text("只勾选已确认覆盖的 TMDB 季。特别篇和未来新季不会自动加入。").font(.caption).foregroundStyle(.secondary)
                    if selectedSeasons.count > 1 { Toggle("使用整部评分",isOn:$overall) }
                }
                Section("集对应关系") {
                    TextField("平台正片总集数",text:$count).keyboardType(.numberPad)
                    ForEach(Array(rows.enumerated()),id:\.offset) { index,row in
                        HStack {
                            Text(row.platformEpisodes.map(String.init).joined(separator:",") + " → " + row.tmdbEpisodes.map { "S\($0.season)E\($0.number)" }.joined(separator:","))
                                .font(.caption)
                            Spacer()
                            Button("移除",role:.destructive) { rows.remove(at:index) }.buttonStyle(.borderless)
                        }
                    }
                    Toggle("已覆盖平台全部内容",isOn:$complete)
                    Text("未建立集映射时仍可继承已确认季的评分；进度暂停同步。").font(.caption).foregroundStyle(.secondary)
                }
                Section("添加对应") {
                    Picker("方式",selection:$mode) { ForEach(["连续一对一","平台一集对应多集","平台多集对应一集"],id:\.self) { Text($0) } }
                    Stepper("平台起始集：\(platformFirst)",value:$platformFirst,in:1...100000)
                    Picker("TMDB 季",selection:$tmdbSeason) { ForEach(units) { Text($0.title).tag($0.season) } }
                    Stepper("TMDB 起始集：\(tmdbFirst)",value:$tmdbFirst,in:1...100000)
                    Stepper("集数：\(length)",value:$length,in:1...500)
                    Button("添加映射") { appendMapping() }
                }
                if let map = association.mapping {
                    Section("匹配依据") {
                        Text(map.reason)
                        ForEach(map.evidence) { item in
                            if let raw = item.url, let url = URL(string:raw) { Link(item.title,destination:url) }
                            else { Text(item.title) }
                        }
                    }
                }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle("内容对应")
            .toolbar {
                ToolbarItem(placement:.cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement:.confirmationAction) { Button(loading ? "校验中…" : "保存") { Task { await save() } }.disabled(loading || selectedSeasons.isEmpty) }
            }
            .onAppear {
                let map = association.mapping
                selectedSeasons = Set(map?.seasons ?? (association.scope == .season ? [association.season] : units.filter { $0.season > 0 }.map(\.season)))
                whole = association.scope == .whole; overall = map?.useOverallRating ?? false
                rows = map?.episodes ?? []; complete = map?.complete ?? false
                count = map?.platformEpisodeCount.map(String.init) ?? ""
                tmdbSeason = units.first?.season ?? 1
            }
        }.presentationSizing(.form)
    }
    private func appendMapping() {
        if mode == "连续一对一" {
            rows += (0..<length).map { EpisodeCorrespondence(platformEpisodes:[platformFirst + $0],tmdbEpisodes:[EpisodeAddress(season:tmdbSeason,number:tmdbFirst + $0)]) }
        } else if mode == "平台一集对应多集" {
            rows.append(EpisodeCorrespondence(platformEpisodes:[platformFirst],tmdbEpisodes:(0..<length).map { EpisodeAddress(season:tmdbSeason,number:tmdbFirst + $0) }))
        } else {
            rows.append(EpisodeCorrespondence(platformEpisodes:Array(platformFirst..<(platformFirst + length)),tmdbEpisodes:[EpisodeAddress(season:tmdbSeason,number:tmdbFirst)]))
        }
        selectedSeasons.insert(tmdbSeason)
    }
    private func save() async {
        loading = true; defer { loading = false }
        do {
            let catalog = try await CatalogAPI.shared.matchingCatalog(tmdb)
            var map = ContentMapping(tmdbID:tmdb.remoteID,confirmed:true,seasons:selectedSeasons.sorted(),coverage:"unknown",episodes:rows,
                                     platformEpisodeCount:Int(count),complete:complete,manual:true,useOverallRating:overall,reason:"人工确认内容对应")
            if !count.isEmpty && Int(count) == nil { throw APIError.message("请输入有效的平台总集数") }
            try map.validate(seasonCounts:catalog.counts)
            // Validate actual TMDB addresses, including holes in non-contiguous season numbering.
            for number in Set(rows.flatMap { $0.tmdbEpisodes.map(\.season) }) {
                let actual = try await CatalogAPI.shared.episodes(tmdb,season:number)
                let ids = Set(actual.map(\.number))
                guard rows.flatMap(\.tmdbEpisodes).filter({ $0.season == number }).allSatisfy({ ids.contains($0.number) }) else { throw APIError.message("映射中有不存在的 TMDB 集") }
            }
            map.updatedAt = Date()
            if onSave(map,whole || selectedSeasons.count > 1 ? .whole : .season) { dismiss() }
            else { error = "保存失败，请重试" }
        } catch { self.error = error.localizedDescription }
    }
}
