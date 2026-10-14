import Foundation
import TailcatCore

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

    func testTerminalOutputArrivesBeforeExitAndCancellationClosesTerminal() async throws {
        let runner = ProcessRunner()
        var liveOutput = ""
        let command = Command(URL(fileURLWithPath: "/bin/sh"),
                              ["-c", "test -t 1 && test -t 2 || exit 7; printf 'READY\\n'; sleep 0.3; printf '\\r[ 42%%] progress\\r\\nFINAL\\n'"],
                              timeout: 5, terminalOutput: true)
        let job = Task { try await runner.run(command) { liveOutput += $0 } }
        for _ in 0..<20 {
            if liveOutput.contains("READY") { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        try expectTrue(liveOutput.contains("READY"))
        try expectFalse(liveOutput.contains("FINAL"))
        let result = try await job.value
        try expectEqual(result.exitCode, 0)
        try expectTrue(result.output.contains("[ 42%]"))
        try expectTrue(result.output.contains("FINAL"))
        let timedOut = try await runner.run(Command(URL(fileURLWithPath: "/bin/sleep"), ["30"], timeout: 0.1, terminalOutput: true))
        try expectTrue(timedOut.timedOut)
        let cancellable = Task { try await runner.run(Command(URL(fileURLWithPath: "/bin/sleep"), ["30"], terminalOutput: true)) }
        try await Task.sleep(nanoseconds: 30_000_000)
        cancellable.cancel()
        let cancelled = try await cancellable.value
        try expectTrue(cancelled.cancelled)
    }

    func testNativeTailcatListeners() async throws {
        guard let path = ToolLocator.find("tailcat") else { throw ManagerError.message("Native check requires installed Tailcat") }
        let runner = ProcessRunner()
        let transport = TailcatTransport(executable: URL(fileURLWithPath: path), runner: runner)
        // Public documentation example: only bind local listeners, never dial a remote port.
        let address = "tcomFwWCCcjS5nKNqAod034nWoJZW0LZqDhhC8U_dKdnDRYQ8uNGFpGQEu"
        let first = try await transport.open(address: address, preferredPort: nil, remotePort: 5555, onLog: { _ in }, onExit: { _ in })
        do {
            let second = try await transport.open(address: address, preferredPort: nil, remotePort: 5555, onLog: { _ in }, onExit: { _ in })
            do {
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
}
