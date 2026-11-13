import SwiftUI
import UIKit

struct CloudSyncView:View {
    @State private var sync = CloudSync.shared
    @State private var config = CloudSync.shared.configuration
    @State private var access = ""
    @State private var secret = ""
    @State private var message = ""
    @State private var confirmReset = false
    @State private var confirmPreferCloud = false
    @State private var showImport = false
    @State private var importCode = ""
    @State private var importError = ""
    @State private var busy = false
    @State private var loaded = false
    @State private var showRecovery = false
    @State private var recoveryCode = ""
    @State private var recoveryError = ""
    @State private var showAccess = false
    @State private var showSecret = false
    @State private var revealRecovery = false
    @State private var recoveryPreview = ""
    @State private var showConnection = false
    var body:some View {
        Form {
            Section("同步状态") {
                LabeledContent("状态",value:sync.running ? "正在同步…" : sync.error != nil ? "同步未完成" : !sync.configuration.enabled ? "未启用" : "已启用")
                if sync.running { ProgressView() }
                if let date = sync.lastSuccess { LabeledContent("上次同步",value:date.formatted()) }
                if sync.configuration.enabled {
                    Button("立即同步") { Task { await sync.synchronize() } }.disabled(sync.running || busy)
                    Button("停用同步") { config = sync.configuration; config.enabled = false; saveSettings() }.disabled(sync.running || busy || !loaded)
                }
            }
            Section("添加设备") {
                if sync.configuration.enabled && sync.encryptedLibraryID != nil {
                    Button("复制同步加入码") {
                        do {
                            guard let key = try CloudKeyStore.load() else { throw S3Failure.message("本机没有恢复码") }
                            let value = S3SettingsTransfer(configuration:sync.configuration,access:try Credentials.readChecked("cloud.access"),secret:try Credentials.readChecked("cloud.secret"),recovery:try key.encoded())
                            UIPasteboard.general.string = try value.encoded()
                            message = "已复制同步加入码，含连接和解密密钥"
                        } catch { message = error.localizedDescription }
                    }.disabled(sync.running || busy)
                }
                Button("粘贴加入码或恢复码") { recoveryCode = ""; recoveryError = ""; showRecovery = true }
                    .disabled(sync.running || busy)
                if !message.isEmpty { Text(message).font(.caption) }
            }
            Section {
                Button(sync.configuration.enabled ? "连接设置" : "手动设置同步") {
                    config = sync.configuration
                    if !config.enabled { config.enabled = true }
                    showConnection = true
                }.disabled(busy || !loaded || sync.running)
            }
            if !sync.deletedItems.isEmpty || !sync.deliveryHistory.isEmpty || !sync.conflictRows.isEmpty {
                Section {
                    NavigationLink("同步内容与冲突") {
                        List {
                            if !sync.deletedItems.isEmpty {
                                Section("已删除作品") {
                                    ForEach(sync.deletedItems) { item in
                                        VStack(alignment:.leading) {
                                            Text(item.title)
                                            Text(item.date.formatted()).font(.caption).foregroundStyle(.secondary)
                                            Button("恢复作品") { Task { await sync.restoreItem(item.id) } }.disabled(sync.running)
                                        }
                                    }
                                }
                            }
                            if !sync.deliveryHistory.isEmpty {
                                Section("各设备平台投递历史") {
                                    ForEach(sync.deliveryHistory.prefix(100)) { delivery in
                                        VStack(alignment:.leading) {
                                            Text(delivery.record.work.title)
                                            Text(delivery.target.source.title + " · " + delivery.state).font(.caption)
                                            if let error = delivery.errorDetail { Text(error).font(.caption).foregroundStyle(.red) }
                                        }
                                    }
                                }
                            }
                            ForEach(sync.conflictRows) { conflict in
                                Section("并发修改：" + conflict.id) {
                                    ForEach(conflict.versions) { version in
                                        VStack(alignment:.leading,spacing:6) {
                                            Text(version.timestamp.formatted()).font(.caption)
                                            Text("设备 " + String(version.device.prefix(8))).font(.caption).foregroundStyle(.secondary)
                                            if conflict.id.contains("credential/") { Text("账号凭据版本（内容隐藏）") }
                                            else { Text(version.value.flatMap { String(data:$0,encoding:.utf8) }.map { String($0.prefix(1000)) } ?? "删除 / 清除").font(.caption).textSelection(.enabled) }
                                            Button("采用此版本") { Task { await sync.resolve(conflict.id,operation:version.id) } }.disabled(sync.running)
                                        }
                                    }
                                }
                            }
                        }.navigationTitle("同步内容与冲突")
                    }
                }
            }
            Section {
                NavigationLink("详细日志") {
                    List {
                        Section("当前运行") {
                            Text(sync.phase)
                            if let error = sync.error { Text(error).textSelection(.enabled) }
                            Text("下载 \(sync.traffic.download) B · 上传 \(sync.traffic.upload) B · 校验 \(sync.traffic.verification) B")
                            Text("列表 \(sync.traffic.listing) B · 其他 \(sync.traffic.other) B · 重试 \(sync.traffic.retryUpload + sync.traffic.retryDownload) B")
                            ForEach(sync.queueCategories) { category in
                                LabeledContent(category.id,value:"\(category.count) 项 · \(category.bytes) B")
                            }
                        }
                        Section("运行记录") {
                            ForEach(Array(sync.events.enumerated()),id:\.offset) { _,event in Text(event).textSelection(.enabled) }
                        }
                    }.navigationTitle("详细日志")
                }
            }
        }.navigationTitle("云同步")
            .sheet(isPresented:$showConnection) {
                NavigationStack {
                    Form {
                        Section("连接设置") {
                            TextField("Endpoint",text:$config.endpoint).plainTextInput()
                            if config.endpoint.trimmingCharacters(in:.whitespacesAndNewlines).lowercased().hasPrefix("http://"),
                               let endpoint = config.connectionEndpoint, endpoint.scheme == "https" {
                                Text("实际连接地址：\(endpoint.string ?? "")").font(.caption).foregroundStyle(.secondary)
                            }
                            keyField("Access Key",text:$access,revealed:$showAccess)
                            keyField("Secret Key",text:$secret,revealed:$showSecret)
                            TextField("Bucket（S3 空间名）",text:$config.bucket).plainTextInput()
                            TextField("Region ID",text:$config.regionID).plainTextInput()
                            DisclosureGroup("高级选项") {
                                Picker("寻址方式",selection:$config.addressingStyle) {
                                    Text("自动（七牛优先）").tag("auto")
                                    Text("Path-style").tag("path")
                                    Text("Virtual-hosted").tag("virtual")
                                }
                                Stepper("请求超时：\(Int(config.timeout)) 秒",value:$config.timeout,in:5...300,step:5)
                                Stepper("并发请求上限：\(config.concurrentReqs)",value:$config.concurrentReqs,in:1...16)
                                Toggle("TLS 证书验证",isOn:$config.tlsVerify)
                                if !config.tlsVerify { Text("此连接已关闭证书验证").foregroundStyle(.orange) }
                            }
                            Button("保存同步设置") { saveSettings() }.disabled(sync.running || busy || !loaded)
                            Button("复制全部 S3 设置（含密钥）") {
                                let value = S3SettingsTransfer(configuration:config,access:access,secret:secret)
                                Task {
                                    do {
                                        let text = try await Task.detached(priority:.utility) { try value.encoded() }.value
                                        UIPasteboard.general.string = text
                                        message = "已复制 Base64 设置，含可读取的访问密钥"
                                    } catch { message = error.localizedDescription }
                                }
                            }.disabled(!loaded)
                            Button("粘贴并导入 S3 设置") {
                                importCode = ""; importError = ""; showImport = true
                            }.disabled(sync.running || busy || !loaded)
                            Button("测试连接与读写") {
                                let value = S3SettingsTransfer(configuration:config,access:access,secret:secret)
                                busy = true; message = "正在测试连接…"
                                Task {
                                    defer { busy = false }
                                    do { message = try await Self.testConnection(value) }
                                    catch { message = error.localizedDescription }
                                }
                            }.disabled(sync.running || busy || !loaded)
                            if !message.isEmpty { Text(message).font(.caption) }
                        }
                        Section("资料库") {
                            if sync.configuration.enabled && sync.encryptedLibraryID == nil {
                                Button("创建加密云资料库") {
                                    busy = true
                                    Task {
                                        defer { busy = false }
                                        do { try await sync.createEncryptedLibrary(); message = "已创建，可以复制加入码" }
                                        catch { message = error.localizedDescription }
                                    }
                                }.disabled(sync.running || busy)
                            }
                            if sync.encryptedLibraryID != nil {
                                Button("复制资料库恢复码") {
                                    do {
                                        guard let material = try CloudKeyStore.load() else { throw S3Failure.message("本机没有加密资料库恢复码") }
                                        UIPasteboard.general.string = try material.encoded()
                                        message = "已复制恢复码；其他设备需要此恢复码才能解密资料库"
                                    } catch { message = error.localizedDescription }
                                }.disabled(sync.running || busy)
                                Button {
                                    if revealRecovery { recoveryPreview = ""; revealRecovery = false }
                                    else {
                                        do {
                                            guard let key = try CloudKeyStore.load() else { throw S3Failure.message("本机没有恢复码") }
                                            recoveryPreview = try key.encoded()
                                            revealRecovery = true
                                        } catch { message = error.localizedDescription }
                                    }
                                } label: {
                                    Label(revealRecovery ? "隐藏资料库恢复码" : "查看资料库恢复码",systemImage:revealRecovery ? "eye.slash" : "eye")
                                }
                                if revealRecovery { Text(recoveryPreview).font(.caption).textSelection(.enabled) }
                            }
                            Button("用本机资料库替换云端",role:.destructive) {
                                showConnection = false
                                confirmReset = true
                            }.disabled(sync.running || busy || !sync.configuration.enabled)
                            Button("放弃本机冲突并以云端为准",role:.destructive) {
                                confirmPreferCloud = true
                            }.disabled(sync.running || busy || !sync.configuration.enabled)
                                .alert("放弃本机冲突并以云端为准？",isPresented:$confirmPreferCloud) {
                                    Button("采用云端版本",role:.destructive) { Task { await sync.preferCloudConflicts() } }
                                    Button("取消",role:.cancel) {}
                                } message: {
                                    Text("先同步最新云端资料，再对同时有本机和云端版本的冲突采用云端版本。其他本机修改会保留。")
                                }
                        }
                    }.navigationTitle("连接设置")
                        .onDisappear { showAccess = false; showSecret = false; revealRecovery = false; recoveryPreview = "" }
                        .toolbar { ToolbarItem(placement:.confirmationAction) { Button("完成") { showConnection = false } } }
                        .sheet(isPresented:$showImport) { importSheet }
                }
            }
            .task {
                let result = await Task.detached(priority:.utility) { (Credentials.read("cloud.access"),Credentials.read("cloud.secret")) }.value
                access = result.0; secret = result.1; loaded = true
            }
            .alert("消除所有冲突并以本机为准？",isPresented:$confirmReset) {
                Button("覆盖云端",role:.destructive) { Task { await sync.replaceCloudWithLocal() } }
                Button("取消",role:.cancel) {}
            } message: {
                Text("云端会采用本机的同步数据。其他设备下次同步时会采用新版本，清除旧的冲突版本、未上传修改。")
            }
            .sheet(isPresented:$showRecovery) {
                NavigationStack {
                    Form {
                        TextField("粘贴同步加入码或资料库恢复码",text:$recoveryCode,axis:.vertical).plainTextInput()
                        PasteButton(payloadType:String.self) { if let value = $0.first { recoveryCode = value } }
                        if !recoveryError.isEmpty { Text(recoveryError).foregroundStyle(.red) }
                    }.navigationTitle("加入加密资料库")
                        .toolbar {
                            ToolbarItem(placement:.cancellationAction) { Button("取消") { showRecovery = false } }
                            ToolbarItem(placement:.confirmationAction) { Button("加入") { joinEncryption() }.disabled(recoveryCode.isEmpty || busy || sync.running) }
                        }
                }
            }
    }

    private var importSheet: some View {
        NavigationStack {
            Form {
                TextField("粘贴 Base64 设置",text:$importCode,axis:.vertical).plainTextInput()
                PasteButton(payloadType:String.self) { values in
                    if let value = values.first { importCode = value }
                }
                if !importError.isEmpty { Text(importError).foregroundStyle(.red) }
            }.navigationTitle("导入 S3 设置")
                .toolbar {
                    ToolbarItem(placement:.cancellationAction) { Button("取消") { showImport = false } }
                    ToolbarItem(placement:.confirmationAction) {
                        Button("导入") { importSettings() }.disabled(importCode.isEmpty || sync.running || busy)
                    }
                }
        }
    }

    private func keyField(_ name:String,text:Binding<String>,revealed:Binding<Bool>) -> some View {
        HStack {
            Group {
                if revealed.wrappedValue { TextField(name,text:text) }
                else { SecureField(name,text:text) }
            }.plainTextInput()
            Button { revealed.wrappedValue.toggle() } label: {
                Image(systemName:revealed.wrappedValue ? "eye.slash" : "eye")
            }.buttonStyle(.borderless)
                .accessibilityLabel((revealed.wrappedValue ? "隐藏 " : "显示 ") + name)
        }
    }

    private func saveSettings() {
        let value = S3SettingsTransfer(configuration:config,access:access,secret:secret)
        busy = true
        Task {
            defer { busy = false }
            do { try await sync.save(value.configuration,access:value.access,secret:value.secret); message = "设置已保存" }
            catch { message = error.localizedDescription }
        }
    }

    private func joinEncryption() {
        busy = true
        Task {
            defer { busy = false }
            do {
                let connection = try? S3SettingsTransfer.decode(recoveryCode)
                let material = try CloudKeyMaterial.decode(connection?.recovery ?? recoveryCode)
                try await sync.joinEncrypted(material:material,connection:connection,storeKey:{ try CloudKeyStore.install($0) })
                if let connection {
                    config = connection.configuration; access = connection.access; secret = connection.secret
                }
                recoveryCode = ""; showRecovery = false
                await sync.synchronize()
                message = sync.error ?? "已加入加密资料库"
            } catch { recoveryError = error.localizedDescription }
        }
    }

    private func importSettings() {
        let text = importCode
        busy = true
        Task {
            defer { busy = false }
            do {
                let value = try await Task.detached(priority:.utility) { try S3SettingsTransfer.decode(text) }.value
                try await sync.save(value.configuration,access:value.access,secret:value.secret)
                config = value.configuration; access = value.access; secret = value.secret
                importCode = ""; showImport = false; message = "S3 设置已导入"
            } catch { importError = error.localizedDescription }
        }
    }

    private nonisolated static func testConnection(_ value:S3SettingsTransfer) async throws -> String {
        try value.configuration.validate()
        let transport = S3Transport(config:value.configuration,access:value.access,secret:value.secret)
        _ = try await transport.list(prefix:CloudSync.prefix)
        let key = "anishelf/v1/probes/" + UUID().uuidString
        let body = Data(UUID().uuidString.utf8)
        _ = try await transport.request("PUT",key:key,body:body)
        guard try await transport.request("GET",key:key) == body else { throw S3Failure.message("写入后校验失败") }
        do {
            _ = try await transport.request("DELETE",key:key)
            return "连接、列举、上传、读取及校验通过"
        } catch { return "读写校验通过；测试对象清理失败："+error.localizedDescription }
    }
}
