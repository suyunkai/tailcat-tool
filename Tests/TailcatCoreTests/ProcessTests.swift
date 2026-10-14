import Foundation
import TailcatCore

@MainActor private final class RecordingRunner: CommandExecuting {
    private let runner = ProcessRunner()
    var starts: [Command] = []
    func start(_ command: Command, onOutput: @escaping (String) -> Void,
               onExit: @escaping (Int32) -> Void) throws -> any RunningProcess {
        starts.append(command)
        return try runner.start(command, onOutput: onOutput, onExit: onExit)
    }
    func run(_ command: Command, onOutput: @escaping (String) -> Void) async throws -> CommandResult {
        try await runner.run(command, onOutput: onOutput)
    }
}

@MainActor final class ProcessTests {
    func testBothPipesDrainAndTrailingOutputIsPreserved() async throws {
        let runner = ProcessRunner()
        let command = Command(URL(fileURLWithPath: "/bin/sh"), ["-c", "i=0; while [ $i -lt 3000 ]; do echo output; echo error >&2; i=$((i+1)); done; echo FINAL"], timeout: 10)
        let result = try await runner.run(command)
        try expectEqual(result.exitCode, 0)
        try expectTrue(result.output.contains("error"))
        try expectTrue(result.output.contains("output"))
        try expectTrue(result.output.contains("FINAL"))
    }
    func testTimeoutAndCancellationStopOwnedProcess() async throws {
        let runner = ProcessRunner()
        let result = try await runner.run(Command(URL(fileURLWithPath: "/bin/sleep"), ["30"], timeout: 0.1))
        try expectTrue(result.timedOut)
        let job = Task { try await runner.run(Command(URL(fileURLWithPath: "/bin/sleep"), ["30"], timeout: 60)) }
        try await Task.sleep(nanoseconds: 30_000_000)
        job.cancel()
        let cancelled = try await job.value
        try expectTrue(cancelled.cancelled)
    }
    func testArgumentsWithSpacesAreNotEvaluatedByShell() async throws {
        let runner = ProcessRunner()
        let literal = "a file ' with $(echo unsafe)"
        let result = try await runner.run(Command(URL(fileURLWithPath: "/usr/bin/printf"), ["%s", literal]))
        try expectEqual(result.output, literal)
    }

    func testNativeTailcatListeners() async throws {
        guard let path = ToolLocator.find("tailcat") else { throw ManagerError.message("Native check requires installed Tailcat") }
        let runner = RecordingRunner()
        let transport = TailcatTransport(executable: URL(fileURLWithPath: path), runner: runner)
        // Public documentation example: only bind local listeners, never dial a remote port.
        let address = "tcomFwWCCcjS5nKNqAod034nWoJZW0LZqDhhC8U_dKdnDRYQ8uNGFpGQEu"
        let first = try await transport.open(address: address, preferredPort: nil, remotePort: 5555, onLog: { _ in }, onExit: { _ in })
        do {
            let second = try await transport.open(address: address, preferredPort: nil, remotePort: 5555, onLog: { _ in }, onExit: { _ in })
            do {
                // Occupied OS ports may require extra bind attempts.
                try expectTrue(runner.starts.count >= 2)
                try expectTrue(runner.starts.allSatisfy { $0.arguments.starts(with: ["--key=new", "forward", "--bind=127.0.0.1"]) })
                try expectFalse(first.port == second.port)
                try expectTrue(first.handle.isRunning && second.handle.isRunning)
                await first.handle.stop()
                try expectFalse(first.handle.isRunning)
                try expectTrue(second.handle.isRunning)
                await second.handle.stop()
                try expectFalse(second.handle.isRunning)
            } catch { await second.handle.stop(); throw error }
        } catch { await first.handle.stop(); throw error }
        await first.handle.stop()
    }

    func testNativeEphemeralIdentitiesDifferBetweenProcesses() async throws {
        guard let path = ToolLocator.find("tailcat") else { throw ManagerError.message("Native check requires installed Tailcat") }
        let runner = ProcessRunner()
        let command = Command(URL(fileURLWithPath: path), ["--key=new", "printpub"])
        let first = try await runner.run(command)
        let second = try await runner.run(command)
        try first.requireSuccess(); try second.requireSuccess()
        try expectTrue(first.output.hasPrefix("nodekey:"))
        try expectTrue(second.output.hasPrefix("nodekey:"))
        try expectFalse(first.output == second.output)
    }
}
