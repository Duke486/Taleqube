import SwiftUI
import AppIntents

@main
struct TalequbeApp: App {
    @AppStorage("workspace.destination") private var destination: ShelfDestination = .home
    @AppStorage(LocalReset.pendingKey) private var resetPending = false
    @Environment(\.scenePhase) private var scenePhase
    @State private var store = AppStore()
    @State private var tracking: TrackingStore?
    @State private var startupError: String?
    @State private var startupAttempt = 0
    @State private var pendingOpenURL: URL?
    var body: some Scene {
        WindowGroup {
            Group {
                if tracking != nil && resetPending {
                    ContentUnavailableView("已安排本机重置",systemImage:"arrow.counterclockwise",
                                           description:Text("请退出并重新打开 Taleqube。云端资料会保留。"))
                } else if let tracking {
                    TrackingView()
                        .environment(store)
                        .environment(tracking)
                        .tint(Color.accentColor)
                        .task { CloudSync.shared.start(tracking); await store.restore(); await PlatformLogin.shared.checkAccounts() }
                        .onChange(of:CloudSync.shared.lastSuccess) { _,_ in
                            Task { await store.restore(ifTokenChanged:true); await PlatformLogin.shared.checkAccounts() }
                        }
                        .onReceive(NotificationCenter.default.publisher(for:Credentials.didChange).receive(on:RunLoop.main)) { notification in
                            if let name = notification.object as? String, Credentials.names.contains(name) {
                                PlatformLogin.shared.credentialsDidChange()
                            }
                        }
                        .onReceive(NotificationCenter.default.publisher(for:AniListAPI.authorizationRejected).receive(on:RunLoop.main)) { notification in
                            if let token = notification.object as? String { AccountHealth.shared.invalidate(.anilist,token:token) }
                        }
                        .onChange(of:scenePhase) { _,phase in
                            if phase == .active { Task { await CloudSync.shared.synchronize(); await PlatformLogin.shared.checkAccounts() } }
                        }
                        .onAppear { if let url = pendingOpenURL { tracking.pendingArchiveURL = url; pendingOpenURL = nil } }
                } else if let startupError {
                    ContentUnavailableView {
                        Label("资料库暂时无法打开",systemImage:"externaldrive.badge.exclamationmark")
                    } description: { Text(startupError) } actions: {
                        Button("重试") { self.startupError = nil; startupAttempt += 1 }
                    }
                } else {
                    ZStack {
                        WorkspaceBackdrop()
                        VStack(spacing: 12) {
                            Image("BrandMark").resizable().scaledToFit().frame(width:88,height:88).accessibilityHidden(true)
                            Text("Taleqube").font(.largeTitle.bold())
                        }
                    }.frame(maxWidth:.infinity,maxHeight:.infinity)
                }
            }
            .task(id:startupAttempt) {
                guard tracking == nil else { return }
                do {
                    let directory = URL.applicationSupportDirectory.appending(path:"AniShelf")
                    try await Task.detached(priority:.userInitiated) { try LocalReset.apply(directory:directory) }.value
                    let prepared = try await PreparedTrackingLibrary.load(directory:directory,diagnostics:DiagnosticLog.shared)
                    let ready = TrackingStore(directory:directory,prepared:prepared)
                    if let error = ready.startupFailure { startupError = error }
                    else { tracking = ready }
                } catch { startupError = "原始数据已保留。" + error.localizedDescription }
            }
            .onOpenURL { url in
                if url.isFileURL && ["taleqube", "anishelf"].contains(url.pathExtension.lowercased()) {
                    if let tracking { tracking.pendingArchiveURL = url } else { pendingOpenURL = url }
                }
            }
        }
        .commands {
            CommandMenu("作品") {
                Button("首页") { destination = .home }.keyboardShortcut("1")
                Button("发现") { destination = .discover }.keyboardShortcut("2")
                Button("我的资料库") { destination = .library }.keyboardShortcut("3")
                Divider()
                Button("刷新") { tracking?.keyboardRefreshRequest = UUID() }.keyboardShortcut("r")
                Button("搜索作品") { destination = .discover; tracking?.wantsSearchFocus = true; tracking?.searchFocusRequest = UUID() }.keyboardShortcut("f")
            }
        }
    }
}
