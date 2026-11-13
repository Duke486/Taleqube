import SwiftUI
import UniformTypeIdentifiers

struct ConnectionsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var values:[String:String] = [:]
    @State private var savedValues:[String:String] = [:]
    @State private var leaving = false
    @State private var error = ""
    @State private var showLocalReset = false
    @State private var resetSeconds = 5
    @AppStorage(LocalReset.pendingKey) private var resetPending = false
    @State private var archivePassword = ""
    @State private var importPassword = ""
    @State private var importingArchive = false
    @State private var exportingArchive = false
    @State private var exportFile = false
    @State private var importFile = false
    @State private var readingArchive = false
    @State private var archiveReadError = ""
    @State private var exportDocument = LibraryDocument()
    @State private var diagnosticExport: DiagnosticExport?
    @State private var exportName = "AniShelf-library"
    @State private var bangumiAccount = ""
    @State private var category = "账号"
    @State private var cacheUsage = 0
    @State private var managingCache = false
    @State private var pendingArchive:Data?
    @State private var importSummary = ""
    @State private var dataNotice = ""
    @AppStorage("artwork.cacheLimitMB") private var cacheLimit = 512
    @State private var authenticating = false
    @AppStorage("anilist.clientID") private var anilistClientID = ""
    @Environment(AppStore.self) private var appStore
    @State private var traktLogin = false
    @Environment(TrackingStore.self) private var tracker
    var body: some View {
        NavigationStack { Form {
            if category == "账号" {
                Section {
                    Button("检查所有账号") { Task { await PlatformLogin.shared.checkAccounts(force:true) } }
                    NavigationLink { CloudSyncView() } label: {
                        VStack(alignment:.leading,spacing:4) {
                            Text("账号凭据云同步")
                            Text(CloudSync.shared.configuration.enabled ? (CloudSync.shared.error.map { "同步失败：" + $0 } ?? (CloudSync.shared.credentialsPending ? "凭据已保存 · 等待同步" : CloudSync.shared.phase)) : "未启用 · 仅保存到本机钥匙串")
                                .font(.caption).foregroundStyle(CloudSync.shared.error == nil ? Color.secondary : .red)
                        }
                    }
                } footer: { Text("启用云同步后，登录、刷新和断开连接会自动同步；连续修改合并上传，网络恢复后重试。加入加密资料库后，凭据随资料库加密传输。") }
                ForEach([Catalog.anilist,.trakt,.tmdb,.mal,.bangumi]) { service in
                    Section {
                        HStack {
                            Label(service.title,systemImage:service == .anilist ? "book.closed" : service == .tmdb ? "photo.on.rectangle" : "person.crop.circle")
                                .font(.headline)
                            Spacer()
                            let state = AccountHealth.shared.states[service]
                            Text(state?.title ?? (values["\(service.rawValue).token"]?.isEmpty == false ? "等待验证" : "未登录"))
                                .font(.caption).foregroundStyle(state == .expired ? Color.red : state == .unavailable ? .orange : .secondary)
                        }
                        if CloudSync.shared.conflictRows.contains(where:{ $0.id == "settings/credential/" + service.rawValue }) {
                            NavigationLink("此账号有同步冲突，选择凭据版本") { CloudSyncView() }.foregroundStyle(.orange)
                        }
                        if AccountHealth.shared.states[service] == .expired {
                            Label("请使用下方登录入口重新授权",systemImage:"exclamationmark.triangle.fill")
                                .font(.caption).foregroundStyle(.red)
                        }
                        Button("检查 \(service.title) 连接") { Task { await AccountHealth.shared.check(service,force:true,recover:{ try await PlatformLogin.shared.refresh($0) }) } }
                            .disabled(authenticating || (savedValues["\(service.rawValue).token"] ?? "").isEmpty || AccountHealth.shared.states[service] == .checking)
                        if service == .anilist {
                            TextField("Client ID",text:$anilistClientID).plainTextInput()
                            Button("登录 AniList") { Task {
                                authenticating = true
                                appStore.error = nil
                                await appStore.login(clientID:anilistClientID)
                                if let token = TokenVault.read(), appStore.error == nil {
                                    values["anilist.token"] = token
                                    savedValues["anilist.token"] = token
                                    do { try Credentials.write("anilist.token",token) } catch { self.error = error.localizedDescription }
                                } else { error = appStore.error ?? "登录未完成" }
                                authenticating = false
                            } }.disabled(anilistClientID.isEmpty || authenticating)
                            Link("创建 AniList 应用",destination:URL(string:"https://anilist.co/settings/developer")!)
                            Text("回调地址：anishelf://oauth").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        } else if service == .trakt || service == .mal {
                            TextField("Client ID",text:value("\(service.rawValue).clientID")).plainTextInput()
                            Button("登录 \(service.title)") { connect(service) }.disabled(authenticating || (values["\(service.rawValue).clientID"] ?? "").isEmpty)
                            Button("刷新登录") { Task {
                                authenticating = true; defer { authenticating = false }
                                do { try await PlatformLogin.shared.refresh(service); reload(service) } catch { self.error = error.localizedDescription }
                            } }.disabled(authenticating || (values["\(service.rawValue).refresh"] ?? "").isEmpty)
                            if service == .trakt {
                                Link("创建 Trakt 应用",destination:URL(string:"https://trakt.tv/oauth/applications")!)
                                Text("Redirect URI 填 http://localhost；登录时使用网页设备授权码。")
                                    .font(.caption).foregroundStyle(.secondary)
                            } else {
                                Link("创建 MyAnimeList 应用",destination:URL(string:"https://myanimelist.net/apiconfig")!)
                                Text("回调地址：anishelf://oauth/mal").font(.caption).foregroundStyle(.secondary)
                            }
                        } else {
                            SecureField(service == .tmdb ? "API Read Access Token" : "Access Token",text:value("\(service.rawValue).token")).plainTextInput()
                            if service == .tmdb {
                                Label((values["tmdb.session"] ?? "").isEmpty ? "评分账号未登录" : "已保存评分会话 · 有效性见连接状态",systemImage:(values["tmdb.session"] ?? "").isEmpty ? "person.crop.circle" : "person.crop.circle.badge.checkmark")
                                    .font(.subheadline).foregroundStyle(.secondary)
                                Button("登录 TMDB 账号") { Task {
                                    authenticating = true; defer { authenticating = false }
                                    do {
                                        let token = values["tmdb.token"] ?? ""
                                        try Credentials.write("tmdb.token",token); savedValues["tmdb.token"] = token
                                        try await PlatformLogin.shared.loginTMDB()
                                        values["tmdb.session"] = Credentials.read("tmdb.session"); savedValues["tmdb.session"] = values["tmdb.session"]
                                        error = ""
                                    } catch { self.error = error.localizedDescription }
                                } }.disabled(authenticating || (values["tmdb.token"] ?? "").isEmpty)
                                if !Credentials.read("tmdb.session").isEmpty {
                                    Button("退出 TMDB 评分账号",role:.destructive) { Task {
                                        authenticating = true; defer { authenticating = false }
                                        do { try await PlatformLogin.shared.logoutTMDB(); values["tmdb.session"] = ""; savedValues["tmdb.session"] = "" }
                                        catch { self.error = error.localizedDescription }
                                    } }.disabled(authenticating)
                                }
                            }
                            if service == .bangumi {
                                Button("验证并登录 Bangumi") { Task {
                                    authenticating = true; defer { authenticating = false }
                                    do { let token = (values["bangumi.token"] ?? "").trimmingCharacters(in:.whitespacesAndNewlines); bangumiAccount = try await CatalogAPI.shared.bangumiViewer(token:token); try Credentials.write("bangumi.token",token); savedValues["bangumi.token"] = token; error = "" }
                                    catch { self.error = error.localizedDescription }
                                } }.disabled(authenticating)
                                if !bangumiAccount.isEmpty { Label("已登录：" + bangumiAccount,systemImage:"checkmark.circle").foregroundStyle(.green) }
                            }
                            Link("获取 \(service.title) 令牌",destination:URL(string:service == .tmdb ? "https://www.themoviedb.org/settings/api" : "https://next.bgm.tv/demo/access-token")!)
                        }
                        if values["\(service.rawValue).token"]?.isEmpty == false {
                            Button("断开 \(service.title)",role:.destructive) {
                                do {
                                    try Credentials.writeValues(["\(service.rawValue).token":"","\(service.rawValue).refresh":""])
                                    if service == .anilist { appStore.logout() }
                                    if service == .tmdb { try Credentials.write("tmdb.session",""); values["tmdb.session"] = ""; savedValues["tmdb.session"] = "" }
                                    reload(service)
                                    Task { await tracker.refreshLibrary(); await tracker.refreshHistory() }
                                } catch { self.error = error.localizedDescription }
                            }
                        }
                        if [.anilist,.trakt,.mal].contains(service) {
                            DisclosureGroup("手动填写令牌") {
                                SecureField("Access Token",text:value("\(service.rawValue).token")).plainTextInput()
                                if service != .anilist { SecureField("Refresh Token",text:value("\(service.rawValue).refresh")).plainTextInput() }
                            }
                        }
                    }
                }
            }
            if category == "翻译与匹配" {
                Section { Text("用于查找中文名、翻译简介和匹配平台条目。") }
                ForEach(["openai","deepseek"],id:\.self) { service in
                    Section(service == "openai" ? "OpenAI" : "DeepSeek") {
                        SecureField("API Key",text:value("\(service).key")).plainTextInput()
                    }
                }
            }
            if category == "数据" {
                Section {
                    NavigationLink("云同步") { CloudSyncView() }
                    NavigationLink { DeliveryView() } label: {
                        HStack { Label("同步记录",systemImage:"clock.arrow.circlepath"); Spacer(); if tracker.deliveryErrorCount > 0 { Text("\(tracker.deliveryErrorCount)").foregroundStyle(.red) } }
                    }
                }
            Section("全部应用数据") {
                SecureField("备份密码（可选）",text:$archivePassword).textContentType(.newPassword)
                Button(exportingArchive ? "正在生成备份…" : "导出全部应用数据") {
                    exportingArchive = true
                    Task {
                        defer { exportingArchive = false }
                        do {
                            diagnosticExport = nil; exportName = "AniShelf-complete-backup"
                            var credentials = try Credentials.readValuesChecked(Credentials.names + LibraryImportRecovery.cloudCredentialNames)
                            if let token = try TokenVault.readChecked() { credentials["anilist.token"] = token }
                            exportDocument = LibraryDocument(data:try await tracker.exportApplicationDataAsync(credentials:credentials,password:archivePassword)); exportFile = true
                        } catch { self.error = error.localizedDescription }
                    }
                }.disabled(exportingArchive || importingArchive)
                Button(readingArchive ? "正在读取备份…" : importingArchive ? "正在导入…" : "导入应用数据") { importFile = true }.disabled(importingArchive || readingArchive)
                Text("包含资料库、评分进度、关联、同步队列、译文、观看记录、平台片单、偏好设置、诊断与账号密钥。设置备份密码后加密整个文件；不设密码时包含明文密钥。图片按需重新缓存。").font(.caption).foregroundStyle(.secondary)
                if readingArchive { ProgressView("正在读取并检查备份…") }
                if pendingArchive != nil {
                    Text("确认导入应用数据").font(.headline)
                    Text(importSummary).font(.callout)
                    if pendingArchive.map(LibraryArchive.isEncrypted) == true { SecureField("备份密码",text:$importPassword) }
                    Button("取消",role:.cancel) { pendingArchive = nil; importPassword = "" }
                    Button("导入",role:.destructive) {
                        guard let data = pendingArchive else { return }
                        guard !CloudSync.shared.running else { error = "请等待云同步完成后再导入"; return }
                        pendingArchive = nil
                        importingArchive = true
                        CloudSync.shared.importingBackup = true
                        Task {
                            defer { importingArchive = false; CloudSync.shared.importingBackup = false; importPassword = "" }
                        do {
                            let previousToken = try TokenVault.readChecked()
                            do {
                                try await tracker.importApplicationDataAsync(data,password:importPassword,writeCredential:{ values in
                                    try Credentials.writeValues(values)
                                    if let value = values["anilist.token"] {
                                        if value.isEmpty { try TokenVault.delete() } else { try TokenVault.write(value) }
                                    }
                                })
                            } catch {
                                do { if let previousToken { try TokenVault.write(previousToken) } else { try TokenVault.delete() } }
                                catch { throw APIError.message("导入失败，AniList 登录信息恢复失败：" + error.localizedDescription) }
                                throw error
                            }
                            CloudSync.shared.reloadAfterImport(tracker)
                            values = Dictionary(uniqueKeysWithValues:Credentials.names.map { ($0,Credentials.read($0)) }); savedValues = values
                            Task { await appStore.restore(); try? await PosterCache.shared.setLimit(megabytes:cacheLimit); cacheUsage = await PosterCache.shared.usage() }
                            dataNotice = "应用数据已导入"
                        } catch { self.error = error.localizedDescription }
                        }
                    }
                }
                if !archiveReadError.isEmpty { Text(archiveReadError).foregroundStyle(.red).textSelection(.enabled) }
                if !dataNotice.isEmpty { Text(dataNotice).font(.caption).foregroundStyle(.green) }
            }
            Section("图片缓存") {
                LabeledContent("已使用",value:ByteCountFormatter.string(fromByteCount:Int64(cacheUsage),countStyle:.file))
                Picker("缓存上限",selection:$cacheLimit) {
                    Text("不缓存").tag(0)
                    ForEach(Array(Set([128,256,512,1024,2048,4096,cacheLimit])).filter { $0 > 0 }.sorted(),id:\.self) { value in
                        Text("\(value) MiB").tag(value)
                    }
                }
                .onChange(of:cacheLimit) { _,value in Task {
                    managingCache = true; defer { managingCache = false }
                    do { try await PosterCache.shared.setLimit(megabytes:value); cacheUsage = await PosterCache.shared.usage() }
                    catch { self.error = error.localizedDescription }
                } }
                Button("清理全部图片缓存",role:.destructive) { Task {
                    managingCache = true; defer { managingCache = false }
                    do { try await PosterCache.shared.clear(); cacheUsage = await PosterCache.shared.usage() }
                    catch { self.error = error.localizedDescription }
                } }.disabled(managingCache)
                Text("封面、背景、剧照和剧集图片共用此上限，空间不足时优先清理最久未使用的图片。").font(.caption).foregroundStyle(.secondary)
            }
            Section("诊断") {
                Button("导出最近错误与警告") {
                    do { let snapshot = DiagnosticLog.shared.prepareExport(); exportDocument = LibraryDocument(data:try snapshot.data()); diagnosticExport = snapshot; exportName = "AniShelf-diagnostics"; exportFile = true }
                    catch { self.error = error.localizedDescription }
                }
                Text("仅导出上次成功导出之后、且最近 24 小时内的错误与警告。取消导出不会清除记录。").font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Button("彻底重置本机",role:.destructive) {
                    resetSeconds = 5
                    showLocalReset = true
                }.disabled(CloudSync.shared.running || authenticating || exportingArchive)
            }
            }
            if authenticating { ProgressView("正在连接") }
            if category != "数据" {
                Section {
                    Button("保存账号配置") {
                        do { try saveConfiguration(); dataNotice = "账号配置已保存" }
                        catch { self.error = error.localizedDescription }
                    }
                    if dataNotice == "账号配置已保存" { Text(dataNotice).foregroundStyle(.secondary) }
                } footer: { Text("手动输入的令牌与 API Key 在保存后生效。登录、断开连接和数据操作立即生效。") }
            }
        }
        .safeAreaInset(edge:.top) {
            ShelfTabs(values:["账号","翻译与匹配","数据"],selection:$category,title:{ $0 }).padding(.horizontal,20).padding(.vertical,12).background(.bar)
        }
        .disabled(importingArchive || readingArchive)
        .scrollContentBackground(.hidden).background(Color(.systemGroupedBackground)).navigationTitle("设置").inlineNavigationTitle()
        .toolbar { ToolbarItem(placement:.confirmationAction) { Button("完成") { if values != savedValues { leaving = true } else { dismiss() } }.disabled(importingArchive || readingArchive) } }
        .interactiveDismissDisabled(values != savedValues || importingArchive || readingArchive)
        .confirmationDialog("账号配置尚未保存",isPresented:$leaving,titleVisibility:.visible) {
            Button("保存并关闭") { do { try saveConfiguration(); dismiss() } catch { self.error = error.localizedDescription } }
            Button("放弃手动修改",role:.destructive) { dismiss() }
            Button("继续编辑",role:.cancel) { }
        }
        .alert("操作未完成",isPresented:Binding(get:{ !error.isEmpty },set:{ if !$0 { error = "" } })) { Button("好") { error = "" } } message: { Text(error) }
        .sheet(isPresented:$traktLogin,onDismiss:{ for key in Credentials.names.filter({ $0.hasPrefix("trakt.") }) { values[key] = Credentials.read(key); savedValues[key] = values[key] } }) { TraktDeviceLoginView() }
        .sheet(isPresented:$showLocalReset) {
            VStack(alignment:.leading,spacing:16) {
                Text("彻底重置本机？").font(.headline)
                Text("退出并重新打开后，将清空本机资料库、设置和登录凭据，并退出同步。云端资料会保留。")
                HStack {
                    Button("取消") { showLocalReset = false }
                    Spacer()
                    Button(resetSeconds > 0 ? "确认重置（\(resetSeconds) 秒）" : "确认重置",role:.destructive) {
                        guard resetSeconds == 0, !CloudSync.shared.running else { return }
                        showLocalReset = false
                        resetPending = true
                    }.disabled(resetSeconds > 0 || CloudSync.shared.running)
                }
            }.padding()
                .presentationDetents([.height(230)])
                .task {
                    do {
                        while resetSeconds > 0 {
                            try await Task.sleep(for:.seconds(1))
                            resetSeconds -= 1
                        }
                    } catch {}
                }
        }
        .fileExporter(isPresented:$exportFile,document:exportDocument,contentType:diagnosticExport == nil ? .aniShelfArchive : .json,defaultFilename:exportName) { result in
            switch result {
            case .success: if let snapshot = diagnosticExport { DiagnosticLog.shared.markExported(snapshot) }
            case .failure(let failure): error = failure.localizedDescription
            }
            diagnosticExport = nil
        }
        .fileImporter(isPresented:Binding(get:{ importFile && ProcessInfo.processInfo.isiOSAppOnMac },set:{ importFile = $0 }),allowedContentTypes:[.aniShelfArchive]) { result in
            switch result {
            case .success(let url): beginReadingArchive(url)
            case .failure(let failure):
                archiveReadError = "读取备份失败：" + failure.localizedDescription
                DiagnosticLog.shared.record(component:"archive-import",message:archiveReadError)
            }
        }
        .sheet(isPresented:Binding(get:{ importFile && !ProcessInfo.processInfo.isiOSAppOnMac },set:{ importFile = $0 })) {
            ArchiveFilePicker { url in
                importFile = false
                guard let url else { return }
                beginReadingArchive(url)
            }
        }
        .task(id:tracker.pendingArchiveURL) {
            guard let url = tracker.pendingArchiveURL else { return }
            tracker.pendingArchiveURL = nil; category = "数据"
            beginReadingArchive(url)
        }
        .task { cacheUsage = await PosterCache.shared.usage() }
        .task { await PlatformLogin.shared.checkAccounts() }
        .onReceive(NotificationCenter.default.publisher(for:Credentials.didChange).receive(on:RunLoop.main)) { notification in
            guard let key = notification.object as? String, Credentials.names.contains(key), values[key] == savedValues[key] else { return }
            values[key] = Credentials.read(key); savedValues[key] = values[key]
        }
        .onAppear { values = Dictionary(uniqueKeysWithValues:Credentials.names.map { ($0,Credentials.read($0)) }); if values["anilist.token"]?.isEmpty != false { values["anilist.token"] = TokenVault.read() ?? "" }; savedValues = values }

    }
    }
    @MainActor private func beginReadingArchive(_ url:URL) {
        guard !readingArchive && !importingArchive else { return }
        category = "数据"
        pendingArchive = nil
        archiveReadError = ""
        dataNotice = ""
        readingArchive = true
        Task { await readArchive(url) }
    }

    @MainActor private func readArchive(_ url:URL) async {
        defer { readingArchive = false }
        do {
            let data = try await Task.detached(priority:.userInitiated) {
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                let coordinator = NSFileCoordinator()
                var coordinationError:NSError?
                var result:Result<Data,Error>?
                coordinator.coordinate(readingItemAt:url,options:[],error:&coordinationError) { readableURL in
                    result = Result { try Data(contentsOf:readableURL,options:.mappedIfSafe) }
                }
                if let coordinationError { throw coordinationError }
                guard let result else { throw APIError.message("无法读取所选备份文件") }
                let data = try result.get()
                _ = try LibraryArchive.version(data)
                return data
            }.value
            importSummary = "将恢复备份中的资料库、偏好、凭据和同步队列。备份中的云连接恢复后需手动启用。"
            importPassword = ""; pendingArchive = data
        } catch {
            archiveReadError = "读取备份失败：" + error.localizedDescription
            DiagnosticLog.shared.record(component:"archive-import",message:archiveReadError)
        }
    }

    private func saveConfiguration() throws {
        let previous = try Credentials.readValuesChecked(Credentials.names)
        let previousAniList = try TokenVault.readChecked()
        do {
            let changes = values.filter { $0.value != savedValues[$0.key] }.mapValues { $0.trimmingCharacters(in:.whitespacesAndNewlines) }
            try Credentials.writeValues(changes)
            if let token = changes["anilist.token"] {
                if token.isEmpty { try TokenVault.delete() } else { try TokenVault.write(token) }
            }
            values = Dictionary(uniqueKeysWithValues:try Credentials.names.map { ($0,try Credentials.readChecked($0)) }); savedValues = values
            Task { await appStore.restore() }
        } catch {
            var rollbackErrors: [String] = []
            for group in Dictionary(grouping:previous.keys,by:{ String($0.split(separator:".")[0]) }).values {
                do { try Credentials.writeValues(previous.filter { group.contains($0.key) }) }
                catch { rollbackErrors.append(contentsOf:group) }
            }
            do { if let previousAniList { try TokenVault.write(previousAniList) } else { try TokenVault.delete() } }
            catch { rollbackErrors.append("AniList 登录令牌") }
            if !rollbackErrors.isEmpty { throw APIError.message("配置保存失败，以下项目恢复失败：" + rollbackErrors.joined(separator:"、")) }
            throw error
        }
    }
    private func value(_ key:String) -> Binding<String> {
        Binding(get:{ values[key] ?? "" },set:{ values[key] = $0 })
    }
    private func reload(_ service:Catalog) {
        for key in Credentials.names where key.hasPrefix(service.rawValue + ".") { values[key] = Credentials.read(key); savedValues[key] = values[key] }
    }
    private func connect(_ service:Catalog) {
        do {
            let key = "\(service.rawValue).clientID"
            try Credentials.write(key,(values[key] ?? "").trimmingCharacters(in:.whitespacesAndNewlines))
            if service == .trakt { traktLogin = true }
            else { Task {
                authenticating = true; defer { authenticating = false }
                do { try await PlatformLogin.shared.login(service); reload(service) } catch { self.error = error.localizedDescription }
            } }
        } catch { self.error = error.localizedDescription }
    }

}

extension UTType { static let aniShelfArchive = UTType(exportedAs:LibraryArchive.typeIdentifier,conformingTo:.data) }

private struct ArchiveFilePicker: UIViewControllerRepresentable {
    var onSelection:(URL?) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(onSelection:onSelection) }
    func makeUIViewController(context:Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes:[.aniShelfArchive],asCopy:true)
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ controller:UIDocumentPickerViewController,context:Context) {}
    final class Coordinator:NSObject,UIDocumentPickerDelegate {
        let onSelection:(URL?) -> Void
        init(onSelection:@escaping(URL?) -> Void) { self.onSelection = onSelection }
        private var completed = false
        func documentPicker(_ controller:UIDocumentPickerViewController,didPickDocumentsAt urls:[URL]) {
            guard !completed else { return }; completed = true
            onSelection(urls.first)
        }
        func documentPickerWasCancelled(_ controller:UIDocumentPickerViewController) {
            guard !completed else { return }; completed = true
            onSelection(nil)
        }
    }
}

struct LibraryDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.aniShelfArchive] }
    var data: Data = Data()
    init(data:Data = Data()) { self.data = data }
    init(configuration:ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration:WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents:data) }
}

struct TraktDeviceLoginView:View {
    @Environment(\.dismiss) private var dismiss
    @State private var code:PlatformLogin.DeviceCode?
    @State private var error = ""
    var body:some View {
        NavigationStack {
            Form {
                if let code {
                    Section("Trakt 授权码") {
                        Text(code.user_code).font(.title.monospaced()).textSelection(.enabled)
                        Button("复制授权码") { UIPasteboard.general.string = code.user_code }
                        Link("打开 Trakt 授权网页",destination:code.verification_url)
                        Text("在网页输入授权码并允许访问，完成后返回 AniShelf。授权成功后此窗口会自动关闭。")
                    }
                }
                if error.isEmpty {
                    HStack { ProgressView(); Text(code == nil ? "正在获取授权码…" : "等待 Trakt 授权…") }
                } else { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle("登录 Trakt")
            .toolbar { ToolbarItem(placement:.cancellationAction) { Button("关闭") { dismiss() } } }
        }
        .task {
            do {
                try await PlatformLogin.shared.loginTrakt { code = $0 }
                dismiss()
            } catch {
                guard !Task.isCancelled else { return }
                self.error = error.localizedDescription
            }
        }
    }
}
