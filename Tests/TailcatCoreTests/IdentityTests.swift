import Foundation
import TailcatCore

@MainActor final class TestingIdentities: ClientIdentityProviding {
    func identity(deviceID: UUID, role: ClientIdentityRole, executable: URL,
                  runner: any CommandExecuting) async throws -> ClientIdentity {
        let name = "\(deviceID.uuidString.lowercased())-\(role.rawValue)"
        return ClientIdentity(file: URL(fileURLWithPath: "/test-identities/\(name).private.json"),
                              publicKey: "nodekey:" + String(repeating: role == .connection ? "a" : "b", count: 64))
    }
}

@MainActor private final class IdentityProbeRunner: CommandExecuting {
    var calls: [Command] = []
    var active: [String: Int] = [:]
    var maximumForKey = 0, maximumTotal = 0
    func start(_ command: Command, onOutput: @escaping (String) -> Void,
               onExit: @escaping (Int32) -> Void) throws -> any RunningProcess { throw ManagerError.message("unexpected start") }
    func run(_ command: Command, onOutput: @escaping (String) -> Void) async throws -> CommandResult {
        calls.append(command)
        let key = command.arguments[0]
        active[key, default: 0] += 1
        maximumForKey = max(maximumForKey, active[key]!)
        maximumTotal = max(maximumTotal, active.values.reduce(0, +))
        defer { active[key, default: 0] -= 1 }
        try await Task.sleep(nanoseconds: 100_000_000)
        return CommandResult(output: "pong in 1.0ms via DERP(test)\n")
    }
}

@MainActor final class IdentityTests {
    func testProbesSerializeOnlyTheSameSavedIdentity() async throws {
        let runner = IdentityProbeRunner(), pinger = ClientPinger(identities: TestingIdentities())
        let first = UUID(), second = UUID(), executable = URL(fileURLWithPath: "/usr/bin/true")
        async let a = pinger.ping(deviceID: first, executable: executable, runner: runner, address: "test", seconds: 3)
        async let b = pinger.ping(deviceID: first, executable: executable, runner: runner, address: "test", seconds: 3)
        async let c = pinger.ping(deviceID: second, executable: executable, runner: runner, address: "test", seconds: 3)
        _ = try await (a, b, c)
        let pings = runner.calls.filter { $0.arguments.contains("ping") }
        try expectEqual(pings.count, 3)
        try expectEqual(runner.maximumForKey, 1)
        try expectEqual(runner.maximumTotal, 2)
        try expectEqual(Set(pings.map { $0.arguments[0] }).count, 2)
    }

    func testCustomRelayIsExplicitAndPreservesTheDeviceIdentity() async throws {
        let runner = IdentityProbeRunner(), pinger = ClientPinger(identities: TestingIdentities())
        let id = UUID(), executable = URL(fileURLWithPath: "/usr/bin/true")
        _ = try await pinger.ping(deviceID: id, executable: executable, runner: runner, address: "default-address", seconds: 3)
        _ = try await pinger.ping(deviceID: id, executable: executable, runner: runner, address: "custom-address", seconds: 3,
                                  relaySource: "https://relay.example/map.json")
        _ = try await pinger.ping(deviceID: id, executable: executable, runner: runner, address: "another-default", seconds: 3)
        let pings = runner.calls.filter { $0.arguments.contains("ping") }
        try expectEqual(pings.count, 3)
        try expectEqual(Set(pings.map { $0.arguments[0] }).count, 1)
        try expectEqual(pings.map { $0.arguments[1] }, [TailcatRelay.argument, "--derpmap-url=https://relay.example/map.json", TailcatRelay.argument])
        try expectEqual(pings.map { $0.arguments.last }, ["default-address", "custom-address", "another-default"])
    }

    func testNativeIdentitySurvivesStoreAndProcessRestarts() async throws {
        guard let path = ToolLocator.find("tailcat") else { throw ManagerError.message("Native check requires installed Tailcat") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tailcat-identity-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = ProcessRunner(), executable = URL(fileURLWithPath: path), id = UUID()
        let store = ClientIdentityStore(directory: root)
        async let first = store.identity(deviceID: id, role: .connection, executable: executable, runner: runner)
        async let concurrent = store.identity(deviceID: id, role: .connection, executable: executable, runner: runner)
        let original = try await first
        try expectEqual(original, try await concurrent)
        let inode = try FileManager.default.attributesOfItem(atPath: original.file.path)[.systemFileNumber] as? UInt64
        let reopened = try await ClientIdentityStore(directory: root).identity(deviceID: id, role: .connection, executable: executable, runner: runner)
        try expectEqual(original, reopened)
        try expectEqual(inode, try FileManager.default.attributesOfItem(atPath: reopened.file.path)[.systemFileNumber] as? UInt64)
        try expectEqual(try FileManager.default.attributesOfItem(atPath: original.file.path)[.posixPermissions] as? Int, 0o600)
        try expectEqual(try FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions] as? Int, 0o700)
        let probe = try await store.identity(deviceID: id, role: .probe, executable: executable, runner: runner)
        let other = try await store.identity(deviceID: UUID(), role: .connection, executable: executable, runner: runner)
        try expectEqual(Set([original.publicKey, probe.publicKey, other.publicKey]).count, 3)
        try expectFalse(original.argument.contains("--key=new"))
    }

    func testNativeInvalidIdentityIsNeverReplaced() async throws {
        guard let path = ToolLocator.find("tailcat") else { throw ManagerError.message("Native check requires installed Tailcat") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tailcat-identity-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("broken.private.json")
        try Data("invalid test fixture".utf8).write(to: file)
        let inode = try FileManager.default.attributesOfItem(atPath: file.path)[.systemFileNumber] as? UInt64
        let store = ClientIdentityStore(directory: root), runner = ProcessRunner(), executable = URL(fileURLWithPath: path)
        do {
            _ = try await store.identity(named: "broken", executable: executable, runner: runner)
            throw ManagerError.message("Invalid identity should fail")
        } catch {
            try expectFalse(error.localizedDescription == "Invalid identity should fail")
        }
        try expectEqual(inode, try FileManager.default.attributesOfItem(atPath: file.path)[.systemFileNumber] as? UInt64)
        try expectEqual(try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int, "invalid test fixture".utf8.count)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("linked.private.json"), withDestinationURL: file)
        do {
            _ = try await store.identity(named: "linked", executable: executable, runner: runner)
            throw ManagerError.message("Linked identity should fail")
        } catch { try expectFalse(error.localizedDescription == "Linked identity should fail") }
    }

    func testNativeWhitelistAcceptsTheSavedIdentityAfterReconnect() async throws {
        guard let path = ToolLocator.find("tailcat") else { throw ManagerError.message("Native check requires installed Tailcat") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tailcat-whitelist-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = ProcessRunner(), executable = URL(fileURLWithPath: path), id = UUID()
        let store = ClientIdentityStore(directory: root)
        let allowed = try await store.identity(deviceID: id, role: .connection, executable: executable, runner: runner)
        let denied = try await store.identity(deviceID: id, role: .probe, executable: executable, runner: runner)
        let addressFile = root.appendingPathComponent("test-server-address")
        let server = try runner.start(Command(executable, ["--key=new", "--derpmap-url=none", "serve", "--allow=\(allowed.publicKey)", "43210"],
                                              environment: ["TS_DEBUG_TAILCAT_LOCAL_DERP": "1", "TAILCAT_ADDR_FILE": addressFile.path]),
                                      onOutput: { _ in }, onExit: { _ in })
        do {
            for _ in 0..<100 {
                if FileManager.default.fileExists(atPath: addressFile.path) { break }
                guard server.isRunning else { throw ManagerError.message("Local whitelist test server exited") }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            let address = try String(contentsOf: addressFile).trimmingCharacters(in: .whitespacesAndNewlines)
            for _ in 0..<2 {
                let identity = try await ClientIdentityStore(directory: root).identity(deviceID: id, role: .connection, executable: executable, runner: runner)
                let result = try await runner.run(Command(executable, [identity.argument, "--derpmap-url=none", "ping", "--timeout=3s", address], timeout: 6))
                try expectEqual(result.exitCode, 0)
                try expectTrue(result.output.contains("pong in "))
            }
            let blocked = try await runner.run(Command(executable, [denied.argument, "--derpmap-url=none", "ping", "--timeout=1s", address], timeout: 4))
            try expectFalse(blocked.exitCode == 0)
        } catch { await server.stop(); throw error }
        await server.stop()
    }
}
