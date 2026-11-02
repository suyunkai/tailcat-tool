import Foundation
import Security

public protocol CredentialStore: AnyObject {
    func read(id: UUID) throws -> String?
    func readForObservation(id: UUID) throws -> String?
    func write(_ address: String, id: UUID) throws
    func delete(id: UUID) throws
}

public extension CredentialStore {
    func readForObservation(id: UUID) throws -> String? { try read(id: id) }
}

/// Reuse an authorized read for this process; never persist the cache.
public final class CachedCredentialStore: CredentialStore {
    private enum Entry { case value(String), missing }
    private var cache: [UUID: Entry] = [:]
    private let base: any CredentialStore
    private let lock = NSRecursiveLock()
    public init(_ base: any CredentialStore) { self.base = base }
    public func read(id: UUID) throws -> String? { try load(id, observing: false) }
    public func readForObservation(id: UUID) throws -> String? { try load(id, observing: true) }
    private func load(_ id: UUID, observing: Bool) throws -> String? {
        lock.lock(); defer { lock.unlock() }
        if let entry = cache[id] {
            if case let .value(value) = entry { return value }
            return nil
        }
        let value = try observing ? base.readForObservation(id: id) : base.read(id: id)
        cache[id] = value.map(Entry.value) ?? .missing
        return value
    }
    public func write(_ address: String, id: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        try base.write(address, id: id); cache[id] = .value(address)
    }
    public func delete(id: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        try base.delete(id: id); cache[id] = .missing
    }
}

public final class MemoryCredentialStore: CredentialStore {
    private var values: [UUID: String] = [:]
    public init() {}
    public func read(id: UUID) throws -> String? { values[id] }
    public func write(_ address: String, id: UUID) throws { values[id] = address }
    public func delete(id: UUID) throws { values.removeValue(forKey: id) }
}

public final class KeychainCredentialStore: CredentialStore {
    private let service = "cc.coauto.tailcat-manager.connections"
    public init() {}
    private func query(_ id: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: id.uuidString]
    }
    public func read(id: UUID) throws -> String? {
        var q = query(id)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        try check(status)
        guard let data = item as? Data, let value = String(data: data, encoding: .utf8) else {
            throw ManagerError.message("Keychain 中的连接凭据无法读取")
        }
        return value
    }
    public func readForObservation(id: UUID) throws -> String? {
        // These items live in the legacy login keychain. Data Protection-only
        // authentication query flags do not suppress its ACL dialogs.
        var allowed: DarwinBoolean = false
        try check(SecKeychainGetUserInteractionAllowed(&allowed))
        try check(SecKeychainSetUserInteractionAllowed(false))
        defer { SecKeychainSetUserInteractionAllowed(allowed.boolValue) }
        return try read(id: id)
    }
    public func write(_ address: String, id: UUID) throws {
        let q = query(id)
        let attributes = [kSecValueData as String: Data(address.utf8)]
        let status = SecItemUpdate(q as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = q
            item[kSecValueData as String] = Data(address.utf8)
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            try check(SecItemAdd(item as CFDictionary, nil))
        } else { try check(status) }
    }
    public func delete(id: UUID) throws {
        let status = SecItemDelete(query(id) as CFDictionary)
        if status != errSecItemNotFound { try check(status) }
    }
    private func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else {
            let detail = SecCopyErrorMessageString(status, nil) as String? ?? "错误码 \(status)"
            throw ManagerError.message("Keychain：\(detail)")
        }
    }
}

public struct ToolSettings: Codable, Equatable {
    public var tailcat: String
    public var adb: String
    public var scrcpy: String
    public var addressBookDirectory: String
    public init(tailcat: String = ToolLocator.find("tailcat") ?? "",
                adb: String = ToolLocator.find("adb") ?? "",
                scrcpy: String = ToolLocator.find("scrcpy") ?? "",
                addressBookDirectory: String = LegacyAddressBook.defaultRoot.path) {
        self.tailcat = tailcat; self.adb = adb; self.scrcpy = scrcpy
        self.addressBookDirectory = addressBookDirectory
    }
}

public enum ToolLocator {
    public static func find(_ name: String) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let paths = ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin",
                     "\(home)/Library/Android/sdk/platform-tools", "/usr/bin", "/bin"]
            + (ProcessInfo.processInfo.environment["PATH"] ?? "").components(separatedBy: ":")
        return paths.map { "\($0)/\(name)" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
    public static func executable(_ path: String, name: String) throws -> URL {
        guard path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: path) else {
            throw ManagerError.message("未找到 \(name)，请在设置中指定可执行文件的绝对路径")
        }
        return URL(fileURLWithPath: path)
    }
}

public struct AppConfiguration: Codable {
    public var profiles: [DeviceProfile]
    public var tools: ToolSettings
    public var relayPresets: [RelayPreset]
    public init(profiles: [DeviceProfile] = [], tools: ToolSettings = ToolSettings(), relayPresets: [RelayPreset] = []) {
        self.profiles = profiles; self.tools = tools; self.relayPresets = relayPresets
    }
    private enum CodingKeys: String, CodingKey { case profiles, tools, relayPresets }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        profiles = try values.decode([DeviceProfile].self, forKey: .profiles)
        tools = try values.decode(ToolSettings.self, forKey: .tools)
        relayPresets = try values.decodeIfPresent([RelayPreset].self, forKey: .relayPresets) ?? []
    }
}

public final class ConfigurationStore {
    public let directory: URL
    private var file: URL { directory.appendingPathComponent("configuration.json") }
    public init(directory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("TailcatManager")) {
        self.directory = directory
    }
    public func load() throws -> AppConfiguration {
        guard FileManager.default.fileExists(atPath: file.path) else { return AppConfiguration() }
        try rejectSymlink(directory); try rejectSymlink(file)
        return try JSONDecoder().decode(AppConfiguration.self, from: Data(contentsOf: file))
    }
    public func save(_ configuration: AppConfiguration) throws {
        try rejectSymlink(directory); try rejectSymlink(file)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(configuration).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}

private func rejectSymlink(_ url: URL) throws {
    if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path), attrs[.type] as? FileAttributeType == .typeSymbolicLink {
        throw ManagerError.message("为保护配置，拒绝读取或覆盖符号链接：\(url.lastPathComponent)")
    }
}

public struct LegacyEntry: Equatable {
    public let username: String
    public let address: String
    public init(username: String, address: String) { self.username = username; self.address = address }
}

public struct LegacyImport {
    public var entries: [LegacyEntry]
    public var skipped: Int
}

public enum LegacyAddressBook {
    public static var defaultRoot: URL {
        let env = ProcessInfo.processInfo.environment["XDG_STATE_HOME"]
        let root = env.flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : nil }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/state")
        return root.appendingPathComponent("tailcat-adb")
    }
    public static func read(root: URL) throws -> LegacyImport {
        try rejectSymlink(root)
        let users = root.appendingPathComponent("users")
        try rejectSymlink(users)
        guard FileManager.default.fileExists(atPath: users.path) else {
            throw ManagerError.message("未找到 tailcat-adb 地址簿：\(users.path)")
        }
        let files = try FileManager.default.contentsOfDirectory(at: users, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]).sorted { $0.lastPathComponent < $1.lastPathComponent }
        var entries: [LegacyEntry] = []; var skipped = 0
        for file in files {
            let name = file.lastPathComponent
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard name.range(of: "^[A-Za-z0-9][A-Za-z0-9_-]{0,31}$", options: .regularExpression) != nil,
                  values.isSymbolicLink != true, values.isRegularFile == true,
                  (values.fileSize ?? 8193) <= 8192,
                  let raw = try? String(contentsOf: file, encoding: .utf8) else { skipped += 1; continue }
            let address = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard Credentials.isPlausible(address) else { skipped += 1; continue }
            entries.append(LegacyEntry(username: name, address: address))
        }
        return LegacyImport(entries: entries, skipped: skipped)
    }
}
