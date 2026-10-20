import SwiftUI
import AppKit
import TailcatCore

struct DeviceEditorView: View {
    @ObservedObject var manager: SessionManager
    let profile: DeviceProfile?
    let temporary: Bool
    let saved: (UUID) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var address = ""
    @State private var port = ""
    @State private var remotePort = "5555"
    @State private var reveal = false
    @State private var error: String?
    init(manager: SessionManager, profile: DeviceProfile?, temporary: Bool = false, saved: @escaping (UUID) -> Void) {
        self.manager = manager; self.profile = profile; self.temporary = temporary; self.saved = saved
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(temporary ? (profile == nil ? "临时连接" : "编辑临时设备") : (profile == nil ? "添加设备" : "编辑设备")).font(.title2)
            Form {
                TextField(temporary ? "设备名称（可选）" : "设备名称", text: $name)
                if reveal { TextField("Tailcat 地址", text: $address) }
                else { SecureField("Tailcat 地址", text: $address) }
                Toggle("显示完整连接凭据", isOn: $reveal)
                TextField("本地端口（留空自动）", text: $port)
                TextField("远端 ADB 端口", text: $remotePort)
            }.textFieldStyle(.roundedBorder)
            Text(temporary ? "临时设备配置与连接地址不写入地址簿或 Keychain，退出应用时清除；固定客户端身份单独保存在本机。连接后可使用全部 ADB 操作，也可保存到我的设备。" : "连接凭据保存在本机 Keychain。自动端口从 5556 起分配，已有连接保持。")
                .font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(temporary && profile == nil ? "连接" : "保存") { save() }.keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 500)
        .onAppear {
            guard let profile else { return }
            name = profile.name; port = profile.preferredPort.map(String.init) ?? ""; remotePort = String(profile.remotePort)
            do { address = try manager.addressForEditing(profile.id) }
            catch { self.error = error.localizedDescription }
        }
    }
    private func save() {
        do {
            let portText = port.trimmingCharacters(in: .whitespaces)
            let local = portText.isEmpty ? nil : Int(portText)
            guard portText.isEmpty || local != nil, let remote = Int(remotePort) else {
                throw ManagerError.message("端口需要填写整数")
            }
            let id: UUID
            if temporary {
                id = try manager.saveTemporaryDevice(id: profile?.id, name: name, address: address, preferredPort: local, remotePort: remote)
                if profile == nil { manager.connect(id) }
            } else {
                id = try manager.saveDevice(id: profile?.id, name: name, address: address, preferredPort: local, remotePort: remote)
            }
            saved(id); dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

struct SaveTemporaryDeviceView: View {
    @ObservedObject var manager: SessionManager
    let profile: DeviceProfile
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("保存到我的设备").font(.title2)
            TextField("设备名称", text: $name).textFieldStyle(.roundedBorder)
            Text("保存连接配置和凭据，当前会话与正在执行的任务继续运行。")
                .font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") {
                    do { try manager.promoteTemporaryDevice(profile.id, name: name); dismiss() }
                    catch { self.error = error.localizedDescription }
                }.keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 440).onAppear { name = profile.name }
    }
}

struct TransferView: View {
    @ObservedObject var manager: SessionManager
    let request: TransferRequest
    @Environment(\.dismiss) private var dismiss
    @State private var remotePath = "/sdcard/Download/"
    @State private var downloadFolder: URL?
    @State private var error: String?
    private var uploading: Bool { request.localURL != nil }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(uploading ? "上传文件" : "下载文件").font(.title2)
            Text("目标设备：\(request.deviceName)").font(.headline)
            if let local = request.localURL { Text("本地：\(local.path)").textSelection(.enabled).font(.caption) }
            TextField(uploading ? "远端保存目录或路径" : "远端文件或目录路径", text: $remotePath).textFieldStyle(.roundedBorder)
            if !uploading {
                HStack {
                    Text(downloadFolder?.path ?? "请选择本地保存目录").lineLimit(2).textSelection(.enabled)
                    Spacer()
                    Button("选择目录") { chooseFolder() }
                }
            }
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(uploading ? "上传" : "下载") { start() }.keyboardShortcut(.defaultAction)
                    .disabled(!uploading && downloadFolder == nil)
            }
        }.padding(24).frame(width: 530)
    }
    private func chooseFolder() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.canCreateDirectories = true
        if panel.runModal() == .OK { downloadFolder = panel.url }
    }
    private func start() {
        let remote = remotePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard remote.hasPrefix("/"), !remote.contains("\0"), !remote.contains("\n") else {
            error = "请填写绝对远端路径，例如 /sdcard/Download/example.txt"; return
        }
        do {
            if let local = request.localURL {
                try manager.beginADBTask(request.deviceID, title: "上传 \(local.lastPathComponent)", arguments: ["push", local.path, remote], timeout: 1800)
            } else if let folder = downloadFolder {
                try manager.beginADBTask(request.deviceID, title: "下载 \(URL(fileURLWithPath: remote).lastPathComponent)", arguments: ["pull", remote, folder.path], timeout: 1800)
            }
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

struct ToolSettingsView: View {
    @ObservedObject var manager: SessionManager
    @ObservedObject var installer: ComponentInstaller
    @Environment(\.dismiss) private var dismiss
    @State private var settings = ToolSettings()
    @State private var savedSettings = ToolSettings()
    @State private var message: String?
    init(manager: SessionManager) {
        self.manager = manager; self.installer = manager.componentInstaller
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("工具设置").font(.title2)
            Form {
                toolRow(.tailcat, path: $settings.tailcat)
                toolRow(.adb, path: $settings.adb)
                toolRow(.scrcpy, path: $settings.scrcpy)
                HStack {
                    TextField("地址簿目录", text: $settings.addressBookDirectory)
                    Button("选择") { chooseDirectory() }
                }
            }.textFieldStyle(.roundedBorder)
            Text("缺失组件可通过 Homebrew 一键安装，安装成功后自动保存工具路径。scrcpy 为可选组件；地址簿目录应包含 users 子目录。")
                .font(.caption).foregroundStyle(.secondary)
            if installer.homebrewPath == nil {
                HStack {
                    Text("未检测到 Homebrew，请先安装后重试。").font(.caption).foregroundStyle(.orange)
                    Link("安装 Homebrew", destination: URL(string: "https://brew.sh")!)
                }
            }
            if installer.isBusy || installer.message != nil {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        if let component = installer.installing {
                            ProgressView().controlSize(.small)
                            Text("正在安装 \(component.label)…").font(.caption)
                            Spacer()
                            Button("取消安装") { installer.cancel() }.controlSize(.small)
                        } else if let status = installer.message {
                            Text(status).font(.caption).foregroundStyle(installer.failed ? .red : .secondary).textSelection(.enabled)
                        }
                    }
                    if !installer.output.isEmpty {
                        ScrollView {
                            Text(installer.output).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }.frame(maxHeight: 150)
                    }
                }
            }
            if let message { Text(message).textSelection(.enabled).font(.caption) }
            HStack {
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("安装缺失组件") { manager.installMissingComponents { component, path in settings[component] = path } }
                    .disabled(installer.isBusy || !manager.allowsComponentInstallation || ToolComponent.allCases.allSatisfy { FileManager.default.isExecutableFile(atPath: manager.tools[$0]) })
                Button("重新检测") {
                    settings.tailcat = ToolLocator.find("tailcat") ?? ""
                    settings.adb = ToolLocator.find("adb") ?? ""
                    settings.scrcpy = ToolLocator.find("scrcpy") ?? ""
                }
                Spacer()
                Button("保存") {
                    do { try manager.updateTools(settings); message = "已保存" }
                    catch { message = error.localizedDescription }
                }.keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 730).onAppear { settings = manager.tools; savedSettings = manager.tools }
        .onChange(of: manager.tools) { updated in
            // Preserve other unsaved fields while reflecting an automatically configured component.
            for component in ToolComponent.allCases where savedSettings[component] != updated[component] {
                settings[component] = updated[component]
            }
            savedSettings = updated
        }
    }
    private func toolRow(_ component: ToolComponent, path: Binding<String>) -> some View {
        HStack {
            TextField(component == .scrcpy ? "scrcpy（可选）" : component.label, text: path)
            if !FileManager.default.isExecutableFile(atPath: path.wrappedValue) {
                ComponentInstallButton(manager: manager, component: component) { installedPath in path.wrappedValue = installedPath }
            } else {
                Image(systemName: "checkmark.circle").foregroundStyle(.green).help("可用")
            }
            Button("选择") {
                let panel = NSOpenPanel(); panel.canChooseFiles = true; panel.canChooseDirectories = false
                if panel.runModal() == .OK, let url = panel.url { path.wrappedValue = url.path }
            }
        }
    }
    private func chooseDirectory() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        if panel.runModal() == .OK, let url = panel.url { settings.addressBookDirectory = url.path }
    }
}
