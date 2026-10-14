import Foundation
import TailcatCore

@MainActor private final class DemoProcess: RunningProcess {
    let pid: Int32
    var isRunning = true
    init(_ pid: Int32) { self.pid = pid }
    func stop() async { isRunning = false }
}

@MainActor private final class DemoTransport: ForwardTransport {
    private var nextPort = 5556
    func open(address: String, preferredPort: Int?, remotePort: Int,
              onLog: @escaping (String) -> Void, onExit: @escaping (Int32) -> Void) async throws -> ForwardConnection {
        let port = preferredPort ?? nextPort; nextPort += 1
        onLog("示例通道监听 127.0.0.1:\(port)")
        return ForwardConnection(handle: DemoProcess(Int32(60000 + port)), port: port)
    }
}

@MainActor private final class DemoRunner: CommandExecuting {
    func start(_ command: Command, onOutput: @escaping (String) -> Void,
               onExit: @escaping (Int32) -> Void) throws -> any RunningProcess { DemoProcess(65000) }
    func run(_ command: Command, onOutput: @escaping (String) -> Void) async throws -> CommandResult {
        try await Task.sleep(nanoseconds: 100_000_000)
        let args = command.arguments
        if args.first == "parse" || args.first == "disconnect" { return CommandResult() }
        if args.first == "connect" { return CommandResult(output: "示例 ADB 通道已建立\n") }
        if args.contains("get-state") {
            return args.contains("127.0.0.1:5557") ? CommandResult(exitCode: 1, output: "error: device unauthorized\n") : CommandResult(output: "device\n")
        }
        if args.contains(where: { $0.contains("getprop ro.product.model") }) {
            return CommandResult(output: "E245（示例）\nantora-demo\n11\nDEMO-ONLY\nuid=0(root) gid=0(root)\n")
        }
        if args.first == "ping" { return CommandResult(output: "pong in 18ms via DERP(example)\n") }
        if args.contains("install") {
            for chunk in ["Performing Push Install\n", "\r[ 25%] example.apk: 25%", "\r[ 60%] example.apk: 60%",
                          "\r[100%] example.apk: 100%\rexample.apk: 1 file pushed, 0 skipped.\n"] {
                onOutput(chunk)
                try await Task.sleep(nanoseconds: 3_000_000_000)
            }
            return CommandResult(output: "Success\n（演示：未安装真实 APK）\n")
        }
        onOutput("示例任务正在执行，目标 \(args.dropFirst().first ?? "")\n")
        try await Task.sleep(nanoseconds: 1_500_000_000)
        return CommandResult(output: "示例任务完成，未执行真实设备命令。\n")
    }
}

@MainActor enum DemoEnvironment {
    static func makeManager() -> SessionManager {
        let profiles = [DeviceProfile(name: "E245 · 示例", preferredPort: 5556),
                        DeviceProfile(name: "EX5 · 示例", preferredPort: 5557),
                        DeviceProfile(name: "备用设备 · 示例")]
        let vault = MemoryCredentialStore()
        for profile in profiles { try? vault.write("tc" + String(repeating: "A", count: 30), id: profile.id) }
        let settings = ToolSettings(tailcat: "/usr/bin/true", adb: "/usr/bin/true", scrcpy: "/usr/bin/true")
        let transport = DemoTransport()
        let manager = SessionManager(configuration: AppConfiguration(profiles: profiles, tools: settings),
                                     credentials: vault, runner: DemoRunner(),
                                     allowsComponentInstallation: false,
                                     makeTransport: { _, _ in transport })
        manager.connect(profiles[0].id); manager.connect(profiles[1].id)
        return manager
    }
}
