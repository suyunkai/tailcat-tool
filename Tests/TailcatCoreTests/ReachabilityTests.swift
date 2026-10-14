import Foundation
import TailcatCore

private final class AuthorizationProbeStore: CredentialStore {
    var values: [UUID: String] = [:]
    var reads = 0, observations = 0
    var denyObservation = true
    func read(id: UUID) throws -> String? { reads += 1; return values[id] }
    func readForObservation(id: UUID) throws -> String? {
        observations += 1
        if denyObservation { throw ManagerError.message("需要用户主动授权") }
        return values[id]
    }
    func write(_ address: String, id: UUID) throws { values[id] = address }
    func delete(id: UUID) throws { values[id] = nil }
}

@MainActor private final class PingProbeRunner: CommandExecuting {
    var calls: [Command] = []
    var active = 0, maximumActive = 0, cancelled = 0
    var delay: UInt64 = 20_000_000
    var outcomes: [String: CommandResult] = [:]
    func start(_ command: Command, onOutput: @escaping (String) -> Void,
               onExit: @escaping (Int32) -> Void) throws -> any RunningProcess {
        throw ManagerError.message("测试不应创建转发进程")
    }
    func run(_ command: Command, onOutput: @escaping (String) -> Void) async throws -> CommandResult {
        calls.append(command); active += 1; maximumActive = max(active, maximumActive)
        defer { active -= 1 }
        do { try await Task.sleep(nanoseconds: delay) }
        catch { cancelled += 1; throw error }
        return outcomes[command.arguments.last ?? ""] ?? CommandResult(output: "pong in 12.3ms via DERP(test)\n")
    }
}

@MainActor final class ReachabilityTests {
    func testCredentialsReuseAuthorizationAndUpdateCache() throws {
        let source = AuthorizationProbeStore(), store = CachedCredentialStore(source), id = UUID()
        let first = "tc" + String(repeating: "A", count: 30)
        let second = "tc" + String(repeating: "B", count: 30)
        source.values[id] = first
        try expectThrows(try store.readForObservation(id: id))
        try expectEqual(source.reads, 0)
        // A failed silent read must not cache a missing value or prevent explicit authorization.
        try expectEqual(try store.read(id: id), first)
        for _ in 0..<5 {
            try expectEqual(try store.read(id: id), first)
            try expectEqual(try store.readForObservation(id: id), first)
        }
        try expectEqual(source.reads, 1)
        try expectEqual(source.observations, 1)
        try store.write(second, id: id)
        try expectEqual(try store.readForObservation(id: id), second)
        try store.delete(id: id)
        try expectNil(try store.read(id: id))
        try expectEqual(source.reads, 1)
    }

    func testAllDevicesBoundedResultsAndNoADBCommands() async throws {
        let runner = PingProbeRunner(), checker = ReachabilityChecker(runner: runner)
        let profiles = (0..<7).map { DeviceProfile(name: "Device \($0)") }
        let addresses = profiles.enumerated().reduce(into: [UUID: String]()) { values, pair in
            values[pair.element.id] = "tc" + String(repeating: Character(String(pair.offset)), count: 30)
        }
        runner.outcomes[addresses[profiles[1].id]!] = CommandResult(output: "pong in 1.4ms via 192.0.2.1:1234\n")
        runner.outcomes[addresses[profiles[2].id]!] = CommandResult(exitCode: 1, output: "timeout \(addresses[profiles[2].id]!)\n")
        runner.outcomes[addresses[profiles[3].id]!] = CommandResult(timedOut: true)
        runner.outcomes[addresses[profiles[4].id]!] = CommandResult(output: "no pong")
        checker.start(profiles: profiles, tailcatPath: "/usr/bin/true", temporaryIDs: [profiles[6].id],
                      adbState: { $0 == profiles[3].id ? .online : .disconnected }) { id in
            if id == profiles[5].id { return nil }
            return addresses[id]
        }
        while checker.isRunning { try await Task.sleep(nanoseconds: 10_000_000) }
        try expectEqual(runner.maximumActive, 3)
        try expectEqual(runner.calls.count, 6)
        try expectTrue(runner.calls.allSatisfy { $0.arguments.starts(with: ["--key=new", "ping", "--timeout=5s"]) && $0.arguments.count == 4 && $0.timeout == 8 })
        try expectEqual(checker.results.map(\.id), profiles.map(\.id))
        try expectEqual(checker.results.map(\.state), [.reachable, .reachable, .unreachable, .unreachable, .failed, .failed, .reachable])
        try expectEqual(checker.results[0].latency, "12.3ms")
        try expectTrue(checker.results[0].route.hasPrefix("中继"))
        try expectTrue(checker.results[1].route.hasPrefix("直连"))
        try expectFalse(checker.results[2].detail.contains(addresses[profiles[2].id]!))
        try expectTrue(checker.results[6].temporary)
        try expectEqual(checker.completedCount, 7)
        try expectEqual(checker.reachableCount, 3)
        try expectEqual(checker.results[3].adbState, .online)
        try expectEqual(checker.adbOnlineCount, 1)
    }

    func testCancellationStopsActiveTestsAndQueueBeforeRestart() async throws {
        let runner = PingProbeRunner(), checker = ReachabilityChecker(runner: runner)
        runner.delay = 5_000_000_000
        let profiles = (0..<8).map { DeviceProfile(name: "Device \($0)") }
        let address = "tc" + String(repeating: "C", count: 30)
        checker.start(profiles: profiles, tailcatPath: "/usr/bin/true") { _ in address }
        while runner.active < 3 { try await Task.sleep(nanoseconds: 1_000_000) }
        checker.cancel()
        checker.start(profiles: [], tailcatPath: "/usr/bin/true") { _ in nil }
        await checker.shutdown()
        try expectEqual(runner.calls.count, 3)
        try expectEqual(runner.cancelled, 3)
        try expectEqual(runner.active, 0)
        try expectTrue(checker.results.allSatisfy { $0.state == .cancelled })
        try expectFalse(checker.isRunning)
        runner.delay = 1_000_000
        checker.start(profiles: Array(profiles.prefix(1)), tailcatPath: "/usr/bin/true") { _ in address }
        while checker.isRunning { try await Task.sleep(nanoseconds: 1_000_000) }
        try expectEqual(checker.results.map(\.state), [.reachable])
    }
}
