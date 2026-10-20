import Foundation
import Darwin

public struct ClientIdentity: Equatable {
    public let file: URL
    public let publicKey: String
    public init(file: URL, publicKey: String) { self.file = file; self.publicKey = publicKey }
    public var argument: String { "--key=\(file.path)" }
}

public enum ClientIdentityRole: String, CaseIterable { case connection, probe }

@MainActor public protocol ClientIdentityProviding: AnyObject {
    func identity(deviceID: UUID, role: ClientIdentityRole, executable: URL,
                  runner: any CommandExecuting) async throws -> ClientIdentity
}

/// Private key material is handled exclusively by the native Tailcat executable.
/// This store retains paths and public keys, never private key contents.
@MainActor public final class ClientIdentityStore: ClientIdentityProviding {
    public let directory: URL
    private var pending: [String: Task<ClientIdentity, Error>] = [:]

    public init(directory: URL = ConfigurationStore().directory.appendingPathComponent("Identities")) {
        self.directory = directory
    }

    public func identity(deviceID: UUID, role: ClientIdentityRole, executable: URL,
                         runner: any CommandExecuting) async throws -> ClientIdentity {
        try await identity(named: "\(deviceID.uuidString.lowercased())-\(role.rawValue)", executable: executable, runner: runner)
    }

    public func identity(named name: String, executable: URL, runner: any CommandExecuting) async throws -> ClientIdentity {
        guard name.range(of: "^[A-Za-z0-9][A-Za-z0-9_-]{0,95}$", options: .regularExpression) != nil else {
            throw ManagerError.message("客户端身份名称无效")
        }
        if let task = pending[name] { return try await task.value }
        let task = Task { try await self.prepare(name: name, executable: executable, runner: runner) }
        pending[name] = task
        defer { pending.removeValue(forKey: name) }
        return try await task.value
    }

    public func existing(file: URL, executable: URL, runner: any CommandExecuting) async throws -> ClientIdentity {
        try validateFile(file)
        let result = try await runner.run(Command(executable, ["--key=\(file.path)", "printpub"], timeout: 5), onOutput: { _ in })
        try result.requireSuccess()
        let key = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard key.range(of: "^nodekey:[0-9a-fA-F]{64}$", options: .regularExpression) != nil else {
            throw ManagerError.message("已有客户端身份无法读取，请检查身份文件；不会自动更换身份")
        }
        return ClientIdentity(file: file, publicKey: key.lowercased())
    }

    private func prepare(name: String, executable: URL, runner: any CommandExecuting) async throws -> ClientIdentity {
        let fm = FileManager.default
        try rejectLink(directory.deletingLastPathComponent())
        try rejectLink(directory)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let lockFile = directory.appendingPathComponent("\(name).lock")
        let fd = Darwin.open(lockFile.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw ManagerError.message("无法锁定客户端身份文件") }
        defer { Darwin.close(fd) }
        var locked = false
        for _ in 0..<100 {
            if flock(fd, LOCK_EX | LOCK_NB) == 0 { locked = true; break }
            guard errno == EWOULDBLOCK else { throw ManagerError.message("无法锁定客户端身份文件") }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        guard locked else { throw ManagerError.message("客户端身份正在由另一进程初始化，请稍后重试") }
        defer { flock(fd, LOCK_UN) }
        let file = directory.appendingPathComponent("\(name).private.json")
        try rejectLink(file)
        if !fm.fileExists(atPath: file.path) {
            // No --force: a saved identity must never be silently replaced.
            let result = try await runner.run(Command(executable, ["genkey", "--client", "--key=\(file.path)"], timeout: 5), onOutput: { _ in })
            try result.requireSuccess()
        }
        try validateFile(file)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return try await existing(file: file, executable: executable, runner: runner)
    }

    private func validateFile(_ file: URL) throws {
        try rejectLink(file)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              attributes[.ownerAccountID] as? UInt32 == getuid() else {
            throw ManagerError.message("客户端身份必须是当前用户拥有的普通文件")
        }
    }

    private func rejectLink(_ file: URL) throws {
        if let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
           attributes[.type] as? FileAttributeType == .typeSymbolicLink {
            throw ManagerError.message("客户端身份不能使用符号链接：\(file.lastPathComponent)")
        }
    }
}

/// Batch and single-device probes share this lane. They never run two native
/// processes with the same saved probe identity at the same time.
@MainActor public final class ClientPinger {
    private let identities: any ClientIdentityProviding
    private var active: Set<UUID> = []
    public init(identities: (any ClientIdentityProviding)? = nil) { self.identities = identities ?? ClientIdentityStore() }

    public func ping(deviceID: UUID, executable: URL, runner: any CommandExecuting,
                     address: String, seconds: Int) async throws -> CommandResult {
        while active.contains(deviceID) { try await Task.sleep(nanoseconds: 50_000_000) }
        try Task.checkCancellation()
        active.insert(deviceID)
        defer { active.remove(deviceID) }
        let identity = try await identities.identity(deviceID: deviceID, role: .probe, executable: executable, runner: runner)
        try Task.checkCancellation()
        return try await runner.run(Command(executable, [identity.argument, "ping", "--timeout=\(seconds)s", address],
                                            timeout: TimeInterval(seconds + 3)), onOutput: { _ in })
    }
}
