import Foundation
import Combine

public enum ReachabilityState: String {
    case queued, testing, reachable, unreachable, failed, cancelled
    public var label: String {
        switch self {
        case .queued: return "等待测试"
        case .testing: return "正在测试"
        case .reachable: return "可达"
        case .unreachable: return "未收到 pong"
        case .failed: return "测试失败"
        case .cancelled: return "已取消"
        }
    }
}

public struct ReachabilityResult: Identifiable {
    public let id: UUID
    public let name: String
    public let temporary: Bool
    public var state: ReachabilityState = .queued
    public var latency: String = "—"
    public var route: String = "—"
    public var detail = ""
    public var checkedAt: Date?
    public var adbState: ConnectionState = .disconnected
}

@MainActor public final class ReachabilityChecker: ObservableObject {
    @Published public private(set) var results: [ReachabilityResult] = []
    @Published public private(set) var isRunning = false
    @Published public private(set) var isCancelling = false
    private let runner: any CommandExecuting
    private var job: Task<Void, Never>?
    public init(runner: any CommandExecuting) { self.runner = runner }
    public var completedCount: Int { results.filter { $0.state != .queued && $0.state != .testing }.count }
    public var reachableCount: Int { results.filter { $0.state == .reachable }.count }
    public var adbOnlineCount: Int { results.filter { $0.adbState == .online }.count }

    public func start(profiles: [DeviceProfile], tailcatPath: String, temporaryIDs: Set<UUID> = [],
                      adbState: @escaping @MainActor (UUID) -> ConnectionState = { _ in .disconnected },
                      address: @escaping @MainActor (UUID) throws -> String?) {
        guard !isRunning else { return }
        results = profiles.map { ReachabilityResult(id: $0.id, name: $0.name, temporary: temporaryIDs.contains($0.id), adbState: adbState($0.id)) }
        guard !profiles.isEmpty else { return }
        isRunning = true; isCancelling = false
        job = Task { [weak self] in
            guard let self else { return }
            defer { self.isRunning = false; self.isCancelling = false; self.job = nil }
            await withTaskGroup(of: Void.self) { group in
                var next = 0
                func enqueue() {
                    let index = next; next += 1
                    group.addTask { @MainActor in
                        await self.check(index: index, profile: profiles[index], tailcatPath: tailcatPath, adbState: adbState, address: address)
                    }
                }
                for _ in 0..<min(3, profiles.count) { enqueue() }
                while await group.next() != nil {
                    if Task.isCancelled { group.cancelAll() }
                    else if next < profiles.count { enqueue() }
                }
            }
            for index in self.results.indices where self.results[index].state == .queued || self.results[index].state == .testing {
                self.results[index].state = .cancelled
            }
        }
    }

    public func cancel() { guard isRunning else { return }; isCancelling = true; job?.cancel() }
    public func shutdown() async { cancel(); await job?.value }

    private func check(index: Int, profile: DeviceProfile, tailcatPath: String,
                       adbState: @escaping @MainActor (UUID) -> ConnectionState,
                       address: @escaping @MainActor (UUID) throws -> String?) async {
        guard !Task.isCancelled else { return }
        results[index].state = .testing
        defer { results[index].checkedAt = Date(); results[index].adbState = adbState(profile.id) }
        do {
            let executable = try ToolLocator.executable(tailcatPath, name: "Tailcat")
            guard let credential = try address(profile.id), Credentials.isPlausible(credential) else {
                throw ManagerError.message("没有有效连接凭据，请编辑设备或导入地址簿")
            }
            try Task.checkCancellation()
            let result = try await runner.run(Command(executable, ["--key=new", "ping", "--timeout=5s", credential], timeout: 8), onOutput: { _ in })
            try Task.checkCancellation()
            if result.cancelled { throw CancellationError() }
            let output = Credentials.redact(result.output, address: credential)
            results[index].detail = String(output.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1000))
            if !result.timedOut, result.exitCode == 0,
               let pong = output.components(separatedBy: .newlines).last(where: { $0.hasPrefix("pong in ") }),
               let range = pong.range(of: " via "),
               String(pong[pong.index(pong.startIndex, offsetBy: 8)..<range.lowerBound]).range(of: "^[0-9]+(?:\\.[0-9]+)?ms$", options: .regularExpression) != nil {
                results[index].state = .reachable
                results[index].latency = String(pong[pong.index(pong.startIndex, offsetBy: 8)..<range.lowerBound])
                let path = String(pong[range.upperBound...])
                results[index].route = path.hasPrefix("DERP(") ? "中继 · \(path)" : "直连 · \(path)"
            } else {
                results[index].state = result.timedOut || result.exitCode != 0 ? .unreachable : .failed
                if output.isEmpty { results[index].detail = result.timedOut ? "测试超时" : "未收到有效 pong" }
            }
        } catch is CancellationError { results[index].state = .cancelled }
        catch {
            results[index].state = .failed
            results[index].detail = String(Credentials.redact(error.localizedDescription).prefix(1000))
        }
    }
}
