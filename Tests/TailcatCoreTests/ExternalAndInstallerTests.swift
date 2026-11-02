import Foundation
import TailcatCore

@MainActor private final class StubHandle: RunningProcess {
    let pid: Int32 = 77777
    var isRunning = true
    func stop() async { isRunning = false }
}

@MainActor private final class StubRunner: CommandExecuting {
    var commands: [Command] = []
    var respond: (Command) async throws -> CommandResult = { _ in CommandResult() }
    func start(_ command: Command, onOutput: @escaping (String) -> Void, onExit: @escaping (Int32) -> Void) throws -> any RunningProcess { StubHandle() }
    func run(_ command: Command, onOutput: @escaping (String) -> Void) async throws -> CommandResult {
        commands.append(command)
        let result = try await respond(command); onOutput(result.output); return result
    }
}

@MainActor private final class StubScanner: CLISessionScanning {
    var found: [UUID: [ExternalCLISession]] = [:]
    func scan(root: URL, profiles: [DeviceProfile], adbPath: String,
              addressForProfile: @escaping @MainActor (UUID) throws -> String?) async throws -> [UUID: [ExternalCLISession]] { found }
}

@MainActor private final class StubTransport: ForwardTransport {
    let handle = StubHandle()
    func open(address: String, preferredPort: Int?, remotePort: Int, identity: ClientIdentity, onLog: @escaping (String) -> Void,
              onExit: @escaping (Int32) -> Void) async throws -> ForwardConnection { ForwardConnection(handle: handle, port: preferredPort ?? 5560) }
}

@MainActor final class ExternalAndInstallerTests {
    private let address = "tc" + String(repeating: "C", count: 30)
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tailcat-check-\(UUID())")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("bridges"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("users"), withIntermediateDirectories: true)
        try Data((address + "\n").utf8).write(to: root.appendingPathComponent("users/car"))
        return root
    }
    private func bridge(_ pid: Int, _ port: Int) -> String {
        "\(pid) /opt/homebrew/bin/socat TCP-LISTEN:\(port),bind=127.0.0.1,reuseaddr,fork EXEC:/opt/homebrew/bin/tailcat \(address) 5555\n"
    }

    func testScannerValidatesOwnershipAndKeepsMultiplePorts() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        for (port, pid) in [(5556, 1001), (5557, 1002), (5558, 1003), (5559, 1004), (5560, 1005), (5561, 1006)] {
            try Data("\(pid)\n".utf8).write(to: root.appendingPathComponent("bridges/\(port).pid"))
        }
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("bridges/5562.pid"), withDestinationURL: root.appendingPathComponent("bridges/5556.pid"))
        let before = try Data(contentsOf: root.appendingPathComponent("bridges/5556.pid"))
        let profile = DeviceProfile(name: "Renamed", legacyUsername: "car"), runner = StubRunner()
        runner.respond = { [self] command in
            switch command.executable.lastPathComponent {
            case "ps": return CommandResult(output: bridge(1001, 5556) + bridge(1002, 5557) + bridge(1003, 5558)
                + "1004 /usr/bin/python3 foreign.py\n" + bridge(1005, 5563) + bridge(1006, 5561))
            case "lsof": return CommandResult(output: "p1001\nn127.0.0.1:5556\np1002\nn127.0.0.1:5557\np1004\nn127.0.0.1:5559\np1005\nn127.0.0.1:5560\np1006\nn127.0.0.1:5561\n")
            default: return CommandResult(output: "List of devices attached\n127.0.0.1:5556 device product:DHU model:E245 transport_id:26\n127.0.0.1:5557 unauthorized\n")
            }
        }
        let scanner = CLISessionScanner(runner: runner)
        let result = try await scanner.scan(root: root, profiles: [profile], adbPath: "/usr/bin/true", addressForProfile: { [self] _ in address })
        try expectEqual(result[profile.id]?.map(\.port), [5556, 5557, 5561])
        try expectEqual(result[profile.id]?.map(\.state), [.online, .unauthorized, .offline])
        try expectEqual(result[profile.id]?.first?.model, "E245")
        try expectEqual(try Data(contentsOf: root.appendingPathComponent("bridges/5556.pid")), before)
        try expectEqual(try String(contentsOf: root.appendingPathComponent("users/car")), address + "\n")
        try expectTrue(runner.commands.allSatisfy { ["ps", "lsof", "true"].contains($0.executable.lastPathComponent) })
        try expectFalse(runner.commands.contains { $0.arguments.contains("connect") || $0.arguments.contains("disconnect") || $0.arguments.contains("kill-server") })
        let edited = try await scanner.scan(root: root, profiles: [profile], adbPath: "/usr/bin/true", addressForProfile: { _ in "tc" + String(repeating: "D", count: 30) })
        try expectTrue(edited.isEmpty)
        runner.respond = { _ in CommandResult(exitCode: 1) }
        try expectTrue(try await scanner.scan(root: root, profiles: [profile], adbPath: "/usr/bin/true", addressForProfile: { [self] _ in address }).isEmpty)
    }

    func testLegacyPIDAndSymlinkRootAreReadOnly() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try Data("1001\n".utf8).write(to: root.appendingPathComponent("bridge.pid"))
        try Data("5556\n".utf8).write(to: root.appendingPathComponent("local-port"))
        let profile = DeviceProfile(name: "car", legacyUsername: "car"), runner = StubRunner()
        runner.respond = { [self] command in
            if command.executable.lastPathComponent == "ps" { return CommandResult(output: bridge(1001, 5556)) }
            if command.executable.lastPathComponent == "lsof" { return CommandResult(output: "p1001\nn127.0.0.1:5556\n") }
            return CommandResult(output: "127.0.0.1:5556 device model:Car\n")
        }
        let scanner = CLISessionScanner(runner: runner)
        let result = try await scanner.scan(root: root, profiles: [profile], adbPath: "/usr/bin/true", addressForProfile: { [self] _ in address })
        try expectEqual(result[profile.id]?.count, 1)
        try expectTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("bridge.pid").path))
        let link = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
        try expectTrue(try await scanner.scan(root: link, profiles: [profile], adbPath: "/usr/bin/true", addressForProfile: { [self] _ in address }).isEmpty)
    }

    func testExternalDisconnectAndShutdownNeverTouchCLI() async throws {
        let external = DeviceProfile(name: "CLI"), owned = DeviceProfile(name: "GUI", preferredPort: 5560)
        let scanner = StubScanner(), runner = StubRunner(), transport = StubTransport(), vault = MemoryCredentialStore()
        try vault.write(address, id: owned.id)
        runner.respond = { command in
            CommandResult(output: command.arguments.contains("get-state") ? "device\n" : "")
        }
        scanner.found = [external.id: [ExternalCLISession(pid: 1001, port: 5556, state: .online)]]
        let manager = SessionManager(configuration: AppConfiguration(profiles: [external, owned], tools: ToolSettings(tailcat: "/usr/bin/true", adb: "/usr/bin/true")),
            credentials: vault, runner: runner, identities: TestingIdentities(), monitorInterval: 60_000_000_000, cliScanner: scanner, makeTransport: { _, _, _ in transport })
        await manager.refreshExternalConnections()
        try expectTrue(manager.session(external.id).isExternalCLI)
        try expectEqual(manager.externalActiveCount, 1)
        try expectNil(manager.connect(external.id))
        await manager.disconnect(external.id).value
        try expectEqual(manager.session(external.id).serial, "127.0.0.1:5556")
        let cliTask = try manager.beginADBTask(external.id, title: "CLI shell", arguments: ["shell", "id"])
        await manager.waitForTask(cliTask)
        try expectEqual(manager.tasks.first(where: { $0.id == cliTask })?.state, .succeeded)
        try expectTrue(runner.commands.contains { $0.arguments == ["-s", "127.0.0.1:5556", "shell", "id"] })
        await manager.connect(owned.id)?.value
        try expectEqual(manager.ownedActiveCount, 1)
        // An external channel for a device with a GUI channel remains separately visible.
        scanner.found[owned.id] = [ExternalCLISession(pid: 1002, port: 5557, state: .online)]
        await manager.refreshExternalConnections()
        try expectFalse(manager.session(owned.id).isExternalCLI)
        await manager.shutdown()
        try expectFalse(transport.handle.isRunning)
        try expectEqual(manager.session(external.id).state, .online)
        try expectTrue(runner.commands.contains { $0.arguments == ["disconnect", "127.0.0.1:5560"] })
        try expectFalse(runner.commands.contains { $0.arguments == ["disconnect", "127.0.0.1:5556"] || $0.arguments == ["disconnect", "127.0.0.1:5557"] })
        scanner.found = [:]; await manager.refreshExternalConnections()
        try expectEqual(manager.session(external.id).state, .disconnected)
        try await manager.removeDevice(external.id)
        try expectFalse(runner.commands.contains { $0.arguments.contains("kill-server") })
    }

    private func cliEnvironment() async throws -> (SessionManager, StubRunner, StubScanner, DeviceProfile) {
        let profile = DeviceProfile(name: "CLI"), runner = StubRunner(), scanner = StubScanner(), vault = MemoryCredentialStore()
        try vault.write(address, id: profile.id)
        runner.respond = { command in
            if command.arguments.contains("get-state") { return CommandResult(output: "device\n") }
            if command.arguments.contains(where: { $0.contains("getprop ro.product.model") }) {
                return CommandResult(output: "E245\nantora\n11\nTEST-SERIAL\nuid=2000(shell)\n")
            }
            return CommandResult(output: "Success\n")
        }
        scanner.found = [profile.id: [ExternalCLISession(pid: 1001, port: 5556, state: .online)]]
        let manager = SessionManager(configuration: AppConfiguration(profiles: [profile], tools: ToolSettings(tailcat: "/usr/bin/true", adb: "/usr/bin/true", scrcpy: "/usr/bin/true")),
            credentials: vault, runner: runner, identities: TestingIdentities(), monitorInterval: 60_000_000_000, cliScanner: scanner)
        await manager.refreshExternalConnections()
        await manager.refreshDeviceInformation(profile.id)?.value
        return (manager, runner, scanner, profile)
    }

    func testExternalOperationsAndMetadataBindToCLIEntry() async throws {
        let (manager, runner, _, profile) = try await cliEnvironment()
        try expectEqual(manager.session(profile.id).android, "11")
        try expectEqual(manager.session(profile.id).identity, "uid=2000(shell)")
        let terminal = try await manager.terminalCommand(profile.id)
        try expectEqual(terminal.serial, "127.0.0.1:5556")
        let task = try manager.beginADBTask(profile.id, title: "Upload", arguments: ["push", "a file", "/sdcard/"])
        await manager.waitForTask(task)
        let screen = try manager.beginScreen(profile.id)
        await manager.waitForTask(screen)
        try expectEqual(manager.tasks.first(where: { $0.id == task })?.state, .succeeded)
        try expectEqual(manager.tasks.first(where: { $0.id == screen })?.state, .succeeded)
        try expectTrue(runner.commands.contains { $0.arguments == ["-s", "127.0.0.1:5556", "push", "a file", "/sdcard/"] })
        try expectEqual(runner.commands.first(where: { $0.arguments.contains("--max-size=1280") })?.environment["ADB"], "/usr/bin/true")
        await manager.shutdown()
        try expectEqual(manager.session(profile.id).state, .online)
        try expectFalse(runner.commands.contains { $0.arguments.contains("connect") || $0.arguments.contains("disconnect") || $0.arguments.contains("kill-server") })
    }

    func testExternalPIDReplacementAndUnauthorizedBlockOperations() async throws {
        let (manager, runner, scanner, profile) = try await cliEnvironment()
        let task = try manager.beginADBTask(profile.id, title: "Stale target", arguments: ["install", "-r", "test.apk"])
        scanner.found = [profile.id: [ExternalCLISession(pid: 2002, port: 5556, state: .online)]]
        await manager.waitForTask(task)
        try expectEqual(manager.tasks.first(where: { $0.id == task })?.state, .failed)
        try expectFalse(runner.commands.contains { $0.arguments.contains("install") })
        scanner.found = [profile.id: [ExternalCLISession(pid: 2002, port: 5556, state: .unauthorized)]]
        await manager.refreshExternalConnections()
        try expectThrows(try manager.beginADBTask(profile.id, title: "Unauthorized", arguments: ["shell", "id"]))
        scanner.found = [profile.id: [ExternalCLISession(pid: 2002, port: 5556, state: .offline)]]
        await manager.refreshExternalConnections()
        try expectThrows(try manager.beginScreen(profile.id))
        await manager.shutdown()
        try expectFalse(runner.commands.contains { $0.arguments.contains("disconnect") || $0.arguments.contains("kill-server") })
    }

    func testShutdownCancelsGUICreatedCLITaskWithoutDisconnect() async throws {
        let (manager, runner, _, profile) = try await cliEnvironment()
        runner.respond = { command in
            if command.arguments.contains("get-state") { return CommandResult(output: "device\n") }
            try await Task.sleep(nanoseconds: 2_000_000_000)
            return CommandResult()
        }
        let task = try manager.beginScreen(profile.id)
        try await Task.sleep(nanoseconds: 20_000_000)
        await manager.shutdown()
        try expectEqual(manager.tasks.first(where: { $0.id == task })?.state, .cancelled)
        try expectEqual(manager.session(profile.id).serial, "127.0.0.1:5556")
        try expectFalse(runner.commands.contains { $0.arguments.contains("disconnect") || $0.arguments.contains("kill-server") })
    }

    func testInstallerBatchUsesExactCommandsAndConfiguresPaths() async throws {
        let runner = StubRunner(); var paths = ["brew": "/usr/bin/true"]; var configured: [ToolComponent: String] = [:]
        runner.respond = { command in
            let component = command.arguments.contains("android-platform-tools") ? "adb" : command.arguments.last!
            paths[component] = "/test/bin/\(component)"
            return CommandResult(output: "Installed \(component)\n")
        }
        let installer = ComponentInstaller(runner: runner, locate: { paths[$0] })
        let job = installer.install(ToolComponent.allCases) { component, path in configured[component] = path }
        try expectNil(installer.install(.adb) { _ in })
        await job?.value
        try expectEqual(runner.commands.map(\.arguments), [["install", "tailcat"], ["install", "--cask", "android-platform-tools"], ["install", "scrcpy"]])
        try expectEqual(configured.count, 3)
        try expectFalse(installer.failed); try expectFalse(installer.isBusy)
        for command in runner.commands {
            try expectEqual(command.environment["HOMEBREW_NO_INSTALL_UPGRADE"], "1")
            try expectEqual(command.environment["HOMEBREW_NO_AUTO_UPDATE"], "1")
            try expectEqual(command.environment["HOMEBREW_NO_INSTALL_CLEANUP"], "1")
            try expectEqual(command.environment["HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK"], "1")
        }
        await installer.install(.adb) { _ in }?.value
        try expectEqual(runner.commands.count, 3) // Existing executables are configured without invoking brew.
    }

    func testInstallerFailureMissingBrewAndCancellation() async throws {
        let runner = StubRunner(); var configured = false
        let missing = ComponentInstaller(runner: runner, locate: { _ in nil })
        await missing.install(.tailcat) { _ in configured = true }?.value
        try expectTrue(missing.failed); try expectFalse(configured); try expectTrue(runner.commands.isEmpty)
        let installer = ComponentInstaller(runner: runner, locate: { $0 == "brew" ? "/usr/bin/true" : nil })
        runner.respond = { _ in CommandResult(exitCode: 1, output: "download failed") }
        await installer.install(.scrcpy) { _ in configured = true }?.value
        try expectTrue(installer.failed); try expectFalse(configured)
        try expectTrue(installer.message?.contains("download failed") == true)
        runner.respond = { _ in try await Task.sleep(nanoseconds: 2_000_000_000); return CommandResult() }
        let task = installer.install(.adb) { _ in configured = true }
        try await Task.sleep(nanoseconds: 20_000_000)
        installer.cancel(); await task?.value
        try expectTrue(installer.failed); try expectFalse(installer.isBusy); try expectFalse(configured)
        try expectTrue(installer.message?.contains("取消") == true)
    }

    func testInstalledComponentPersistsWhileCLIStaysOnline() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = DeviceProfile(name: "CLI"), scanner = StubScanner(), runner = StubRunner()
        scanner.found = [profile.id: [ExternalCLISession(pid: 1001, port: 5556, state: .online)]]
        let store = ConfigurationStore(directory: root)
        let manager = SessionManager(configuration: AppConfiguration(profiles: [profile], tools: ToolSettings(scrcpy: "")),
                                     configurationStore: store, credentials: MemoryCredentialStore(), runner: runner, identities: TestingIdentities(), cliScanner: scanner)
        await manager.refreshExternalConnections()
        try manager.configureInstalledTool(.scrcpy, path: "/usr/bin/true")
        try expectEqual(try store.load().tools.scrcpy, "/usr/bin/true")
        try expectEqual(manager.session(profile.id).state, .online)
        try expectTrue(runner.commands.isEmpty)
    }
}
