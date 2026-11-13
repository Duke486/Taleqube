import SwiftUI

struct SettingsView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @AppStorage("anilist.clientID") private var clientID = ""
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 16) {
                        Image(systemName: "rectangle.stack.fill").font(.largeTitle).foregroundStyle(.indigo)
                        VStack(alignment: .leading, spacing: 5) {
                            Text("AniShelf").font(.title2.bold())
                            Text("电影、剧集与书籍收藏").font(.subheadline).foregroundStyle(.secondary)
                        }
                    }.padding(.vertical, 12)
                }
                Section("AniList 账号") {
                    if let viewer = store.viewer {
                        LabeledContent("已登录", value: viewer.name)
                        Button("退出登录", role: .destructive) { store.logout() }
                    } else {
                        TextField("Client ID", text: $clientID).plainTextInput()
                            .accessibilityLabel("AniList Client ID")
                        Button {
                            Task {
                                store.error = nil
                                await store.login(clientID: clientID)
                                if store.viewer != nil { dismiss() }
                            }
                        } label: {
                            HStack {
                                Label("使用 AniList 登录", systemImage: "person.crop.circle.badge.checkmark")
                                if store.auth.isAuthenticating { Spacer(); ProgressView() }
                            }
                        }.buttonStyle(.glassProminent)
                        .disabled(clientID.isEmpty || store.auth.isAuthenticating)
                        if let error = store.error { Text(error).font(.caption).foregroundStyle(.red) }
                    }
                }
                Section {
                    Link("打开 AniList 开发者设置", destination: URL(string: "https://anilist.co/settings/developer")!)
                    Text("创建应用，名称填 AniShelf，Redirect URL 填下面的地址。然后把生成的 Client ID 填到上方。")
                        .font(.subheadline).foregroundStyle(.secondary)
                    Text(OAuthCallback.redirect).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                    Text("无需填写 Client Secret。登录在系统授权窗口完成，访问令牌保存在本机钥匙串；启用云同步后自动同步凭据；加入加密资料库可加密上传。")
                        .font(.caption).foregroundStyle(.secondary)
                } header: { Text("首次连接") }
                Section("操作") {
                    LabeledContent("搜索", value: "⌘F")
                    LabeledContent("刷新", value: "⌘R")
                    LabeledContent("探索 / 我的片单", value: "⌘1 / ⌘2")
                    LabeledContent("保存片单", value: "⌘↩")
                }
                Section {
                    Text("作品、封面与片单数据来自 AniList。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .scrollContentBackground(.hidden)
            .background { WorkspaceBackdrop() }
            .navigationTitle("账号与设置")
            .inlineNavigationTitle()
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() }.buttonStyle(.glassProminent) } }
        }.presentationSizing(.form)
            .presentationDetents([.large])
    }
}
