import Foundation
import CoreFoundation
import Network

public struct RelayPreset: Identifiable, Codable, Equatable {
    public var id: UUID
    public var name: String
    public var source: String
    public init(id: UUID = UUID(), name: String, source: String) {
        self.id = id; self.name = name; self.source = source
    }
}

public enum TailcatRelay {
    public static let mapURL = "https://tailcat.dev/derpmap.json"
    public static var argument: String { "--derpmap-url=\(mapURL)" }

    /// Nil means the official map. Custom configuration is a URL or a normalized map.
    public static func normalize(_ input: String?) throws -> String? {
        guard var value = input?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        guard value.utf8.count <= 131_072 else { throw ManagerError.message("DERP 配置不能超过 128 KiB") }
        if let url = URL(string: value), ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
           let host = url.host, !host.isEmpty, url.user == nil, url.password == nil, url.fragment == nil {
            return value
        }
        if value.hasPrefix("\"derpMap\"") { value = "{" + value + "}" }
        let chars = Array(value)
        var clean = "", quoted = false, escaped = false
        for index in chars.indices {
            let char = chars[index]
            if quoted {
                clean.append(char)
                if escaped { escaped = false }
                else if char == "\\" { escaped = true }
                else if char == "\"" { quoted = false }
            } else {
                if char == "\"" { quoted = true }
                if char == "," {
                    var next = index + 1
                    while next < chars.count && chars[next].isWhitespace { next += 1 }
                    if next < chars.count && (chars[next] == "}" || chars[next] == "]") { continue }
                }
                clean.append(char)
            }
        }
        guard let data = clean.data(using: .utf8),
              let decoded = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw ManagerError.message("请填写 HTTP/HTTPS JSON 链接，或有效的 DERP JSON 内容")
        }
        let map = decoded["derpMap"] as? [String: Any] ?? decoded
        guard let regions = map["Regions"] as? [String: Any], !regions.isEmpty, regions.count <= 128 else {
            throw ManagerError.message("DERP JSON 需要包含 1–128 个 Regions 区域")
        }
        func integer(_ value: Any?) -> Int? {
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue == Double(number.intValue) else { return nil }
            return number.intValue
        }
        for (key, rawRegion) in regions {
            guard let id = Int(key), id > 0, let region = rawRegion as? [String: Any], integer(region["RegionID"]) == id,
                  let nodes = region["Nodes"] as? [[String: Any]], !nodes.isEmpty, nodes.count <= 32 else {
                throw ManagerError.message("DERP 区域 ID 需要与键一致，每个区域需要 1–32 个节点")
            }
            for node in nodes {
                guard let name = node["Name"] as? String, !name.isEmpty,
                      integer(node["RegionID"]) == id,
                      let host = node["HostName"] as? String, !host.isEmpty,
                      host.range(of: "^[A-Za-z0-9_.:-]+$", options: .regularExpression) != nil else {
                    throw ManagerError.message("DERP 节点需要有效的名称、HostName 和匹配的 RegionID")
                }
                for (field, allowed) in [("DERPPort", 0...65535), ("STUNPort", -1...65535)] where node[field] != nil {
                    guard let port = integer(node[field]), allowed.contains(port) else {
                        throw ManagerError.message("DERP 节点的 \(field) 端口无效")
                    }
                }
            }
        }
        let normalized = try JSONSerialization.data(withJSONObject: map, options: [.prettyPrinted, .sortedKeys])
        guard normalized.count <= 131_072 else { throw ManagerError.message("DERP 配置不能超过 128 KiB") }
        return String(decoding: normalized, as: UTF8.self)
    }

    public static func prepare(_ source: String?) async throws -> RelayMapLease {
        guard let normalized = try normalize(source) else { return RelayMapLease(url: mapURL) }
        if normalized.hasPrefix("{") {
            let server = try InlineRelayMapServer(data: Data(normalized.utf8))
            let url = try await server.start()
            return RelayMapLease(url: url, server: server)
        }
        return RelayMapLease(url: normalized)
    }
}

public final class RelayMapLease {
    public let url: String
    public var argument: String { "--derpmap-url=\(url)" }
    private let server: InlineRelayMapServer?
    fileprivate init(url: String, server: InlineRelayMapServer? = nil) { self.url = url; self.server = server }
    public func stop() { server?.stop() }
    deinit { stop() }
}

/// Inline JSON is exposed only on IPv4 loopback while its owned Tailcat process runs.
private final class RelayServerStartup: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<String, Error>?
    init(_ continuation: CheckedContinuation<String, Error>) { self.continuation = continuation }
    @discardableResult func finish(_ result: Result<String, Error>) -> Bool {
        lock.lock(); let pending = continuation; continuation = nil; lock.unlock()
        pending?.resume(with: result)
        return pending != nil
    }
}

// Configuration is immutable; listener callbacks run on queue, and cancel is thread-safe.
private final class InlineRelayMapServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "cc.coauto.tailcat-manager.inline-derp")
    private let path = "/\(UUID().uuidString.lowercased()).json"
    private let data: Data
    init(data: Data) throws {
        self.data = data
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }
    func start() async throws -> String {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                let startup = RelayServerStartup(continuation)
                listener.stateUpdateHandler = { [self] state in
                    switch state {
                    case .ready:
                        guard let port = listener.port else { startup.finish(.failure(ManagerError.message("无法取得本地 DERP 配置端口"))); stop(); return }
                        startup.finish(.success("http://127.0.0.1:\(port.rawValue)\(path)"))
                    case .failed:
                        startup.finish(.failure(ManagerError.message("无法启动本地 DERP 配置服务"))); stop()
                    case .cancelled:
                        startup.finish(.failure(CancellationError()))
                        listener.newConnectionHandler = nil; listener.stateUpdateHandler = nil
                    default: break
                    }
                }
                listener.newConnectionHandler = { [self] connection in
                    connection.start(queue: queue)
                    queue.asyncAfter(deadline: .now() + 4) { connection.cancel() }
                    receive(connection, buffered: Data())
                }
                listener.start(queue: queue)
                queue.asyncAfter(deadline: .now() + 3) { [self] in
                    if startup.finish(.failure(ManagerError.message("启动本地 DERP 配置服务超时"))) { stop() }
                }
            }
        }, onCancel: { self.stop() })
    }
    func stop() { listener.cancel() }
    private func receive(_ connection: NWConnection, buffered: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [self] chunk, _, ended, error in
            var request = buffered
            if let chunk { request.append(chunk) }
            guard request.count <= 8192, error == nil else { connection.cancel(); return }
            guard let text = String(data: request, encoding: .utf8), text.contains("\r\n\r\n") else {
                if ended { connection.cancel() } else { receive(connection, buffered: request) }
                return
            }
            let first = text.components(separatedBy: "\r\n").first?.split(separator: " ") ?? []
            let valid = first.count == 3 && first[1] == path && ["GET", "HEAD"].contains(String(first[0]))
            let body = valid ? data : Data()
            let header = "HTTP/1.1 \(valid ? "200 OK" : "404 Not Found")\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
            var response = Data(header.utf8)
            if first.first != "HEAD" { response.append(body) }
            connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}
