import SwiftUI
import AppKit
import UniformTypeIdentifiers
import TailcatCore

struct DeviceEditorRequest: Identifiable {
    let id = UUID()
    let profile: DeviceProfile?
    let temporary: Bool
    init(profile: DeviceProfile?, temporary: Bool = false) { self.profile = profile; self.temporary = temporary }
}

struct TransferRequest: Identifiable {
    let id = UUID()
    let deviceID: UUID
    let deviceName: String
    let localURL: URL?
}

struct ManagerView: View {
    @ObservedObject var manager: SessionManager
    let demo: Bool
    @State private var selection: UUID?
    @State private var editor: DeviceEditorRequest?
    @State private var promotion: DeviceProfile?
    @State private var transfer: TransferRequest?
    @State private var removeProfile: DeviceProfile?
    @State private var error: String?
    @State private var showSettings = false
    @State private var showReachability = false

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("我的设备") {
                    ForEach(manager.profiles) { profile in
                        deviceRow(profile)
                    }
                }
                Section("临时设备") {
                    ForEach(manager.temporaryProfiles) { profile in deviceRow(profile) }
                    Button { editor = DeviceEditorRequest(profile: nil, temporary: true) } label: {
                        Label("新建临时连接", systemImage: "bolt.circle")
                    }.buttonStyle(.plain).padding(.vertical, 5)
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 225, max: 290)
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("GUI \(manager.ownedActiveCount) · CLI 外部 \(manager.externalActiveCount)").font(.caption).foregroundStyle(.secondary)
                    ForEach(ToolComponent.allCases) { component in
                        ToolHealthRow(manager: manager, component: component)
                    }
                    if let error = manager.externalScanError {
                        Text(error).font(.caption).foregroundStyle(.orange)
                        Button("授权识别 CLI 连接") {
                            Task { await manager.refreshExternalConnections(allowCredentialPrompt: true) }
                        }.font(.caption)
                    }
                    InstallationSummary(installer: manager.componentInstaller, openSettings: { showSettings = true })
                }.padding().frame(maxWidth: .infinity, alignment: .leading)
            }
        } detail: {
            VStack(spacing: 0) {
                if demo {
                    HStack {
                        Label("界面演示 · 使用模拟设备，不执行真实命令", systemImage: "eye")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                    }.padding(.horizontal, 24).padding(.vertical, 10)
                    Divider()
                }
                if let id = selection, let profile = manager.allProfiles.first(where: { $0.id == id }) {
                    DeviceDetailView(manager: manager, profile: profile,
                        edit: { editor = DeviceEditorRequest(profile: profile, temporary: manager.isTemporary(id)) },
                        save: { promotion = profile }, close: { closeTemporary(id) },
                        install: { chooseInstall(id) },
                        upload: { chooseUpload(profile) },
                        download: { transfer = TransferRequest(deviceID: id, deviceName: profile.name, localURL: nil) },
                        terminal: { openTerminal(id) }, reportError: { error = $0 })
                        .id(profile.id)
                } else {
                    VStack(spacing: 15) {
                        Image(systemName: "network").font(.system(size: 42)).foregroundStyle(.secondary)
                        Text(manager.allProfiles.isEmpty ? "连接你的第一台设备" : "选择一台设备").font(.title2)
                        Text("每台设备拥有独立通道，支持同时连接。") .foregroundStyle(.secondary)
                        HStack {
                            Button("添加设备") { editor = DeviceEditorRequest(profile: nil) }
                            Button("临时连接") { editor = DeviceEditorRequest(profile: nil, temporary: true) }
                            Button("导入 tailcat-adb 地址簿") { importBook() }
                        }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                if let notice = manager.notice {
                    Divider()
                    HStack {
                        Image(systemName: "info.circle")
                        Text(notice).font(.caption).textSelection(.enabled)
                        Spacer()
                        Button { manager.notice = nil } label: { Image(systemName: "xmark") }
                            .buttonStyle(.plain).help("关闭提示")
                    }.padding(12)
                }
                if !manager.tasks.isEmpty {
                    Divider()
                    TaskHistoryView(manager: manager)
                }
            }
        }
        .frame(minWidth: 850, minHeight: 600)
        .toolbar {
            ToolbarItemGroup {
                Button {
                    showReachability = true
                    if manager.reachability.results.isEmpty { manager.testAllDevices() }
                } label: { Label("测试全部设备", systemImage: "waveform.path.ecg") }
                    .help("一键测试全部设备的 Tailcat 可达性").disabled(manager.allProfiles.isEmpty)
                Button { editor = DeviceEditorRequest(profile: nil, temporary: true) } label: { Label("临时连接", systemImage: "bolt.circle") }
                    .help("临时连接，不保存到我的设备").keyboardShortcut("n", modifiers: [.command, .shift])
                Button { editor = DeviceEditorRequest(profile: nil) } label: { Label("添加设备", systemImage: "plus") }
                    .help("添加设备")
                Button { importBook() } label: { Label("导入地址簿", systemImage: "square.and.arrow.down") }
                    .help("只读导入 tailcat-adb 地址簿")
                Button { showSettings = true } label: { Label("工具设置", systemImage: "gearshape") }
                    .help("配置 Tailcat、ADB、scrcpy 路径")
            }
        }
        .sheet(item: $editor) { request in
            DeviceEditorView(manager: manager, profile: request.profile, temporary: request.temporary) { id in selection = id }
        }
        .sheet(item: $promotion) { profile in SaveTemporaryDeviceView(manager: manager, profile: profile) }
        .sheet(item: $transfer) { request in
            TransferView(manager: manager, request: request)
        }
        .sheet(isPresented: $showSettings) { ToolSettingsView(manager: manager) }
        .sheet(isPresented: $showReachability) { ReachabilityView(manager: manager, checker: manager.reachability) }
        .alert("操作未完成", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("好") { error = nil }
        } message: { Text(error ?? "") }
        .confirmationDialog("移除设备？", isPresented: Binding(get: { removeProfile != nil }, set: { if !$0 { removeProfile = nil } }), presenting: removeProfile) { profile in
            Button("移除 \(profile.name)", role: .destructive) {
                Task {
                    do { try await manager.removeDevice(profile.id) }
                    catch { self.error = error.localizedDescription }
                }
                removeProfile = nil
            }
        } message: { _ in Text("会断开应用创建的通道并移除应用内配置。CLI 外部连接和 tailcat-adb 地址簿保留。") }
        .onAppear { if selection == nil { selection = manager.allProfiles.first?.id } }
        .onChange(of: manager.allProfiles.map(\.id)) { ids in
            if selection == nil || !ids.contains(selection!) { selection = ids.first }
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)) { _ in
            manager.recheckConnections()
        }
    }

    private func deviceRow(_ profile: DeviceProfile) -> some View {
        let session = manager.session(profile.id)
        let temporary = manager.isTemporary(profile.id)
        return SidebarDevice(profile: profile, session: session, external: manager.externalSessions[profile.id] ?? [])
            .tag(profile.id)
            .contextMenu {
                Button("连接 / 重新连接") { manager.connect(profile.id) }.disabled(session.state.isBusy || session.isExternalCLI)
                Button("断开") { manager.disconnect(profile.id) }.disabled(session.isExternalCLI || (session.serial == nil && !session.state.isBusy))
                Divider()
                Button(temporary ? "编辑临时设备" : "编辑设备") { editor = DeviceEditorRequest(profile: profile, temporary: temporary) }
                    .disabled(session.serial != nil || session.state.isBusy)
                if temporary {
                    Button("保存到我的设备") { promotion = profile }.disabled(session.state == .disconnecting)
                    Button("关闭临时设备") { closeTemporary(profile.id) }
                } else {
                    Button("移除设备", role: .destructive) { removeProfile = profile }
                }
            }
    }

    private func closeTemporary(_ id: UUID) {
        Task { do { try await manager.removeDevice(id) } catch { self.error = error.localizedDescription } }
    }

    private func importBook() {
        guard !demo else { manager.notice = "演示模式不读取真实地址簿"; return }
        do { try manager.importLegacy() } catch { self.error = error.localizedDescription }
    }
    private func chooseInstall(_ id: UUID) {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(filenameExtension: "apk") ?? .data]
        panel.message = "选择要安装到当前设备的 APK"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try manager.beginAPKInstall(id, file: url) }
        catch { self.error = error.localizedDescription }
    }
    private func chooseUpload(_ profile: DeviceProfile) {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = true
        panel.allowsMultipleSelection = false; panel.message = "选择上传到 \(profile.name) 的文件或文件夹"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        transfer = TransferRequest(deviceID: profile.id, deviceName: profile.name, localURL: url)
    }
    private func openTerminal(_ id: UUID) {
        guard !demo else { manager.notice = "演示模式：终端操作绑定所选设备，不启动真实 Terminal"; return }
        Task {
        do {
            let target = try await manager.terminalCommand(id)
            let script = "#!/bin/sh\nexec \(shellQuote(target.adb)) -s \(shellQuote(target.serial)) shell\n"
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("tailcat-shell-\(UUID().uuidString).command")
            try Data(script.utf8).write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
            let configuration = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.open([file], withApplicationAt: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"), configuration: configuration) { _, launchError in
                if let launchError { Task { @MainActor in self.error = launchError.localizedDescription } }
            }
        } catch { self.error = error.localizedDescription }
        }
    }
    private func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}

private struct SidebarDevice: View {
    let profile: DeviceProfile
    let session: DeviceSession
    let external: [ExternalCLISession]
    var body: some View {
        HStack(spacing: 10) {
            StatusDot(state: session.state)
            VStack(alignment: .leading, spacing: 4) {
                Text(profile.name).lineLimit(1)
                Text(session.state.label + (session.serial.map { " · \($0.split(separator: ":").last ?? "")" } ?? ""))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                ForEach(external) { connection in
                    Text("CLI 外部连接 · \(String(connection.port))").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }.padding(.vertical, 5)
    }
}

struct StatusDot: View {
    let state: ConnectionState
    var body: some View {
        Circle().fill(color).frame(width: 8, height: 8).accessibilityHidden(true)
    }
    private var color: Color {
        switch state {
        case .online: return .green
        case .unauthorized, .offline: return .orange
        case .failed: return .red
        case .connecting, .disconnecting: return .blue
        case .disconnected: return .secondary
        }
    }
}

private struct DeviceDetailView: View {
    @ObservedObject var manager: SessionManager
    let profile: DeviceProfile
    let edit: () -> Void
    let save: () -> Void
    let close: () -> Void
    let install: () -> Void
    let upload: () -> Void
    let download: () -> Void
    let terminal: () -> Void
    let reportError: (String) -> Void
    @State private var tab = 0
    @State private var shellCommand = ""
    private var session: DeviceSession { manager.session(profile.id) }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text(profile.name).font(.title2.weight(.semibold))
                    Text(manager.isTemporary(profile.id) ? "临时设备 · 仅本次运行" : session.isExternalCLI ? "CLI 外部连接" : "独立连接会话").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if session.state.isBusy { ProgressView().controlSize(.small) }
                if manager.isTemporary(profile.id) {
                    Button("保存到我的设备", action: save).disabled(session.state == .disconnecting)
                    Button(action: close) { Image(systemName: "xmark.circle") }.help("关闭临时设备")
                }
                Button(session.serial == nil ? "连接" : "重新连接") { manager.connect(profile.id) }
                    .buttonStyle(.borderedProminent).disabled(session.state.isBusy || session.isExternalCLI)
                Button("断开") { manager.disconnect(profile.id) }
                    .disabled(session.isExternalCLI || session.state == .disconnected || session.state == .disconnecting)
            }
            Picker("设备详情", selection: $tab) {
                Text("概览").tag(0)
                Text("日志").tag(1)
            }.pickerStyle(.segmented).frame(maxWidth: 300)
            if tab == 0 {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack { StatusDot(state: session.state); Text(session.state.label).font(.headline) }
                        if manager.isTemporary(profile.id) {
                            Text("临时连接仅保留在内存中。断开后可重连；关闭临时设备或退出应用时清除配置。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if let external = manager.externalSessions[profile.id], !external.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("CLI 外部连接").font(.headline)
                                ForEach(external) { connection in
                                    HStack {
                                        StatusDot(state: connection.state)
                                        Text("\(connection.serial) · \(connection.state.label) · PID \(String(connection.pid))").textSelection(.enabled)
                                    }.font(.caption)
                                }
                                Text("通道由 tailcat-adb 管理；在线时可在这里执行 ADB 操作。GUI 退出会保留通道，重连和断开由 CLI 控制。")
                                    .font(.caption).foregroundStyle(.secondary)
                            }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                        }
                        if session.state == .unauthorized {
                            Text("Tailcat 通道已建立。远端 ADB 尚未接受本机密钥，需要完成设备侧授权。")
                                .foregroundStyle(.orange).textSelection(.enabled)
                        }
                        if let error = session.error { Text(error).foregroundStyle(session.state == .failed ? .red : .secondary).textSelection(.enabled) }
                        VStack(spacing: 13) {
                            DetailRow("本地入口", session.serial ?? "未分配")
                            DetailRow("远端端口", String(session.isExternalCLI ? manager.externalSessions[profile.id]?.first(where: { $0.serial == session.serial })?.remotePort ?? profile.remotePort : profile.remotePort))
                            DetailRow("链路", session.route)
                            DetailRow("设备型号", session.model)
                            DetailRow("设备代号", session.product)
                            DetailRow("Android", session.android)
                            DetailRow("设备序列号", session.deviceSerial)
                            DetailRow("Shell 权限", session.identity)
                        }
                        HStack {
                            Button("探测链路") { manager.diagnose(profile.id) }.disabled(session.serial == nil || session.state.isBusy)
                            Button("刷新信息") { manager.refreshDeviceInformation(profile.id) }.disabled(session.state != .online)
                            Button(manager.isTemporary(profile.id) ? "编辑临时设备" : "编辑设备") { edit() }.disabled(session.serial != nil || session.state.isBusy)
                            if let serial = session.serial {
                                Button("复制 ADB 入口") {
                                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(serial, forType: .string)
                                }
                            }
                        }
                        Divider()
                        Text("设备操作").font(.headline)
                        HStack(spacing: 10) {
                            Button("终端", systemImage: "terminal") { terminal() }
                            Button("安装 APK", systemImage: "shippingbox") { install() }
                            Button("上传", systemImage: "arrow.up.doc") { upload() }
                            Button("下载", systemImage: "arrow.down.doc") { download() }
                        }.disabled(session.state != .online)
                        Button("屏幕控制（scrcpy）", systemImage: "display") {
                            do { try manager.beginScreen(profile.id) } catch { reportError(error.localizedDescription) }
                        }.disabled(session.state != .online).help("需要在设置中配置 scrcpy")
                        HStack {
                            TextField("执行一条 ADB Shell 命令", text: $shellCommand)
                                .textFieldStyle(.roundedBorder).onSubmit { runShell() }
                            Button("执行") { runShell() }.disabled(shellCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }.disabled(session.state != .online)
                        Text("任务始终绑定启动时的设备和 ADB 入口。关闭主窗口后，连接继续由菜单栏管理。")
                            .font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.trailing, 6)
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if session.logs.isEmpty { Text("暂无通道日志").foregroundStyle(.secondary) }
                        ForEach(session.logs) { entry in
                            HStack(alignment: .top, spacing: 10) {
                                Text(entry.date, style: .time).foregroundStyle(.secondary)
                                Text(entry.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                            }.font(.system(.caption, design: .monospaced))
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    private func runShell() {
        guard !shellCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        do { try manager.beginADBTask(profile.id, title: "Shell 命令", arguments: ["shell", shellCommand], timeout: 120) }
        catch { reportError(error.localizedDescription) }
    }
}

private struct DetailRow: View {
    let label: String
    let value: String
    init(_ label: String, _ value: String) { self.label = label; self.value = value }
    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Text(label).foregroundStyle(.secondary).frame(width: 95, alignment: .leading)
            Text(value).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct TaskHistoryView: View {
    @ObservedObject var manager: SessionManager
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("设备任务").font(.headline)
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(Array(manager.tasks.suffix(20).reversed())) { task in
                        VStack(alignment: .leading, spacing: 8) {
                            DisclosureGroup {
                                Text(task.output.isEmpty ? (task.installProgress?.stage.label ?? "等待命令输出…") : task.output)
                                    .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 6)
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(task.title).lineLimit(1)
                                        Text("\(task.deviceName) · \(task.serial)").font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text(task.state.label).font(.caption).foregroundStyle(task.state == .failed ? .red : .secondary)
                                    if task.state == .running {
                                        Button("取消") { manager.cancelTask(task.id) }.controlSize(.small)
                                    }
                                }
                            }
                            if let progress = task.installProgress {
                                APKInstallProgressView(task: task, progress: progress)
                            }
                        }
                    }
                }.padding(.trailing, 8)
            }.frame(maxHeight: 160)
        }.padding(.horizontal, 24).padding(.vertical, 14)
    }
}

private struct APKInstallProgressView: View {
    let task: DeviceTask
    let progress: APKInstallProgress
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(task.state == .running || task.state == .succeeded ? progress.stage.label : task.state.label)
                Spacer()
                if let fraction = progress.fraction, progress.stage == .uploading {
                    Text("\(Int((fraction * 100).rounded()))%")
                        .monospacedDigit()
                }
                Text(ByteCountFormatter.string(fromByteCount: progress.totalBytes, countStyle: .file))
                    .foregroundStyle(.secondary)
                if task.state == .running {
                    TimelineView(.periodic(from: task.date, by: 1)) { context in
                        let seconds = max(0, Int(context.date.timeIntervalSince(task.date)))
                        Text("已用时 \(seconds / 60) 分 \(seconds % 60) 秒")
                            .monospacedDigit().foregroundStyle(.secondary)
                    }
                }
            }.font(.caption)
            if task.state == .running {
                if let fraction = progress.fraction, progress.stage == .uploading {
                    ProgressView(value: fraction).accessibilityLabel("APK 上传进度")
                } else {
                    ProgressView().controlSize(.small).accessibilityLabel(progress.stage.label)
                }
            }
        }.padding(.leading, 20)
    }
}

struct ToolHealthRow: View {
    @ObservedObject var manager: SessionManager
    let component: ToolComponent
    var body: some View {
        let path = manager.tools[component]
        let available = FileManager.default.isExecutableFile(atPath: path)
        HStack {
            Image(systemName: available ? "checkmark.circle" : "exclamationmark.circle")
                .foregroundStyle(available ? .green : .orange)
            Text(component.label)
            Spacer()
            if available { Text("可用").foregroundStyle(.secondary) }
            else { ComponentInstallButton(manager: manager, component: component) }
        }.font(.caption).help(path.isEmpty ? "请在工具设置中指定路径" : path)
    }
}

struct ComponentInstallButton: View {
    @ObservedObject var manager: SessionManager
    @ObservedObject var installer: ComponentInstaller
    let component: ToolComponent
    let onConfigured: @MainActor (String) -> Void
    init(manager: SessionManager, component: ToolComponent, onConfigured: @escaping @MainActor (String) -> Void = { _ in }) {
        self.manager = manager; self.installer = manager.componentInstaller; self.component = component
        self.onConfigured = onConfigured
    }
    var body: some View {
        if installer.installing == component {
            HStack(spacing: 5) { ProgressView().controlSize(.mini); Text("安装中") }.font(.caption)
        } else {
            Button(ToolLocator.find(component.executableName) == nil ? "安装" : "自动配置") { manager.installComponent(component, onConfigured: onConfigured) }
                .controlSize(.small).disabled(installer.isBusy || !manager.allowsComponentInstallation)
                .help("通过 Homebrew：\(component.installDescription)")
        }
    }
}

private struct InstallationSummary: View {
    @ObservedObject var installer: ComponentInstaller
    let openSettings: () -> Void
    var body: some View {
        if installer.isBusy {
            Button("查看安装进度…", action: openSettings).font(.caption).buttonStyle(.link)
        } else if let message = installer.message {
            Button(message, action: openSettings).font(.caption).buttonStyle(.link)
                .foregroundStyle(installer.failed ? .orange : .secondary).lineLimit(2)
        }
    }
}
