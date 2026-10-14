import Foundation
import TailcatCore

private final class SpyCredentialStore: CredentialStore {
    private let memory = MemoryCredentialStore()
    var reads = 0, writes = 0, deletes = 0
    func read(id: UUID) throws -> String? { reads += 1; return try memory.read(id: id) }
    func write(_ address: String, id: UUID) throws { writes += 1; try memory.write(address, id: id) }
    func delete(id: UUID) throws { deletes += 1; try memory.delete(id: id) }
    func resetCounts() { reads = 0; writes = 0; deletes = 0 }
}

@MainActor private final class FakeProcess: RunningProcess {
    let pid: Int32
    var isRunning = true
    var stopCount = 0
    init(_ pid: Int32) { self.pid = pid }
    func stop() async { stopCount += 1; isRunning = false }
}

@MainActor private final class FakeTransport: ForwardTransport {
    var handles: [Int: FakeProcess] = [:]
    var exits: [Int: (Int32) -> Void] = [:]
    var openDelay: UInt64 = 0
    var nextPort = 5556
    func open(address: String, preferredPort: Int?, remotePort: Int,
              onLog: @escaping (String) -> Void, onExit: @escaping (Int32) -> Void) async throws -> ForwardConnection {
        if openDelay > 0 { try await Task.sleep(nanoseconds: openDelay) }
        let port = preferredPort ?? nextPort; nextPort += 1
        let process = FakeProcess(Int32(port)); handles[port] = process; exits[port] = onExit
        return ForwardConnection(handle: process, port: port)
    }
    func crash(_ port: Int) { handles[port]?.isRunning = false; exits[port]?(9) }
}

@MainActor private final class FakeRunner: CommandExecuting {
    var calls: [[String]] = []
    var commands: [Command] = []
    var unauthorized: Set<String> = []
    var operationDelay: UInt64 = 0
    var operationChunks = ["Success\n"]
    var operationResult = CommandResult(output: "Success\n")
    var didEmit: ((Command) -> Void)?
    var onDisconnect: ((String) -> Void)?
    func start(_ command: Command, onOutput: @escaping (String) -> Void,
               onExit: @escaping (Int32) -> Void) throws -> any RunningProcess { FakeProcess(1) }
    func run(_ command: Command, onOutput: @escaping (String) -> Void) async throws -> CommandResult {
        let args = command.arguments; calls.append(args); commands.append(command)
        if args.first == "disconnect", args.count > 1 { onDisconnect?(args[1]) }
        if args.first == "parse" || args.first == "connect" || args.first == "disconnect" { return CommandResult() }
        if args.contains("get-state") {
            return unauthorized.contains(args[1]) ? CommandResult(exitCode: 1, output: "error: device unauthorized\n") : CommandResult(output: "device\n")
        }
        if args.contains(where: { $0.contains("getprop ro.product.model") }) {
            return CommandResult(output: "TestModel\nproduct\n11\nSERIAL-TEST\nuid=2000(shell)\n")
        }
        if operationDelay > 0 { try await Task.sleep(nanoseconds: operationDelay) }
        for chunk in operationChunks { onOutput(chunk); didEmit?(command) }
        return operationResult
    }
}

@MainActor final class SessionTests {
    private func environment() throws -> (SessionManager, FakeRunner, FakeTransport, [DeviceProfile]) {
        let profiles = [DeviceProfile(name: "A", preferredPort: 5556), DeviceProfile(name: "B", preferredPort: 5557)]
        let vault = MemoryCredentialStore()
        for profile in profiles { try vault.write("tc" + String(repeating: "A", count: 30), id: profile.id) }
        let runner = FakeRunner(), transport = FakeTransport()
        let settings = ToolSettings(tailcat: "/usr/bin/true", adb: "/usr/bin/true", scrcpy: "/usr/bin/true")
        let manager = SessionManager(configuration: AppConfiguration(profiles: profiles, tools: settings),
                                     credentials: vault, runner: runner, monitorInterval: 60_000_000_000,
                                     makeTransport: { _, _ in transport })
        return (manager, runner, transport, profiles)
    }
    func testConcurrentSessionsAndStoppingOnePreservesOther() async throws {
        let (manager, runner, transport, profiles) = try environment()
        let first = manager.connect(profiles[0].id), second = manager.connect(profiles[1].id)
        await first?.value; await second?.value
        try expectEqual(manager.session(profiles[0].id).serial, "127.0.0.1:5556")
        try expectEqual(manager.session(profiles[1].id).serial, "127.0.0.1:5557")
        var listenerKeptUntilADBDisconnect = false
        runner.onDisconnect = { serial in
            if serial == "127.0.0.1:5556" { listenerKeptUntilADBDisconnect = transport.handles[5556]!.isRunning }
        }
        await manager.disconnect(profiles[0].id).value
        try expectTrue(listenerKeptUntilADBDisconnect)
        try expectFalse(transport.handles[5556]!.isRunning)
        try expectTrue(transport.handles[5557]!.isRunning)
        try expectEqual(manager.session(profiles[1].id).state, .online)
        try expectTrue(runner.calls.contains(["disconnect", "127.0.0.1:5556"]))
        try expectFalse(runner.calls.contains(["disconnect", "127.0.0.1:5557"]))
        try expectFalse(runner.calls.contains(where: { $0.contains("kill-server") }))
        await manager.disconnectAll()
    }
    func testTasksBindTargetEvenWhenAnotherDeviceConnects() async throws {
        let (manager, runner, _, profiles) = try environment()
        await manager.connect(profiles[0].id)?.value
        runner.operationDelay = 100_000_000
        let task = try manager.beginADBTask(profiles[0].id, title: "install", arguments: ["install", "-r", "/tmp/a file.apk"])
        await manager.connect(profiles[1].id)?.value
        await manager.waitForTask(task)
        try expectTrue(runner.calls.contains(["-s", "127.0.0.1:5556", "install", "-r", "/tmp/a file.apk"]))
        try expectFalse(runner.calls.contains(["-s", "127.0.0.1:5557", "install", "-r", "/tmp/a file.apk"]))
        try expectEqual(manager.tasks.first?.state, .succeeded)
        await manager.disconnectAll()
    }
    func testUnauthorizedKeepsTunnelAndRejectsDeviceOperations() async throws {
        let (manager, runner, transport, profiles) = try environment()
        runner.unauthorized.insert("127.0.0.1:5556")
        await manager.connect(profiles[0].id)?.value
        try expectEqual(manager.session(profiles[0].id).state, .unauthorized)
        try expectTrue(transport.handles[5556]!.isRunning)
        try expectThrows(try manager.beginADBTask(profiles[0].id, title: "install", arguments: ["install", "-r", "x.apk"]))
        await manager.disconnectAll()
    }
    func testAPKInstallShowsLivePhasesAndKeepsFixedTarget() async throws {
        let (manager, runner, _, profiles) = try environment()
        await manager.connect(profiles[0].id)?.value
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("an APK ' with spaces.apk")
        try Data(repeating: 0, count: 1024).write(to: file)
        let empty = directory.appendingPathComponent("empty.apk")
        try Data().write(to: empty)
        try expectThrows(try manager.beginAPKInstall(profiles[0].id, file: empty))
        try expectTrue(manager.tasks.isEmpty)
        runner.operationDelay = 100_000_000
        runner.operationChunks = ["Performing Push Install\n", "\r[ 42%] /data/local/tmp/example.apk: 42%",
                                  "\r/data/local/tmp/example.apk: 1 file pushed, 0 skipped.\n", "Success\n"]
        var observed: [APKInstallProgress] = []
        runner.didEmit = { command in
            if command.arguments.contains("127.0.0.1:5556"), let progress = manager.tasks.first?.installProgress {
                observed.append(progress)
            }
        }
        let task = try manager.beginAPKInstall(profiles[0].id, file: file)
        try expectEqual(manager.tasks.first?.installProgress?.stage, .preparing)
        try expectThrows(try manager.beginAPKInstall(profiles[0].id, file: file))
        await manager.connect(profiles[1].id)?.value
        let secondTask = try manager.beginAPKInstall(profiles[1].id, file: file)
        await manager.waitForTask(task)
        await manager.waitForTask(secondTask)
        guard let command = runner.commands.first(where: { $0.arguments.contains("install") }) else {
            throw ManagerError.message("missing install")
        }
        try expectEqual(command.arguments, ["-s", "127.0.0.1:5556", "install", "--no-streaming", "-r", file.path])
        try expectTrue(command.terminalOutput)
        try expectEqual(command.environment["TERM"], "xterm")
        try expectTrue(runner.calls.contains(["-s", "127.0.0.1:5557", "install", "--no-streaming", "-r", file.path]))
        try expectTrue(observed.contains { $0.stage == .uploading && $0.fraction == 0.42 })
        try expectTrue(observed.contains { $0.stage == .installing && $0.fraction == nil })
        try expectFalse(observed.contains { $0.stage == .completed })
        try expectEqual(manager.tasks.first?.installProgress?.totalBytes, 1024)
        try expectEqual(manager.tasks.first?.installProgress?.stage, .completed)
        try expectEqual(manager.tasks.first?.state, .succeeded)
        try expectEqual(manager.tasks.last?.state, .succeeded)
        await manager.disconnectAll()
    }
    func testAPKInstallFailureAndCancellationNeverReportCompletion() async throws {
        let (manager, runner, _, profiles) = try environment()
        await manager.connect(profiles[0].id)?.value
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).apk")
        try Data([0]).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        runner.operationChunks = ["\r[100%] example.apk: 100%\r", "example.apk: 1 file pushed, 0 skipped.\n"]
        runner.operationResult = CommandResult(exitCode: 1, output: "Failure [INSTALL_FAILED_UPDATE_INCOMPATIBLE]\n")
        let failed = try manager.beginAPKInstall(profiles[0].id, file: file)
        await manager.waitForTask(failed)
        try expectEqual(manager.tasks.first?.state, .failed)
        try expectEqual(manager.tasks.first?.installProgress?.stage, .installing)
        try expectNil(manager.tasks.first?.installProgress?.fraction)
        runner.operationDelay = 2_000_000_000
        let cancelled = try manager.beginAPKInstall(profiles[0].id, file: file)
        try await Task.sleep(nanoseconds: 20_000_000)
        manager.cancelTask(cancelled); await manager.waitForTask(cancelled)
        try expectEqual(manager.tasks.last?.state, .cancelled)
        try expectFalse(manager.tasks.last?.installProgress?.stage == .completed)
        runner.operationDelay = 0
        runner.operationResult = CommandResult(timedOut: true)
        let timedOut = try manager.beginAPKInstall(profiles[0].id, file: file)
        await manager.waitForTask(timedOut)
        try expectEqual(manager.tasks.last?.state, .failed)
        try expectFalse(manager.tasks.last?.installProgress?.stage == .completed)
        await manager.disconnectAll()
    }
    func testDisconnectCancelsPendingConnectWithoutLeakingTunnel() async throws {
        let (manager, _, transport, profiles) = try environment()
        transport.openDelay = 500_000_000
        let job = manager.connect(profiles[0].id)
        try await Task.sleep(nanoseconds: 20_000_000)
        await manager.disconnect(profiles[0].id).value
        await job?.value
        try expectEqual(manager.session(profiles[0].id).state, .disconnected)
        try expectTrue(transport.handles.values.allSatisfy { !$0.isRunning })
    }
    func testReconnectCancelsOldTasksBeforeReplacingSession() async throws {
        let (manager, runner, transport, profiles) = try environment()
        await manager.connect(profiles[0].id)?.value
        let old = transport.handles[5556]!
        runner.operationDelay = 2_000_000_000
        let task = try manager.beginADBTask(profiles[0].id, title: "push", arguments: ["push", "file", "/sdcard/"])
        try await Task.sleep(nanoseconds: 20_000_000)
        await manager.connect(profiles[0].id)?.value
        await manager.waitForTask(task)
        try expectEqual(manager.tasks.first(where: { $0.id == task })?.state, .cancelled)
        try expectFalse(old.isRunning)
        try expectTrue(transport.handles[5556]!.isRunning)
        try expectEqual(manager.session(profiles[0].id).state, .online)
        await manager.disconnectAll()
    }
    func testUnexpectedTransportExitDoesNotAffectOtherDevice() async throws {
        let (manager, _, transport, profiles) = try environment()
        await manager.connect(profiles[0].id)?.value; await manager.connect(profiles[1].id)?.value
        transport.crash(5556)
        try expectEqual(manager.session(profiles[0].id).state, .failed)
        try expectNil(manager.session(profiles[0].id).serial)
        try expectEqual(manager.session(profiles[1].id).state, .online)
        await manager.disconnectAll()
    }

    func testRepeatedImportPreservesGUIEditsAndCredentials() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let legacy = root.appendingPathComponent("legacy"), users = legacy.appendingPathComponent("users")
        try FileManager.default.createDirectory(at: users, withIntermediateDirectories: true)
        let original = "tc" + String(repeating: "L", count: 30)
        try Data((original + "\n").utf8).write(to: users.appendingPathComponent("carA"))
        let vault = MemoryCredentialStore(), runner = FakeRunner(), transport = FakeTransport()
        let store = ConfigurationStore(directory: root.appendingPathComponent("gui"))
        let settings = ToolSettings(tailcat: "/usr/bin/true", adb: "/usr/bin/true", addressBookDirectory: legacy.path)
        let manager = SessionManager(configuration: AppConfiguration(tools: settings), configurationStore: store,
                                     credentials: vault, runner: runner, makeTransport: { _, _ in transport })
        try expectEqual(try manager.importLegacy(), 1)
        let id = manager.profiles[0].id
        let edited = "tc" + String(repeating: "E", count: 30)
        _ = try manager.saveDevice(id: id, name: "Edited name", address: edited, preferredPort: 6666, remotePort: 5555)
        try expectEqual(try manager.importLegacy(), 0)
        try expectEqual(manager.profiles.count, 1)
        try expectEqual(manager.profiles[0].name, "Edited name")
        try expectEqual(try vault.read(id: id), edited)
        try expectEqual(try String(contentsOf: users.appendingPathComponent("carA")), original + "\n")
        try expectEqual(try store.load().profiles[0].id, id)
        let metadata = try String(contentsOf: store.directory.appendingPathComponent("configuration.json"))
        try expectFalse(metadata.contains(original) || metadata.contains(edited))
    }

    func testTemporaryDevicesAreMemoryOnlyAndCloseIndependently() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let saved = DeviceProfile(name: "Saved", preferredPort: 5556), vault = SpyCredentialStore()
        try vault.write("tc" + String(repeating: "S", count: 30), id: saved.id)
        let runner = FakeRunner(), transport = FakeTransport(), store = ConfigurationStore(directory: root)
        let settings = ToolSettings(tailcat: "/usr/bin/true", adb: "/usr/bin/true", scrcpy: "/usr/bin/true")
        let config = AppConfiguration(profiles: [saved], tools: settings)
        try store.save(config)
        let before = try Data(contentsOf: root.appendingPathComponent("configuration.json"))
        let manager = SessionManager(configuration: config, configurationStore: store, credentials: vault, runner: runner,
                                     monitorInterval: 60_000_000_000, makeTransport: { _, _ in transport })
        await manager.connect(saved.id)?.value
        vault.resetCounts()
        let first = try manager.saveTemporaryDevice(address: "tc" + String(repeating: "T", count: 30), preferredPort: 6666)
        let second = try manager.saveTemporaryDevice(address: "tc" + String(repeating: "U", count: 30), preferredPort: 6667)
        try expectEqual(manager.temporaryProfiles.map(\.name), ["临时设备 1", "临时设备 2"])
        let a = manager.connect(first), b = manager.connect(second)
        await a?.value; await b?.value
        try expectEqual(manager.session(first).state, .online)
        try expectEqual(manager.profiles.map(\.id), [saved.id])
        try expectEqual(try Data(contentsOf: root.appendingPathComponent("configuration.json")), before)
        let task = try manager.beginADBTask(first, title: "Temporary shell", arguments: ["shell", "id"])
        await manager.waitForTask(task)
        try expectEqual(manager.tasks.first(where: { $0.id == task })?.state, .succeeded)
        try expectTrue(runner.calls.contains(["-s", "127.0.0.1:6666", "shell", "id"]))
        manager.diagnose(first)
        try await Task.sleep(nanoseconds: 20_000_000)
        try await manager.removeDevice(first)
        try expectFalse(transport.handles[6666]!.isRunning)
        try expectTrue(transport.handles[6667]!.isRunning)
        try expectTrue(transport.handles[5556]!.isRunning)
        try expectFalse(manager.isTemporary(first))
        try manager.configureInstalledTool(.scrcpy, path: "/usr/bin/true")
        try expectEqual(try store.load().profiles.map(\.id), [saved.id])
        await manager.disconnect(second).value
        try expectTrue(manager.isTemporary(second))
        await manager.connect(second)?.value
        try expectEqual(manager.session(second).state, .online)
        await manager.shutdown()
        try expectTrue(manager.temporaryProfiles.isEmpty)
        try expectTrue(transport.handles.values.allSatisfy { !$0.isRunning })
        try expectEqual(vault.reads, 0); try expectEqual(vault.writes, 0); try expectEqual(vault.deletes, 0)
        let restored = SessionManager(configuration: try store.load(), credentials: vault, runner: runner)
        try expectTrue(restored.temporaryProfiles.isEmpty)
        try expectEqual(restored.allProfiles.count, 1)
    }

    func testPromotionKeepsConnectionAndRunningTask() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = FakeRunner(), transport = FakeTransport(), vault = SpyCredentialStore(), store = ConfigurationStore(directory: root)
        let config = AppConfiguration(tools: ToolSettings(tailcat: "/usr/bin/true", adb: "/usr/bin/true"))
        let manager = SessionManager(configuration: config, configurationStore: store, credentials: vault, runner: runner,
                                     monitorInterval: 60_000_000_000, makeTransport: { _, _ in transport })
        let address = "tc" + String(repeating: "P", count: 30)
        let id = try manager.saveTemporaryDevice(address: address, preferredPort: 6666)
        await manager.connect(id)?.value
        let handle = transport.handles[6666]!, serial = manager.session(id).serial
        runner.operationDelay = 100_000_000
        let task = try manager.beginADBTask(id, title: "Task across promotion", arguments: ["shell", "id"])
        try await Task.sleep(nanoseconds: 20_000_000)
        let connects = runner.calls.filter { $0.first == "connect" }.count
        try manager.promoteTemporaryDevice(id, name: "Keep this device")
        try expectFalse(manager.isTemporary(id))
        try expectEqual(manager.allProfiles.filter { $0.id == id }.count, 1)
        try expectEqual(manager.session(id).serial, serial)
        try expectTrue(handle.isRunning)
        try expectEqual(handle.stopCount, 0)
        await manager.waitForTask(task)
        try expectEqual(manager.tasks.first(where: { $0.id == task })?.state, .succeeded)
        try expectEqual(runner.calls.filter { $0.first == "connect" }.count, connects)
        try expectEqual(vault.writes, 1)
        try expectEqual(try vault.read(id: id), address)
        try expectEqual(try store.load().profiles.first?.id, id)
        try expectFalse(try String(contentsOf: root.appendingPathComponent("configuration.json")).contains(address))
        await manager.shutdown()
    }

    func testFailedPromotionRollsBackAndTemporaryStartupCancels() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let blocked = root.appendingPathComponent("not-a-directory")
        try Data("keep".utf8).write(to: blocked)
        let vault = SpyCredentialStore(), runner = FakeRunner(), transport = FakeTransport()
        let manager = SessionManager(configuration: AppConfiguration(tools: ToolSettings(tailcat: "/usr/bin/true", adb: "/usr/bin/true")),
            configurationStore: ConfigurationStore(directory: blocked), credentials: vault, runner: runner,
            monitorInterval: 60_000_000_000, makeTransport: { _, _ in transport })
        let id = try manager.saveTemporaryDevice(address: "tc" + String(repeating: "F", count: 30), preferredPort: 6666)
        await manager.connect(id)?.value
        try expectThrows(try manager.promoteTemporaryDevice(id, name: "Failed save"))
        try expectTrue(manager.isTemporary(id)); try expectTrue(manager.profiles.isEmpty)
        try expectTrue(transport.handles[6666]!.isRunning)
        try expectEqual(vault.writes, 1); try expectEqual(vault.deletes, 1); try expectNil(try vault.read(id: id))
        try expectEqual(try String(contentsOf: blocked), "keep")
        transport.openDelay = 500_000_000
        let pending = try manager.saveTemporaryDevice(address: "tc" + String(repeating: "C", count: 30), preferredPort: 6667)
        let job = manager.connect(pending)
        try await Task.sleep(nanoseconds: 20_000_000)
        try await manager.removeDevice(pending); await job?.value
        try expectFalse(manager.isTemporary(pending))
        try expectTrue(transport.handles[6667] == nil || transport.handles[6667]?.isRunning == false)
        try expectTrue(transport.handles[6666]!.isRunning)
        await manager.shutdown()
    }
}
