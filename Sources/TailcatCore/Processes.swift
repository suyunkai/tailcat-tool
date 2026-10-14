import Foundation
import Darwin

public struct Command {
    public let executable: URL
    public let arguments: [String]
    public let timeout: TimeInterval
    public let environment: [String: String]
    public let terminalOutput: Bool
    public init(_ executable: URL, _ arguments: [String], timeout: TimeInterval = 20, environment: [String: String] = [:], terminalOutput: Bool = false) {
        self.executable = executable; self.arguments = arguments; self.timeout = timeout; self.environment = environment
        self.terminalOutput = terminalOutput
    }
}

public struct CommandResult {
    public var exitCode: Int32
    public var output: String
    public var timedOut: Bool
    public var cancelled: Bool
    public init(exitCode: Int32 = 0, output: String = "", timedOut: Bool = false, cancelled: Bool = false) {
        self.exitCode = exitCode; self.output = output; self.timedOut = timedOut; self.cancelled = cancelled
    }
    public func requireSuccess() throws {
        if cancelled { throw CancellationError() }
        if timedOut { throw ManagerError.message("命令超时，已停止本次操作") }
        guard exitCode == 0 else {
            throw ManagerError.message(output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "命令退出码 \(exitCode)" : output)
        }
    }
}

@MainActor public protocol RunningProcess: AnyObject {
    var pid: Int32 { get }
    var isRunning: Bool { get }
    func stop() async
}

@MainActor public protocol CommandExecuting: AnyObject {
    func start(_ command: Command, onOutput: @escaping (String) -> Void,
               onExit: @escaping (Int32) -> Void) throws -> any RunningProcess
    func run(_ command: Command, onOutput: @escaping (String) -> Void) async throws -> CommandResult
}

@MainActor private final class LiveProcess: RunningProcess {
    let process = Process()
    var pid: Int32 { process.processIdentifier }
    var isRunning: Bool { process.isRunning }
    init(_ command: Command, onOutput: @escaping (String) -> Void, onExit: @escaping (Int32) -> Void) throws {
        process.executableURL = command.executable
        process.arguments = command.arguments
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = ["/opt/homebrew/bin", "/usr/local/bin", env["PATH"] ?? "/usr/bin:/bin"].joined(separator: ":")
        env.merge(command.environment) { _, new in new }
        process.environment = env
        process.standardInput = FileHandle.nullDevice
        let group = DispatchGroup()
        var readers: [FileHandle] = []
        var terminalSlave: FileHandle?
        if command.terminalOutput {
            // ADB hides live transfer progress unless stderr is a smart terminal.
            // Share the terminal for stdout/stderr so phase markers are line-buffered too.
            var master: Int32 = -1, slave: Int32 = -1
            var size = winsize(ws_row: 24, ws_col: 160, ws_xpixel: 0, ws_ypixel: 0)
            guard openpty(&master, &slave, nil, nil, &size) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            _ = fcntl(master, F_SETFD, FD_CLOEXEC); _ = fcntl(slave, F_SETFD, FD_CLOEXEC)
            let reader = FileHandle(fileDescriptor: master, closeOnDealloc: true)
            let writer = FileHandle(fileDescriptor: slave, closeOnDealloc: true)
            readers = [reader]; terminalSlave = writer
            process.standardOutput = writer; process.standardError = writer
        } else {
            let out = Pipe(), err = Pipe()
            process.standardOutput = out; process.standardError = err
            readers = [out.fileHandleForReading, err.fileHandleForReading]
        }
        for _ in readers { group.enter() }
        process.terminationHandler = { process in
            let status = process.terminationStatus
            group.notify(queue: .main) { onExit(status) }
        }
        try process.run()
        try? terminalSlave?.close()
        // Drain outputs concurrently, including trailing output before delivering exit.
        for handle in readers {
            DispatchQueue.global(qos: .utility).async {
                var bytes = Data()
                var buffer = [UInt8](repeating: 0, count: 8192)
                while true {
                    // Foundation's read(upToCount:) can wait to fill its buffer, hiding live
                    // progress. One POSIX read returns as soon as any bytes are available.
                    let count = buffer.withUnsafeMutableBytes { Darwin.read(handle.fileDescriptor, $0.baseAddress, $0.count) }
                    if count < 0 && errno == EINTR { continue }
                    if count <= 0 { break } // A closed terminal can report EIO instead of EOF.
                    let data = Data(buffer.prefix(count))
                    bytes.append(data)
                    // UTF-8 code points may span reads. Preserve incomplete suffixes.
                    if let value = String(data: bytes, encoding: .utf8) {
                        bytes.removeAll(keepingCapacity: true)
                        DispatchQueue.main.async { onOutput(value) }
                    } else if bytes.count > 65536 {
                        let value = String(decoding: bytes, as: UTF8.self)
                        bytes.removeAll(keepingCapacity: true)
                        DispatchQueue.main.async { onOutput(value) }
                    }
                }
                if !bytes.isEmpty {
                    let value = String(decoding: bytes, as: UTF8.self)
                    DispatchQueue.main.async { onOutput(value) }
                }
                try? handle.close()
                group.leave()
            }
        }
    }
    func stop() async {
        guard isRunning else { return }
        process.terminate()
        for _ in 0..<20 {
            if !isRunning { return }
            await pause(0.1)
        }
        if isRunning { Darwin.kill(pid, SIGKILL) }
        for _ in 0..<10 {
            if !isRunning { return }
            await pause(0.05)
        }
    }
    private func pause(_ seconds: Double) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { continuation.resume() }
        }
    }
}

@MainActor public final class ProcessRunner: CommandExecuting {
    private final class Job {
        var handle: (any RunningProcess)?
        var continuation: CheckedContinuation<CommandResult, Error>?
        var output = ""
        var timedOut = false
        var cancelled = false
        var timer: Task<Void, Never>?
    }
    private var jobs: [UUID: Job] = [:]
    public init() {}
    public func start(_ command: Command, onOutput: @escaping (String) -> Void,
                      onExit: @escaping (Int32) -> Void) throws -> any RunningProcess {
        try LiveProcess(command, onOutput: onOutput, onExit: onExit)
    }
    public func run(_ command: Command, onOutput: @escaping (String) -> Void = { _ in }) async throws -> CommandResult {
        try Task.checkCancellation()
        let id = UUID()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                let job = Job(); job.continuation = continuation; jobs[id] = job
                do {
                    job.handle = try start(command, onOutput: { chunk in
                        job.output = String((job.output + chunk).suffix(1_048_576))
                        onOutput(chunk)
                    }, onExit: { [weak self] code in
                        guard let self, self.jobs.removeValue(forKey: id) != nil else { return }
                        job.timer?.cancel()
                        job.continuation?.resume(returning: CommandResult(exitCode: code, output: job.output,
                                                                          timedOut: job.timedOut, cancelled: job.cancelled))
                        job.continuation = nil
                        job.handle = nil
                        job.timer = nil
                    })
                    job.timer = Task { [weak self] in
                        do { try await Task.sleep(nanoseconds: UInt64(max(0.1, command.timeout) * 1_000_000_000)) }
                        catch { return }
                        guard let self, let current = self.jobs[id] else { return }
                        current.timedOut = true
                        await current.handle?.stop()
                    }
                } catch {
                    jobs.removeValue(forKey: id)
                    continuation.resume(throwing: error)
                }
            }
        }, onCancel: {
            Task { @MainActor [weak self] in
                guard let job = self?.jobs[id] else { return }
                job.cancelled = true
                await job.handle?.stop()
            }
        })
    }
}

public enum ForwardOutput {
    public static func listeningPort(in output: String, remotePort: Int) -> Int? {
        let pattern = "# forwarding 127\\.0\\.0\\.1:([0-9]+) -> remote localhost:\(remotePort)(?:\\s|$)"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: output, range: NSRange(output.startIndex..., in: output)),
              let range = Range(match.range(at: 1), in: output), let port = Int(output[range]), (1...65535).contains(port) else { return nil }
        return port
    }
}

@MainActor public struct ForwardConnection {
    public let handle: any RunningProcess
    public let port: Int
    public var serial: String { "127.0.0.1:\(port)" }
    public init(handle: any RunningProcess, port: Int) { self.handle = handle; self.port = port }
}

@MainActor public protocol ForwardTransport: AnyObject {
    func open(address: String, preferredPort: Int?, remotePort: Int,
              onLog: @escaping (String) -> Void, onExit: @escaping (Int32) -> Void) async throws -> ForwardConnection
}

@MainActor public final class TailcatTransport: ForwardTransport {
    private final class Startup { var output = ""; var exitCode: Int32? }
    fileprivate static var reservedPorts: Set<Int> = []
    private let executable: URL
    private let runner: any CommandExecuting
    public init(executable: URL, runner: any CommandExecuting) { self.executable = executable; self.runner = runner }
    public func open(address: String, preferredPort: Int?, remotePort: Int,
                     onLog: @escaping (String) -> Void, onExit: @escaping (Int32) -> Void) async throws -> ForwardConnection {
        let candidates = preferredPort.map { [$0] } ?? Array(5556...5655)
        for candidate in candidates {
            try Task.checkCancellation()
            if Self.reservedPorts.contains(candidate) {
                if preferredPort != nil { throw ManagerError.message("本地端口 \(candidate) 已由另一会话使用或正在释放") }
                continue
            }
            Self.reservedPorts.insert(candidate)
            let startup = Startup()
            let redactor = OutputRedactor(address: address)
            let command = Command(executable, ["forward", "--bind=127.0.0.1", address, "\(candidate):\(remotePort)"])
            let handle: any RunningProcess
            do {
                let process = try runner.start(command, onOutput: { chunk in
                    startup.output = String((startup.output + chunk).suffix(16384))
                    let safe = redactor.append(chunk)
                    if !safe.isEmpty { onLog(safe) }
                }, onExit: { code in
                    let tail = redactor.flush()
                    if !tail.isEmpty { onLog(tail) }
                    startup.exitCode = code; onExit(code)
                })
                handle = ReservedForwardProcess(process, port: candidate)
            } catch { Self.reservedPorts.remove(candidate); throw error }
            do {
                for _ in 0..<50 {
                    try Task.checkCancellation()
                    if let port = ForwardOutput.listeningPort(in: startup.output, remotePort: remotePort), handle.isRunning {
                        return ForwardConnection(handle: handle, port: port)
                    }
                    if startup.exitCode != nil { break }
                    try await Task.sleep(nanoseconds: 100_000_000)
                }
                await handle.stop()
                if preferredPort == nil && startup.output.localizedCaseInsensitiveContains("address already in use") { continue }
                let detail = Credentials.redact(startup.output, address: address).trimmingCharacters(in: .whitespacesAndNewlines)
                throw ManagerError.message(detail.isEmpty ? "转发未在 5 秒内报告端口就绪；请确认 Tailcat 支持 forward 命令" : detail)
            } catch {
                await handle.stop()
                throw error
            }
        }
        throw ManagerError.message("5556–5655 均被占用，请为设备指定其他本地端口")
    }
}

@MainActor private final class ReservedForwardProcess: RunningProcess {
    private let process: any RunningProcess
    private let port: Int
    init(_ process: any RunningProcess, port: Int) { self.process = process; self.port = port }
    var pid: Int32 { process.pid }
    var isRunning: Bool { process.isRunning }
    func stop() async {
        await process.stop()
        if !process.isRunning { TailcatTransport.reservedPorts.remove(port) }
    }
}
