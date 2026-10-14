import Foundation

public struct DeviceProfile: Identifiable, Codable, Equatable {
    public var id: UUID
    public var name: String
    public var legacyUsername: String?
    public var preferredPort: Int?
    public var remotePort: Int

    public init(id: UUID = UUID(), name: String, legacyUsername: String? = nil,
                preferredPort: Int? = nil, remotePort: Int = 5555) {
        self.id = id
        self.name = name
        self.legacyUsername = legacyUsername
        self.preferredPort = preferredPort
        self.remotePort = remotePort
    }
}

public enum ConnectionState: String {
    case disconnected, connecting, online, offline, unauthorized, disconnecting, failed
    public var label: String {
        switch self {
        case .disconnected: return "未连接"
        case .connecting: return "正在连接"
        case .online: return "ADB 已连接"
        case .offline: return "ADB 离线"
        case .unauthorized: return "ADB 待授权"
        case .disconnecting: return "正在断开"
        case .failed: return "连接失败"
        }
    }
    public var isBusy: Bool { self == .connecting || self == .disconnecting }
}

public struct SessionLog: Identifiable {
    public let id = UUID()
    public let date = Date()
    public var text: String
    public init(_ text: String) { self.text = text }
}

public struct DeviceSession {
    public var isExternalCLI = false
    public var state: ConnectionState = .disconnected
    public var serial: String?
    public var pid: Int32?
    public var model = "—"
    public var product = "—"
    public var android = "—"
    public var deviceSerial = "—"
    public var identity = "—"
    public var route = "未探测"
    public var error: String?
    public var logs: [SessionLog] = []
    public init() {}
}

public struct ExternalCLISession: Identifiable, Equatable {
    public var id: String { "\(pid):\(port)" }
    public let pid: Int32
    public let port: Int
    public let remotePort: Int
    public let state: ConnectionState
    public let model: String
    public let product: String
    public var serial: String { "127.0.0.1:\(port)" }
    public init(pid: Int32, port: Int, remotePort: Int = 5555, state: ConnectionState, model: String = "—", product: String = "—") {
        self.pid = pid; self.port = port; self.remotePort = remotePort; self.state = state; self.model = model; self.product = product
    }
    public var deviceSession: DeviceSession {
        var session = DeviceSession()
        session.isExternalCLI = true; session.pid = pid; session.serial = serial
        session.state = state; session.model = model; session.product = product
        session.route = "由 tailcat-adb 管理"
        return session
    }
}

public enum TaskState: String {
    case running, succeeded, failed, cancelled
    public var label: String {
        switch self {
        case .running: return "执行中"
        case .succeeded: return "已完成"
        case .failed: return "失败"
        case .cancelled: return "已取消"
        }
    }
}

public struct DeviceTask: Identifiable {
    public let id: UUID
    public let deviceID: UUID
    public let deviceName: String
    public let serial: String
    public let title: String
    public let date = Date()
    public var state: TaskState = .running
    public var output = ""
    public var installProgress: APKInstallProgress?
}

public enum ManagerError: LocalizedError {
    case message(String)
    public var errorDescription: String? {
        if case let .message(message) = self { return message }
        return nil
    }
}

public enum Credentials {
    public static func isPlausible(_ address: String) -> Bool {
        address.count <= 8192 && address.range(of: "^tc[A-Za-z0-9_-]{20,}$", options: .regularExpression) != nil
    }
    public static func redact(_ text: String, address: String? = nil) -> String {
        var result = text
        if let address, !address.isEmpty { result = result.replacingOccurrences(of: address, with: "[连接凭据已隐藏]") }
        return result.replacingOccurrences(of: "tc[A-Za-z0-9_-]{20,}", with: "[连接凭据已隐藏]", options: .regularExpression)
    }
}

/// Buffer incomplete lines so credentials split across pipe reads never reach the UI.
public final class OutputRedactor {
    private var pending = ""
    private var discarding = false
    private let address: String?
    public init(address: String? = nil) { self.address = address }
    public func append(_ chunk: String) -> String {
        pending += chunk
        var output = ""
        while let range = pending.rangeOfCharacter(from: .newlines) {
            let line = String(pending[..<range.lowerBound])
            pending = String(pending[range.upperBound...])
            if !discarding { output += Credentials.redact(line, address: address) + "\n" }
            discarding = false
        }
        if pending.count > 32768 {
            pending = ""; discarding = true
            output += "[输出行过长，已截断]\n"
        }
        return output
    }
    public func flush() -> String {
        defer { pending = ""; discarding = false }
        return discarding ? "" : Credentials.redact(pending, address: address)
    }
}
