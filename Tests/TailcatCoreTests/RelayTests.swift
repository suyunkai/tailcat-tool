import Foundation
import TailcatCore

@MainActor private final class RelayTestProcess: RunningProcess {
    let pid: Int32 = 1
    var isRunning = true
    func stop() async { isRunning = false }
}

@MainActor private final class InlineRetryRunner: CommandExecuting {
    var starts: [Command] = []
    func start(_ command: Command, onOutput: @escaping (String) -> Void,
               onExit: @escaping (Int32) -> Void) throws -> any RunningProcess {
        starts.append(command)
        let handle = RelayTestProcess()
        if starts.count == 1 {
            handle.isRunning = false; onOutput("address already in use\n"); onExit(1)
        } else {
            let port = command.arguments.last!.split(separator: ":")[0]
            onOutput("# forwarding 127.0.0.1:\(port) -> remote localhost:5555\n")
        }
        return handle
    }
    func run(_ command: Command, onOutput: @escaping (String) -> Void) async throws -> CommandResult { CommandResult() }
}

@MainActor private final class RelayTestTransport: ForwardTransport {
    private var next = 6600
    func open(address: String, preferredPort: Int?, remotePort: Int, identity: ClientIdentity,
              onLog: @escaping (String) -> Void, onExit: @escaping (Int32) -> Void) async throws -> ForwardConnection {
        next += 1
        return ForwardConnection(handle: RelayTestProcess(), port: preferredPort ?? next)
    }
}

@MainActor private final class RelayTestRunner: CommandExecuting {
    func start(_ command: Command, onOutput: @escaping (String) -> Void,
               onExit: @escaping (Int32) -> Void) throws -> any RunningProcess { RelayTestProcess() }
    func run(_ command: Command, onOutput: @escaping (String) -> Void) async throws -> CommandResult {
        if command.arguments.contains("get-state") { return CommandResult(output: "device\n") }
        return CommandResult()
    }
}

@MainActor final class RelayTests {
    static let map = """
    {"Regions":{"302":{"RegionID":302,"RegionCode":"test","RegionName":"Test",
    "Nodes":[{"Name":"test","RegionID":302,"HostName":"relay.example","DERPPort":443,"STUNPort":3478}]}}}
    """
    func testInputNormalizationAndLegacyDefaults() throws {
        try expectNil(try TailcatRelay.normalize(nil))
        try expectNil(try TailcatRelay.normalize(" \n"))
        try expectEqual(try TailcatRelay.normalize(" https://relay.example/map.json \n"), "https://relay.example/map.json")
        let canonical = try TailcatRelay.normalize(Self.map)
        let fragment = "\"derpMap\": " + Self.map.replacingOccurrences(of: "}]", with: "},]") + ","
        try expectEqual(try TailcatRelay.normalize(fragment), canonical)
        try expectThrows(try TailcatRelay.normalize("ftp://relay.example/map.json"))
        try expectThrows(try TailcatRelay.normalize("{\"Regions\":{}}"))
        try expectThrows(try TailcatRelay.normalize(Self.map.replacingOccurrences(of: "\"DERPPort\":443", with: "\"DERPPort\":70000")))
        try expectThrows(try TailcatRelay.normalize(Self.map.replacingOccurrences(of: "\"RegionID\":302", with: "\"RegionID\":true")))
        let old = AppConfiguration(profiles: [DeviceProfile(name: "Old")])
        var fields = try JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as! [String: Any]
        fields.removeValue(forKey: "relayPresets")
        let decoded = try JSONDecoder().decode(AppConfiguration.self, from: JSONSerialization.data(withJSONObject: fields))
        try expectTrue(decoded.relayPresets.isEmpty)
        try expectNil(decoded.profiles.first?.relaySource)
    }

    func testPresetsAndDeviceIsolation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ConfigurationStore(directory: root), transport = RelayTestTransport()
        var sources: [String?] = []
        let settings = ToolSettings(tailcat: "/usr/bin/true", adb: "/usr/bin/true", scrcpy: "/usr/bin/true")
        let manager = SessionManager(configuration: AppConfiguration(tools: settings), configurationStore: store,
            credentials: MemoryCredentialStore(), runner: RelayTestRunner(), identities: TestingIdentities(),
            monitorInterval: 60_000_000_000, makeTransport: { _, _, source in sources.append(source); return transport })
        let firstURL = "https://first.example/map.json", secondURL = "https://second.example/map.json"
        let preset = try manager.saveRelayPreset(name: "Custom", source: firstURL)
        let address = "tc" + String(repeating: "T", count: 30)
        let custom = try manager.saveDevice(name: "Custom device", address: address, preferredPort: nil, remotePort: 5555, relaySource: firstURL)
        let standard = try manager.saveDevice(name: "Default device", address: address, preferredPort: nil, remotePort: 5555)
        _ = try manager.saveRelayPreset(id: preset, name: "Custom", source: secondURL)
        let a = manager.connect(custom), b = manager.connect(standard)
        await a?.value; await b?.value
        try expectEqual(Set(sources.compactMap { $0 }), Set([firstURL]))
        try expectEqual(sources.filter { $0 == nil }.count, 1)
        await manager.disconnectAll()
        let temporary = try manager.saveTemporaryDevice(address: address, relaySource: Self.map)
        try expectEqual(try store.load().profiles.count, 2)
        try manager.promoteTemporaryDevice(temporary, name: "Promoted JSON")
        try manager.updateTools(settings)
        let loaded = try store.load()
        try expectEqual(loaded.relayPresets.first?.source, secondURL)
        try expectEqual(loaded.profiles.first { $0.id == custom }?.relaySource, firstURL)
        try expectNil(loaded.profiles.first { $0.id == standard }?.relaySource)
        try expectEqual(loaded.profiles.first { $0.id == temporary }?.relaySource, try TailcatRelay.normalize(Self.map))
        let before = try Data(contentsOf: root.appendingPathComponent("configuration.json"))
        try expectThrows(try manager.saveRelayPreset(name: "Invalid", source: "invalid"))
        try expectEqual(try Data(contentsOf: root.appendingPathComponent("configuration.json")), before)
        await manager.shutdown()
    }

    func testInlineMapLifecycle() async throws {
        let standard = try await TailcatRelay.prepare(nil)
        try expectEqual(standard.url, "https://tailcat.dev/derpmap.json")
        let external = try await TailcatRelay.prepare("https://relay.example/map.json")
        try expectEqual(external.url, "https://relay.example/map.json")
        let lease = try await TailcatRelay.prepare(Self.map)
        defer { lease.stop() }
        let url = URL(string: lease.url)!
        try expectEqual(url.host, "127.0.0.1")
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(from: url)
        try expectEqual((response as? HTTPURLResponse)?.statusCode, 200)
        try expectEqual(String(decoding: data, as: UTF8.self), try TailcatRelay.normalize(Self.map))
        var head = URLRequest(url: url); head.httpMethod = "HEAD"
        let (empty, headResponse) = try await session.data(for: head)
        try expectTrue(empty.isEmpty)
        try expectEqual((headResponse as? HTTPURLResponse)?.statusCode, 200)
        let (_, missing) = try await session.data(from: url.deletingLastPathComponent().appendingPathComponent("wrong.json"))
        try expectEqual((missing as? HTTPURLResponse)?.statusCode, 404)
        lease.stop()
        try await Task.sleep(nanoseconds: 50_000_000)
        var request = URLRequest(url: url); request.timeoutInterval = 1
        do { _ = try await session.data(for: request); throw ManagerError.message("Stopped map server accepted a request") }
        catch { try expectFalse(error.localizedDescription == "Stopped map server accepted a request") }
    }

    func testNativeInlineMapResolve() async throws {
        guard let path = ToolLocator.find("tailcat") else { throw ManagerError.message("Native check requires installed Tailcat") }
        let lease = try await TailcatRelay.prepare(Self.map)
        defer { lease.stop() }
        // Official public documentation sample, resolved locally without dialing its server.
        let address = "tcomFwWCCcjS5nKNqAod034nWoJZW0LZqDhhC8U_dKdnDRYQ8uNGFpGQEu"
        let result = try await ProcessRunner().run(Command(URL(fileURLWithPath: path), [lease.argument, "resolve", address], timeout: 5))
        try result.requireSuccess()
        try expectTrue(Credentials.isPlausible(result.output.trimmingCharacters(in: .whitespacesAndNewlines)))
    }

    func testInlineMapSurvivesAutomaticPortRetry() async throws {
        let runner = InlineRetryRunner()
        let identity = ClientIdentity(file: URL(fileURLWithPath: "/test-identities/retry.private.json"), publicKey: "test")
        let transport = TailcatTransport(executable: URL(fileURLWithPath: "/usr/bin/true"), runner: runner, relaySource: Self.map)
        let connection = try await transport.open(address: "test", preferredPort: nil, remotePort: 5555,
            identity: identity, onLog: { _ in }, onExit: { _ in })
        do {
            try expectEqual(runner.starts.count, 2)
            let url = URL(string: runner.starts.last!.arguments[1].replacingOccurrences(of: "--derpmap-url=", with: ""))!
            let (data, response) = try await URLSession.shared.data(from: url)
            try expectEqual((response as? HTTPURLResponse)?.statusCode, 200)
            try expectEqual(String(decoding: data, as: UTF8.self), try TailcatRelay.normalize(Self.map))
        } catch { await connection.handle.stop(); throw error }
        await connection.handle.stop()
    }
}
