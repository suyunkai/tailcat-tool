import Foundation
import Combine

@MainActor public final class SessionManager: ObservableObject {
    @Published public private(set) var profiles: [DeviceProfile]
    @Published public private(set) var temporaryProfiles: [DeviceProfile] = []
    @Published public private(set) var sessions: [UUID: DeviceSession] = [:]
    @Published public private(set) var tasks: [DeviceTask] = []
    @Published public private(set) var tools: ToolSettings
    @Published public private(set) var externalSessions: [UUID: [ExternalCLISession]] = [:]
    @Published public private(set) var externalScanError: String?
    @Published public var notice: String?
    public let componentInstaller: ComponentInstaller
    public let allowsComponentInstallation: Bool
    public let reachability: ReachabilityChecker

    private struct Runtime {
        let connection: ForwardConnection
        let adb: URL
        let generation: UUID
    }
    private enum TargetIdentity: Equatable { case application(UUID), cli(String) }
    private struct OperationTarget {
        let serial: String
        let adb: URL
        let identity: TargetIdentity
    }
    @Published private var externalDetails: [String: DeviceSession] = [:]
    private var informationJobs: [UUID: Task<Void, Never>] = [:]
    private var informationTokens: [UUID: UUID] = [:]
    private var externalInfoAttempted: Set<String> = []
    private let configurationStore: ConfigurationStore?
    private let credentials: any CredentialStore
    private let runner: any CommandExecuting
    private let makeTransport: @MainActor (URL, any CommandExecuting) -> any ForwardTransport
    private let cliScanner: (any CLISessionScanning)?
    private var cliMonitor: Task<Void, Never>?
    private var externalScanInProgress = false
    private var externalRevision = UUID()
    private var externalCredentials: [UUID: String] = [:]
    private var temporaryCredentials: [UUID: String] = [:]
    private var nextTemporaryNumber = 1
    private var generations: [UUID: UUID] = [:]
    private var runtimes: [UUID: Runtime] = [:]
    private var connections: [UUID: Task<Void, Never>] = [:]
    private var monitors: [UUID: Task<Void, Never>] = [:]
    private var taskJobs: [UUID: Task<Void, Never>] = [:]
    private var diagnosticJobs: [UUID: Task<Void, Never>] = [:]
    private var retryCounts: [UUID: Int] = [:]
    private var nextRetries: [UUID: Date] = [:]
    private let monitorInterval: UInt64

    public init(configuration: AppConfiguration = AppConfiguration(),
                configurationStore: ConfigurationStore? = nil,
                credentials: any CredentialStore,
                runner: any CommandExecuting,
                monitorInterval: UInt64 = 3_000_000_000,
                cliScanner: (any CLISessionScanning)? = nil,
                allowsComponentInstallation: Bool = true,
                makeTransport: @escaping @MainActor (URL, any CommandExecuting) -> any ForwardTransport = { TailcatTransport(executable: $0, runner: $1) }) {
        self.profiles = configuration.profiles
        self.tools = configuration.tools
        self.configurationStore = configurationStore
        self.credentials = CachedCredentialStore(credentials)
        self.runner = runner
        self.monitorInterval = monitorInterval
        self.makeTransport = makeTransport
        self.cliScanner = cliScanner
        self.componentInstaller = ComponentInstaller(runner: runner)
        self.reachability = ReachabilityChecker(runner: runner)
        self.allowsComponentInstallation = allowsComponentInstallation
        for profile in profiles { sessions[profile.id] = DeviceSession() }
    }

    public func session(_ id: UUID) -> DeviceSession {
        let owned = sessions[id] ?? DeviceSession()
        if owned.serial != nil || owned.state.isBusy { return owned }
        guard let external = selectedExternal(id) else { return owned }
        var observed = external.deviceSession; observed.logs = owned.logs
        if let detail = externalDetails[external.id] {
            if detail.model != "—" { observed.model = detail.model }
            if detail.product != "—" { observed.product = detail.product }
            observed.android = detail.android; observed.deviceSerial = detail.deviceSerial; observed.identity = detail.identity
            if detail.route != "未探测" { observed.route = detail.route }
        }
        return observed
    }
    private func selectedExternal(_ id: UUID) -> ExternalCLISession? {
        externalSessions[id]?.first(where: { $0.state == .online }) ?? externalSessions[id]?.first
    }
    public var ownedActiveCount: Int { sessions.values.filter { $0.serial != nil }.count }
    public var externalActiveCount: Int { externalSessions.values.reduce(0) { $0 + $1.count } }
    public var activeCount: Int { ownedActiveCount + externalActiveCount }
    public var allProfiles: [DeviceProfile] { profiles + temporaryProfiles }
    public func isTemporary(_ id: UUID) -> Bool { temporaryProfiles.contains { $0.id == id } }

    public func startCLIObservation() {
        guard cliScanner != nil, cliMonitor == nil else { return }
        cliMonitor = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshExternalConnections()
                do { try await Task.sleep(nanoseconds: self?.monitorInterval ?? 3_000_000_000) } catch { return }
            }
        }
    }

    public func refreshExternalConnections(allowCredentialPrompt: Bool = false) async {
        guard let cliScanner, !externalScanInProgress else { return }
        externalScanInProgress = true
        defer { externalScanInProgress = false }
        let revision = externalRevision
        do {
            let found = try await cliScanner.scan(root: URL(fileURLWithPath: tools.addressBookDirectory), profiles: profiles,
                adbPath: tools.adb, addressForProfile: { [weak self] id in
                    guard let self else { return nil }
                    if let cached = self.externalCredentials[id] { return cached }
                    let address = try allowCredentialPrompt ? self.credentials.read(id: id) : self.credentials.readForObservation(id: id)
                    self.externalCredentials[id] = address
                    return address
                })
            guard revision == externalRevision, !Task.isCancelled else { return }
            let previous = externalSessions.keys.reduce(into: [UUID: String]()) { $0[$1] = selectedExternal($1)?.id }
            externalSessions = found; externalScanError = nil
            for (id, identity) in previous where selectedExternal(id)?.id != identity && runtimes[id] == nil && connections[id] == nil {
                _ = cancelDeviceTasks(id)
                diagnosticJobs.removeValue(forKey: id)?.cancel()
                informationJobs.removeValue(forKey: id)?.cancel(); informationTokens.removeValue(forKey: id)
            }
            let alive = Set(found.values.flatMap { $0.map(\.id) })
            externalDetails = externalDetails.filter { alive.contains($0.key) }
            externalInfoAttempted.formIntersection(alive)
            for id in found.keys {
                if session(id).isExternalCLI, let external = selectedExternal(id), external.state == .online,
                   !externalInfoAttempted.contains(external.id) {
                    externalInfoAttempted.insert(external.id)
                    refreshDeviceInformation(id)
                }
            }
        } catch is CancellationError { return }
        catch {
            guard revision == externalRevision, !Task.isCancelled else { return }
            externalSessions = [:]
            externalScanError = "CLI 会话检测失败：\(Credentials.redact(error.localizedDescription))"
        }
    }

    public func shutdown() async {
        externalRevision = UUID(); cliMonitor?.cancel(); cliMonitor = nil
        await componentInstaller.shutdown()
        await reachability.shutdown()
        let operations = Array(taskJobs.values) + Array(diagnosticJobs.values) + Array(informationJobs.values)
        for job in operations { job.cancel() }
        for job in operations { await job.value }
        await disconnectAll()
        for profile in temporaryProfiles {
            sessions.removeValue(forKey: profile.id); generations.removeValue(forKey: profile.id)
            retryCounts.removeValue(forKey: profile.id); nextRetries.removeValue(forKey: profile.id)
        }
        temporaryProfiles = []; temporaryCredentials = [:]
    }

    public func installComponent(_ component: ToolComponent, onConfigured: @escaping @MainActor (String) -> Void = { _ in }) {
        guard allowsComponentInstallation else { notice = "演示模式不安装真实组件"; return }
        componentInstaller.install(component) { [weak self] path in
            try self?.configureInstalledTool(component, path: path)
            onConfigured(path)
        }
    }

    public func installMissingComponents(onConfigured: @escaping @MainActor (ToolComponent, String) -> Void = { _, _ in }) {
        guard allowsComponentInstallation else { notice = "演示模式不安装真实组件"; return }
        let missing = ToolComponent.allCases.filter { !FileManager.default.isExecutableFile(atPath: tools[$0]) }
        componentInstaller.install(missing) { [weak self] component, path in
            try self?.configureInstalledTool(component, path: path)
            onConfigured(component, path)
        }
    }

    public func saveDevice(id: UUID? = nil, name: String, address: String,
                           preferredPort: Int?, remotePort: Int) throws -> UUID {
        let (name, address) = try validatedDeviceInput(name: name, address: address, preferredPort: preferredPort, remotePort: remotePort)
        let deviceID = id ?? UUID()
        guard !isTemporary(deviceID) else { throw ManagerError.message("请使用“保存到我的设备”保存临时会话") }
        guard session(deviceID).serial == nil, !session(deviceID).state.isBusy else {
            throw ManagerError.message("请先断开该设备，再修改连接配置")
        }
        let old = try credentials.read(id: deviceID)
        var updated = profiles
        var profile = updated.first { $0.id == deviceID } ?? DeviceProfile(id: deviceID, name: name)
        profile.name = name; profile.preferredPort = preferredPort; profile.remotePort = remotePort
        if let index = updated.firstIndex(where: { $0.id == deviceID }) { updated[index] = profile }
        else { updated.append(profile) }
        try credentials.write(address, id: deviceID)
        do { try persist(profiles: updated) }
        catch {
            if let old { try? credentials.write(old, id: deviceID) } else { try? credentials.delete(id: deviceID) }
            throw error
        }
        profiles = updated
        externalCredentials[deviceID] = address; externalRevision = UUID()
        externalSessions.removeValue(forKey: deviceID)
        if sessions[deviceID] == nil { sessions[deviceID] = DeviceSession() }
        return deviceID
    }

    public func addressForEditing(_ id: UUID) throws -> String { try address(for: id) ?? "" }

    /// Temporary profiles and credentials exist only in memory until explicitly promoted.
    @discardableResult public func saveTemporaryDevice(id: UUID? = nil, name: String = "", address: String,
                                                      preferredPort: Int? = nil, remotePort: Int = 5555) throws -> UUID {
        let suppliedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let defaultName = id.flatMap { existing in temporaryProfiles.first { $0.id == existing }?.name } ?? "临时设备 \(nextTemporaryNumber)"
        let (name, address) = try validatedDeviceInput(name: suppliedName.isEmpty ? defaultName : suppliedName,
            address: address, preferredPort: preferredPort, remotePort: remotePort)
        if let id {
            guard isTemporary(id) else { throw ManagerError.message("临时设备已关闭或已保存") }
            guard session(id).serial == nil, !session(id).state.isBusy else { throw ManagerError.message("请先断开该临时设备，再修改连接配置") }
        }
        let deviceID = id ?? UUID()
        let profile = DeviceProfile(id: deviceID, name: name, preferredPort: preferredPort, remotePort: remotePort)
        temporaryCredentials[deviceID] = address
        if let index = temporaryProfiles.firstIndex(where: { $0.id == deviceID }) { temporaryProfiles[index] = profile }
        else { temporaryProfiles.append(profile); sessions[deviceID] = DeviceSession(); nextTemporaryNumber += 1 }
        return deviceID
    }

    public func promoteTemporaryDevice(_ id: UUID, name: String) throws {
        guard var profile = temporaryProfiles.first(where: { $0.id == id }), let address = temporaryCredentials[id] else {
            throw ManagerError.message("临时设备已关闭或已保存")
        }
        guard session(id).state != .disconnecting else { throw ManagerError.message("临时设备正在关闭，请稍后再保存") }
        let validated = try validatedDeviceInput(name: name, address: address, preferredPort: profile.preferredPort, remotePort: profile.remotePort)
        profile.name = validated.0
        let updated = profiles + [profile]
        try credentials.write(address, id: id)
        do { try persist(profiles: updated) }
        catch { try? credentials.delete(id: id); throw error }
        // UUID, generation, process handle and task targets stay intact while the profile moves groups.
        profiles = updated; temporaryProfiles.removeAll { $0.id == id }; temporaryCredentials.removeValue(forKey: id)
        externalRevision = UUID(); externalCredentials[id] = address
        notice = "已保存到我的设备，当前会话保持"
    }

    private func address(for id: UUID) throws -> String? {
        if isTemporary(id) { return temporaryCredentials[id] }
        return try credentials.read(id: id)
    }

    private func validatedDeviceInput(name: String, address: String, preferredPort: Int?, remotePort: Int) throws -> (String, String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 80 else { throw ManagerError.message("设备名称需要 1–80 个字符") }
        guard Credentials.isPlausible(address) else { throw ManagerError.message("请填写以 tc 开头的完整 Tailcat 连接地址") }
        guard (1...65535).contains(remotePort), preferredPort.map({ (1...65535).contains($0) }) ?? true else {
            throw ManagerError.message("端口必须在 1–65535 之间；本地端口留空表示自动分配")
        }
        return (name, address)
    }

    @discardableResult public func importLegacy() throws -> Int {
        let result = try LegacyAddressBook.read(root: URL(fileURLWithPath: tools.addressBookDirectory))
        let additions = result.entries.filter { entry in !profiles.contains { $0.legacyUsername == entry.username } }
        var updated = profiles; var written: [UUID] = []
        do {
            for entry in additions {
                let profile = DeviceProfile(name: entry.username, legacyUsername: entry.username)
                try credentials.write(entry.address, id: profile.id)
                written.append(profile.id); updated.append(profile)
            }
            try persist(profiles: updated)
        } catch {
            for id in written { try? credentials.delete(id: id) }
            throw error
        }
        profiles = updated
        externalRevision = UUID()
        for id in written { sessions[id] = DeviceSession() }
        let count = additions.count
        notice = "已导入 \(count) 台设备，已存在的条目保留" + (result.skipped > 0 ? "；跳过 \(result.skipped) 个无效条目" : "")
        return count
    }

    public func updateTools(_ settings: ToolSettings) throws {
        guard ownedActiveCount == 0, !sessions.values.contains(where: { $0.state.isBusy }) else {
            throw ManagerError.message("请先断开应用管理的连接，再修改工具路径")
        }
        try configurationStore?.save(AppConfiguration(profiles: profiles, tools: settings))
        tools = settings
        externalRevision = UUID(); externalSessions = [:]
    }

    public func configureInstalledTool(_ component: ToolComponent, path: String) throws {
        _ = try ToolLocator.executable(path, name: component.label)
        var settings = tools; settings[component] = path
        try configurationStore?.save(AppConfiguration(profiles: profiles, tools: settings))
        // Running owned sessions retain their captured tool URLs and process handles.
        tools = settings; externalRevision = UUID()
    }

    public func removeDevice(_ id: UUID) async throws {
        let tasks = cancelDeviceTasks(id)
        for task in tasks { await task.value }
        let information = informationJobs.removeValue(forKey: id); information?.cancel(); await information?.value
        informationTokens.removeValue(forKey: id)
        await disconnect(id).value
        if isTemporary(id) {
            temporaryProfiles.removeAll { $0.id == id }; temporaryCredentials.removeValue(forKey: id)
            sessions.removeValue(forKey: id); generations.removeValue(forKey: id)
            retryCounts.removeValue(forKey: id); nextRetries.removeValue(forKey: id)
            return
        }
        let updated = profiles.filter { $0.id != id }
        try persist(profiles: updated)
        profiles = updated; sessions.removeValue(forKey: id)
        externalSessions.removeValue(forKey: id); externalCredentials.removeValue(forKey: id); externalRevision = UUID()
        try credentials.delete(id: id)
    }

    private func persist(profiles: [DeviceProfile]) throws {
        try configurationStore?.save(AppConfiguration(profiles: profiles, tools: tools))
    }

    @discardableResult public func connect(_ id: UUID) -> Task<Void, Never>? {
        guard let profile = allProfiles.first(where: { $0.id == id }), !session(id).state.isBusy,
              !session(id).isExternalCLI else { return nil }
        let previous = runtimes.removeValue(forKey: id)
        let previousJob = connections.removeValue(forKey: id)
        previousJob?.cancel(); monitors.removeValue(forKey: id)?.cancel()
        diagnosticJobs.removeValue(forKey: id)?.cancel()
        let oldTasks = cancelDeviceTasks(id)
        let generation = UUID(); generations[id] = generation
        retryCounts[id] = 0; nextRetries[id] = nil
        var fresh = DeviceSession(); fresh.logs = session(id).logs; fresh.state = .connecting
        sessions[id] = fresh
        let job = Task { [weak self] in
            guard let self else { return }
            await previousJob?.value
            for task in oldTasks { await task.value }
            if let previous { await self.close(previous) }
            guard self.isCurrent(id, generation), !Task.isCancelled else { return }
            do {
                let tailcat = try ToolLocator.executable(self.tools.tailcat, name: "Tailcat")
                let adb = try ToolLocator.executable(self.tools.adb, name: "ADB")
                guard let address = try self.address(for: id), Credentials.isPlausible(address) else {
                    throw ManagerError.message("设备没有有效连接凭据，请编辑设备或重新导入地址簿")
                }
                // Use the native parser to reject malformed addresses before starting a listener.
                let parsed = try await self.runner.run(Command(tailcat, ["parse", address], timeout: 5), onOutput: { _ in })
                try parsed.requireSuccess(); try Task.checkCancellation()
                guard self.isCurrent(id, generation) else { return }
                self.log(id, "正在建立独立 Tailcat 转发通道")
                let transport = self.makeTransport(tailcat, self.runner)
                let connection = try await transport.open(address: address, preferredPort: profile.preferredPort, remotePort: profile.remotePort,
                    onLog: { [weak self] chunk in
                        guard let self, self.isCurrent(id, generation) else { return }
                        self.log(id, Credentials.redact(chunk, address: address))
                    }, onExit: { [weak self] code in
                        guard let self, self.isCurrent(id, generation), self.runtimes[id] != nil else { return }
                        self.transportExited(id, generation: generation, code: code)
                    })
                guard self.isCurrent(id, generation), !Task.isCancelled else { await connection.handle.stop(); return }
                self.runtimes[id] = Runtime(connection: connection, adb: adb, generation: generation)
                self.change(id) { $0.serial = connection.serial; $0.pid = connection.handle.pid }
                let result = try await self.runner.run(Command(adb, ["connect", connection.serial], timeout: 15), onOutput: { _ in })
                try Task.checkCancellation()
                guard self.isCurrent(id, generation) else { return }
                self.log(id, Credentials.redact(result.output, address: address))
                if result.timedOut { self.log(id, "ADB 连接等待超时，通道保留，可重试或等待设备上线") }
                for _ in 0..<10 {
                    try Task.checkCancellation()
                    await self.refresh(id, generation: generation)
                    let state = self.session(id).state
                    if state == .online || state == .unauthorized { break }
                    try await Task.sleep(nanoseconds: 400_000_000)
                }
                guard self.isCurrent(id, generation), !Task.isCancelled else { return }
                self.startMonitor(id, generation: generation)
            } catch is CancellationError {
                // disconnect/reconnect owns the replacement state and cleanup.
            } catch {
                guard self.isCurrent(id, generation), !Task.isCancelled else { return }
                if let runtime = self.runtimes.removeValue(forKey: id) { await self.close(runtime) }
                guard self.isCurrent(id, generation) else { return }
                self.change(id) { $0.state = .failed; $0.serial = nil; $0.pid = nil; $0.error = Credentials.redact(error.localizedDescription) }
                self.log(id, "连接失败：\(Credentials.redact(error.localizedDescription))")
            }
            if self.isCurrent(id, generation) { self.connections.removeValue(forKey: id) }
        }
        connections[id] = job
        return job
    }

    @discardableResult public func disconnect(_ id: UUID) -> Task<Void, Never> {
        guard runtimes[id] != nil || connections[id] != nil || (sessions[id]?.serial != nil) else { return Task {} }
        let generation = UUID(); generations[id] = generation
        let connectionJob = connections.removeValue(forKey: id)
        connectionJob?.cancel(); monitors.removeValue(forKey: id)?.cancel()
        let diagnostic = diagnosticJobs.removeValue(forKey: id); diagnostic?.cancel()
        let jobs = cancelDeviceTasks(id)
        let runtime = runtimes.removeValue(forKey: id)
        change(id) { $0.state = .disconnecting }
        let job = Task { [weak self] in
            guard let self else { return }
            await connectionJob?.value; await diagnostic?.value
            for task in jobs { await task.value }
            if let runtime { await self.close(runtime) }
            guard self.isCurrent(id, generation) else { return }
            self.change(id) { $0.state = .disconnected; $0.serial = nil; $0.pid = nil; $0.error = nil; $0.route = "未探测" }
            self.log(id, "已断开该设备，其他会话保持")
            self.connections.removeValue(forKey: id)
        }
        connections[id] = job
        return job
    }

    public func disconnectAll() async {
        let jobs = allProfiles.map { disconnect($0.id) }
        for job in jobs { await job.value }
    }

    private func close(_ runtime: Runtime) async {
        // Keep the port reserved until its ADB entry is removed; another session
        // must not reuse the serial while an old disconnect command is in flight.
        let cleanup = Task { [runner] in
            _ = try? await runner.run(Command(runtime.adb, ["disconnect", runtime.connection.serial], timeout: 3), onOutput: { _ in })
            await runtime.connection.handle.stop()
        }
        await cleanup.value
    }

    private func transportExited(_ id: UUID, generation: UUID, code: Int32) {
        guard isCurrent(id, generation) else { return }
        generations[id] = UUID()
        connections.removeValue(forKey: id)?.cancel()
        monitors.removeValue(forKey: id)?.cancel()
        diagnosticJobs.removeValue(forKey: id)?.cancel()
        _ = cancelDeviceTasks(id)
        let runtime = runtimes.removeValue(forKey: id)
        change(id) { $0.state = .failed; $0.serial = nil; $0.pid = nil; $0.error = "Tailcat 转发进程已退出（\(code)），请重新连接" }
        log(id, "转发进程退出，退出码 \(code)")
        if let runtime {
            connections[id] = Task { await close(runtime) }
        }
    }

    private func startMonitor(_ id: UUID, generation: UUID) {
        monitors[id]?.cancel()
        monitors[id] = Task { [weak self] in
            guard let self else { return }
            while self.isCurrent(id, generation), !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: self.monitorInterval) } catch { return }
                await self.refresh(id, generation: generation)
                await self.retryOffline(id, generation: generation)
            }
        }
    }

    private func refresh(_ id: UUID, generation: UUID) async {
        guard let runtime = runtimes[id], isCurrent(id, generation), runtime.connection.handle.isRunning else { return }
        let result = try? await runner.run(Command(runtime.adb, ["-s", runtime.connection.serial, "get-state"], timeout: 4), onOutput: { _ in })
        guard isCurrent(id, generation), !Task.isCancelled, runtimes[id] != nil else { return }
        let output = result?.output.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let state: ConnectionState = output == "device" && result?.exitCode == 0 ? .online : output.contains("unauthorized") ? .unauthorized : .offline
        let previous = session(id).state
        change(id) { $0.state = state; $0.error = state == .offline ? "本地通道运行中，ADB 尚未上线" : nil }
        if previous != state { log(id, state.label) }
        if state == .online { retryCounts[id] = 0; nextRetries[id] = nil }
        if state == .online && (previous != .online || session(id).model == "—") {
            let command = "getprop ro.product.model; getprop ro.product.device; getprop ro.build.version.release; getprop ro.serialno; id"
            let info = try? await runner.run(Command(runtime.adb, ["-s", runtime.connection.serial, "shell", command], timeout: 6), onOutput: { _ in })
            guard isCurrent(id, generation), !Task.isCancelled, info?.exitCode == 0 else { return }
            let lines = (info?.output ?? "").replacingOccurrences(of: "\r", with: "").components(separatedBy: "\n")
            change(id) {
                if lines.count >= 5 {
                    $0.model = lines[0]; $0.product = lines[1]; $0.android = lines[2]
                    $0.deviceSerial = lines[3]; $0.identity = lines[4]
                }
            }
        }
    }

    // ADB retries are bounded; unauthorized devices wait for authorization instead.
    private func retryOffline(_ id: UUID, generation: UUID) async {
        guard isCurrent(id, generation), !Task.isCancelled, session(id).state == .offline,
              let runtime = runtimes[id], runtime.connection.handle.isRunning else { return }
        let count = retryCounts[id] ?? 0
        guard count < 6, (nextRetries[id] ?? .distantPast) <= Date() else { return }
        retryCounts[id] = count + 1
        nextRetries[id] = Date().addingTimeInterval(min(30, pow(2, Double(count + 1))))
        log(id, "尝试恢复 ADB 连接（\(count + 1)/6）")
        _ = try? await runner.run(Command(runtime.adb, ["connect", runtime.connection.serial], timeout: 10), onOutput: { _ in })
        guard isCurrent(id, generation), !Task.isCancelled else { return }
        await refresh(id, generation: generation)
        if count == 5 && session(id).state == .offline {
            change(id) { $0.error = "自动恢复已尝试 6 次，请检查设备后重新连接" }
        }
    }

    public func recheckConnections() {
        Task { await refreshExternalConnections() }
        for (id, runtime) in runtimes {
            retryCounts[id] = 0; nextRetries[id] = nil
            startMonitor(id, generation: runtime.generation)
        }
    }

    public func testAllDevices() {
        reachability.start(profiles: allProfiles, tailcatPath: tools.tailcat,
                           temporaryIDs: Set(temporaryProfiles.map(\.id)),
                           adbState: { [weak self] id in self?.session(id).state ?? .disconnected }) { [weak self] id in
            try self?.address(for: id)
        }
    }

    public func diagnose(_ id: UUID) {
        guard diagnosticJobs[id] == nil, let target = try? operationTarget(id, requireOnline: false) else { return }
        diagnosticJobs[id] = Task { [weak self] in
            guard let self else { return }
            defer { self.diagnosticJobs.removeValue(forKey: id) }
            do {
                guard let address = try self.address(for: id) else { return }
                let executable = try ToolLocator.executable(self.tools.tailcat, name: "Tailcat")
                let result = try await self.runner.run(Command(executable, ["ping", "--timeout=3s", address], timeout: 5), onOutput: { _ in })
                guard self.targetIsCurrent(id, target), !Task.isCancelled else { return }
                let output = Credentials.redact(result.output, address: address)
                let pong = output.components(separatedBy: "\n").last { $0.hasPrefix("pong in ") }
                self.changeTargetDetails(id, target: target) { $0.route = pong ?? "探测失败" }
                self.log(id, output.isEmpty ? "Tailcat 探测未返回结果" : output)
            } catch {
                guard self.targetIsCurrent(id, target), !Task.isCancelled else { return }
                self.log(id, "链路探测：\(Credentials.redact(error.localizedDescription))")
            }
        }
    }

    @discardableResult public func beginADBTask(_ id: UUID, title: String, arguments: [String], timeout: TimeInterval = 300) throws -> UUID {
        let snapshot = try operationTarget(id)
        return startTask(id, title: title, target: snapshot,
                         command: Command(snapshot.adb, ["-s", snapshot.serial] + arguments, timeout: timeout))
    }

    @discardableResult public func beginAPKInstall(_ id: UUID, file: URL) throws -> UUID {
        let target = try operationTarget(id)
        guard !tasks.contains(where: { $0.deviceID == id && $0.state == .running && $0.installProgress != nil }) else {
            throw ManagerError.message("这台设备已有 APK 正在安装，请等待完成或取消后再试")
        }
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard file.isFileURL, file.pathExtension.lowercased() == "apk", values.isRegularFile == true,
              let size = values.fileSize, size > 0, FileManager.default.isReadableFile(atPath: file.path) else {
            throw ManagerError.message("请选择可读取的非空 APK 文件")
        }
        // Let ADB own upload, replacement, and temporary-file cleanup. Its non-streaming
        // mode exposes real upload progress; a terminal prevents buffering/suppression.
        let command = Command(target.adb, ["-s", target.serial, "install", "--no-streaming", "-r", file.path],
                              timeout: 600, environment: ["TERM": "xterm"], terminalOutput: true)
        return startTask(id, title: "安装 \(file.lastPathComponent)", target: target,
                         command: command, installProgress: APKInstallProgress(totalBytes: Int64(size)))
    }

    @discardableResult public func beginScreen(_ id: UUID) throws -> UUID {
        let snapshot = try operationTarget(id)
        let executable = try ToolLocator.executable(tools.scrcpy, name: "scrcpy")
        return startTask(id, title: "屏幕控制", target: snapshot,
                         command: Command(executable, ["-s", snapshot.serial, "--max-size=1280", "--video-bit-rate=4M", "--max-fps=30"], timeout: 86_400,
                                          environment: ["ADB": snapshot.adb.path]))
    }

    public func terminalCommand(_ id: UUID) async throws -> (adb: String, serial: String) {
        let target = try operationTarget(id)
        try await validateTarget(id, target)
        return (target.adb.path, target.serial)
    }

    private func operationTarget(_ id: UUID, requireOnline: Bool = true) throws -> OperationTarget {
        guard allProfiles.contains(where: { $0.id == id }), !session(id).state.isBusy,
              !requireOnline || session(id).state == .online else {
            throw ManagerError.message("该设备的 ADB 尚未进入 device 状态")
        }
        if let runtime = runtimes[id], runtime.connection.handle.isRunning {
            return OperationTarget(serial: runtime.connection.serial, adb: runtime.adb, identity: .application(runtime.generation))
        }
        if let external = selectedExternal(id), cliScanner != nil {
            return OperationTarget(serial: external.serial, adb: try ToolLocator.executable(tools.adb, name: "ADB"), identity: .cli(external.id))
        }
        throw ManagerError.message("设备通道已结束，请重新连接")
    }

    private func targetIsCurrent(_ id: UUID, _ target: OperationTarget) -> Bool {
        guard allProfiles.contains(where: { $0.id == id }) else { return false }
        switch target.identity {
        case .application(let generation):
            return isCurrent(id, generation) && runtimes[id]?.connection.handle.isRunning == true && session(id).serial == target.serial
        case .cli(let identity):
            return runtimes[id] == nil && !session(id).state.isBusy && selectedExternal(id)?.id == identity && selectedExternal(id)?.serial == target.serial
        }
    }

    private func validateTarget(_ id: UUID, _ target: OperationTarget) async throws {
        guard targetIsCurrent(id, target) else { throw CancellationError() }
        if case .cli(let identity) = target.identity {
            guard let scanner = cliScanner, let profile = profiles.first(where: { $0.id == id }) else { throw CancellationError() }
            let found = try await scanner.scan(root: URL(fileURLWithPath: tools.addressBookDirectory), profiles: [profile], adbPath: target.adb.path,
                addressForProfile: { [weak self] id in
                    guard let self else { return nil }
                    return try self.externalCredentials[id] ?? self.address(for: id)
                })
            guard found[id]?.contains(where: { $0.id == identity && $0.serial == target.serial && $0.state == .online }) == true else {
                throw ManagerError.message("CLI 会话已变化或离线，未执行设备操作")
            }
        }
        try Task.checkCancellation()
        guard targetIsCurrent(id, target) else { throw CancellationError() }
        let state = try await runner.run(Command(target.adb, ["-s", target.serial, "get-state"], timeout: 4), onOutput: { _ in })
        try Task.checkCancellation()
        guard targetIsCurrent(id, target), state.exitCode == 0,
              state.output.trimmingCharacters(in: .whitespacesAndNewlines) == "device" else {
            throw ManagerError.message("任务目标已离线，未执行设备操作")
        }
    }

    private func changeTargetDetails(_ id: UUID, target: OperationTarget, _ body: (inout DeviceSession) -> Void) {
        if case .cli(let identity) = target.identity {
            var detail = externalDetails[identity] ?? DeviceSession(); body(&detail); externalDetails[identity] = detail
        } else { change(id, body) }
    }

    @discardableResult public func refreshDeviceInformation(_ id: UUID) -> Task<Void, Never>? {
        if let running = informationJobs[id] { return running }
        guard let target = try? operationTarget(id) else { return nil }
        let token = UUID(); informationTokens[id] = token
        let job = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.informationTokens[id] == token { self.informationJobs.removeValue(forKey: id); self.informationTokens.removeValue(forKey: id) }
            }
            do {
                try await self.validateTarget(id, target)
                let command = "getprop ro.product.model; getprop ro.product.device; getprop ro.build.version.release; getprop ro.serialno; id"
                let info = try await self.runner.run(Command(target.adb, ["-s", target.serial, "shell", command], timeout: 6), onOutput: { _ in })
                try Task.checkCancellation(); try info.requireSuccess()
                guard self.targetIsCurrent(id, target) else { return }
                let lines = info.output.replacingOccurrences(of: "\r", with: "").components(separatedBy: "\n")
                if lines.count >= 5 {
                    self.changeTargetDetails(id, target: target) {
                        $0.model = lines[0]; $0.product = lines[1]; $0.android = lines[2]; $0.deviceSerial = lines[3]; $0.identity = lines[4]
                    }
                }
            } catch is CancellationError { return }
            catch {
                guard !Task.isCancelled, self.targetIsCurrent(id, target) else { return }
                self.log(id, "设备信息读取失败：\(Credentials.redact(error.localizedDescription))")
            }
        }
        informationJobs[id] = job; return job
    }

    private func startTask(_ id: UUID, title: String, target: OperationTarget, command: Command,
                           installProgress: APKInstallProgress? = nil) -> UUID {
        let serial = target.serial
        let taskID = UUID()
        let name = allProfiles.first(where: { $0.id == id })?.name ?? "设备"
        var task = DeviceTask(id: taskID, deviceID: id, deviceName: name, serial: serial, title: title)
        task.installProgress = installProgress
        tasks.append(task)
        // Trim completed history only; active tasks always remain visible and cancellable.
        while tasks.count > 100, let index = tasks.firstIndex(where: { $0.state != .running }) { tasks.remove(at: index) }
        let job = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.validateTarget(id, target)
                let redactor = OutputRedactor()
                let parser = installProgress.map { APKInstallOutputParser(totalBytes: $0.totalBytes) }
                let result = try await self.runner.run(command, onOutput: { [weak self] chunk in
                    if let parser {
                        let progress = parser.append(chunk)
                        self?.updateTask(taskID) { $0.installProgress = progress }
                    }
                    let redacted = redactor.append(chunk)
                    let safe = parser == nil ? redacted : APKInstallOutputParser.plainText(redacted)
                    if !safe.isEmpty { self?.updateTask(taskID) { $0.output = String(($0.output + safe).suffix(32768)) } }
                })
                try Task.checkCancellation()
                guard self.targetIsCurrent(id, target) else { throw CancellationError() }
                try result.requireSuccess()
                self.updateTask(taskID) {
                    $0.state = .succeeded
                    $0.output = String(Credentials.redact(parser == nil ? result.output : APKInstallOutputParser.plainText(result.output)).suffix(32768))
                    if $0.installProgress != nil { $0.installProgress?.stage = .completed; $0.installProgress?.fraction = 1 }
                }
                self.log(id, "\(title)已完成 · \(serial)")
            } catch is CancellationError {
                self.updateTask(taskID) { $0.state = .cancelled }
            } catch {
                if Task.isCancelled { self.updateTask(taskID) { $0.state = .cancelled } }
                else {
                    self.updateTask(taskID) {
                        $0.state = .failed
                        $0.output = Credentials.redact(installProgress == nil ? error.localizedDescription : APKInstallOutputParser.plainText(error.localizedDescription))
                    }
                    self.log(id, "\(title)失败：\(Credentials.redact(error.localizedDescription))")
                }
            }
            self.taskJobs.removeValue(forKey: taskID)
        }
        taskJobs[taskID] = job
        return taskID
    }

    public func cancelTask(_ id: UUID) { taskJobs[id]?.cancel() }
    public func waitForTask(_ id: UUID) async { await taskJobs[id]?.value }
    private func cancelDeviceTasks(_ id: UUID) -> [Task<Void, Never>] {
        let jobs = tasks.filter { $0.deviceID == id && $0.state == .running }.compactMap { taskJobs[$0.id] }
        for job in jobs { job.cancel() }
        return jobs
    }
    private func updateTask(_ id: UUID, change: (inout DeviceTask) -> Void) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        change(&tasks[index])
    }
    private func isCurrent(_ id: UUID, _ generation: UUID) -> Bool { generations[id] == generation }
    private func change(_ id: UUID, _ body: (inout DeviceSession) -> Void) {
        var state = sessions[id] ?? DeviceSession(); body(&state); sessions[id] = state
    }
    private func log(_ id: UUID, _ output: String) {
        let output = Credentials.redact(output).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !output.isEmpty else { return }
        change(id) {
            $0.logs.append(SessionLog(String(output.suffix(8192))))
            if $0.logs.count > 200 { $0.logs.removeFirst($0.logs.count - 200) }
        }
    }
}
