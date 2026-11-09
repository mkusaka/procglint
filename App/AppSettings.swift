import Foundation
import ProcglintCore

public typealias AppSettingsKeys = ProcglintCore.AppSettingsKeys
public typealias DefaultsSettingsStore = UserDefaultsSettingsStore

@MainActor
final class AppPreferences {
    let store: DefaultsSettingsStore
    let defaults: UserDefaults

    init(suiteName: String? = AppSettingsKeys.suite) {
        store = DefaultsSettingsStore(suiteName: suiteName)
        defaults = suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
    }

    var menuBar: Bool {
        get { defaults.bool(forKey: AppSettingsKeys.menuBar) }
        set { defaults.set(newValue, forKey: AppSettingsKeys.menuBar) }
    }

    var adaptiveRefresh: Bool {
        get { defaults.object(forKey: AppSettingsKeys.adaptiveRefresh) as? Bool ?? true }
        set { defaults.set(newValue, forKey: AppSettingsKeys.adaptiveRefresh) }
    }

    func visible(_ column: ProcessColumn) -> Bool {
        !column.optional || (defaults.stringArray(forKey: AppSettingsKeys.columns) ?? []).contains(column.rawValue)
    }

    func setVisible(_ visible: Bool, column: ProcessColumn) {
        guard column.optional else { return }
        var columns = Set(defaults.stringArray(forKey: AppSettingsKeys.columns) ?? [])
        if visible {
            columns.insert(column.rawValue)
        } else {
            columns.remove(column.rawValue)
        }
        defaults.set(columns.sorted(), forKey: AppSettingsKeys.columns)
    }
}

enum MCPConfiguration {
    static func helperURL(in bundle: Bundle) -> URL? {
        if let helper = bundle.url(forAuxiliaryExecutable: "procglint-mcp") {
            return helper
        }
        let helper = bundle.bundleURL.appendingPathComponent("Contents/Helpers/procglint-mcp")
        return FileManager.default.isExecutableFile(atPath: helper.path) ? helper : nil
    }

    private struct Configuration: Encodable {
        let mcpServers: [String: Server]
    }

    private struct Server: Encodable {
        let command: String
        let args: [String]
    }

    static func json(helperURL: URL, permissions: PermissionSet) throws -> String {
        let flags: [(Permission, String)] = [
            (.observe, "--allow-observe"), (.configure, "--allow-configure"),
            (.terminate, "--allow-terminate"), (.forceKill, "--allow-force-kill"),
            (.includeSystem, "--include-system"), (.includePaths, "--include-paths"),
        ]
        let configuration = Configuration(mcpServers: ["procglint": Server(
            command: helperURL.path, args: flags.filter { permissions.contains($0.0) }.map(\.1)
        )])
        let encoder = ProcglintJSON.encoder()
        // mcpServers is the host configuration's spelling, not a procglint wire key.
        encoder.keyEncodingStrategy = .useDefaultKeys
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let json = try String(data: encoder.encode(configuration), encoding: .utf8) else {
            throw AgentError.internalError("Could not encode MCP configuration as UTF-8")
        }
        return json
    }
}

@MainActor
final class SettingsViewModel {
    let service: any MonitorService
    let preferences: AppPreferences
    let helperURL: URL?
    let registrationStatus: @MainActor () -> String
    let registerAgent: @MainActor () throws -> Void
    var policy: SamplingPolicy
    var permissions: PermissionSet
    var diagnostics = "Not loaded"
    var message = ""
    var onChange: (@MainActor () -> Void)?
    var onPolicyChanged: (@MainActor (SamplingPolicy) -> Void)?
    var onPermissionsChanged: (@MainActor () -> Void)?
    var onRegistrationChanged: (@MainActor () async -> Void)?
    let loginItem: LoginItemService
    private(set) var changingLoginItem = false

    var opensAtLogin: Bool {
        loginItem.status() == .enabled || loginItem.status() == .requiresApproval
    }

    var loginItemHint: String {
        switch loginItem.status() {
        case .requiresApproval: "Approve procglint in System Settings → General → Login Items."
        case .notFound: "Login item not found — reinstall the complete Procglint.app."
        case .enabled, .notRegistered: ""
        }
    }

    init(service: any MonitorService, preferences: AppPreferences, helperURL: URL?,
         registrationStatus: @escaping @MainActor () -> String, registerAgent: @escaping @MainActor () throws -> Void,
         loginItem: LoginItemService = .mainApp) throws
    {
        self.service = service
        self.preferences = preferences
        self.helperURL = helperURL
        self.registrationStatus = registrationStatus
        self.registerAgent = registerAgent
        self.loginItem = loginItem
        policy = try preferences.store.samplingPolicy()
        permissions = try preferences.store.allowedPermissions()
    }

    func refresh() async {
        do {
            let status = try await service.status()
            policy = status.policy
            onPolicyChanged?(status.policy)
            diagnostics = Self.describe(status)
        } catch { diagnostics = Display.error(error) }
        onChange?()
    }

    func savePolicy(interval: SamplingInterval, historyMinutes: Int) async {
        do {
            let current = try await service.policy()
            var proposed = current
            proposed.guiIntervalMS = interval
            proposed.historyMinutes = historyMinutes
            try proposed.validate()
            let saved = try await service.setPolicy(proposed, expectedRevision: current.revision)
            try preferences.store.setSamplingPolicy(saved)
            policy = saved
            onPolicyChanged?(saved)
            message = "Sampling policy saved"
        } catch { message = Display.error(error) }
        onChange?()
    }

    func setPermission(_ permission: Permission, allowed: Bool) {
        var proposed = permissions
        if allowed {
            proposed.insert(permission)
        } else {
            proposed.remove(permission)
        }
        do {
            try preferences.store.setAllowedPermissions(proposed)
            permissions = proposed
            onPermissionsChanged?()
            message = "Permissions saved; restart the MCP host to apply changed launch flags."
        } catch { message = Display.error(error) }
        onChange?()
    }

    func register() async {
        do { try registerAgent(); message = registrationStatus() } catch { message = Display.error(error) }
        await registrationChanged()
    }

    func registrationChanged() async {
        onChange?()
        await onRegistrationChanged?()
    }

    func setOpensAtLogin(_ enabled: Bool) async {
        guard !changingLoginItem else { return }
        changingLoginItem = true
        onChange?()
        defer { changingLoginItem = false; onChange?() }
        do {
            if enabled {
                try loginItem.register()
            } else {
                try await loginItem.unregister()
            }
            message = loginItemHint
        } catch { message = Display.error(error) }
    }

    func configuration() throws -> String {
        guard let helperURL else { throw AgentError.notFound("The bundled procglint-mcp helper is missing. Install the complete Procglint.app before copying MCP config.") }
        return try MCPConfiguration.json(helperURL: helperURL, permissions: permissions)
    }

    static func describe(_ status: MonitorStatus) -> String {
        let cpu = Display.metric(status.agentCPUPercent, format: Display.percent)
        var lines = [
            "Agent PID \(status.agentPID): CPU \(cpu.text)\(cpu.reason.map { " (\($0))" } ?? ""), footprint \(Display.bytes(Double(status.agentFootprintBytes)))",
            "Sampling: \(status.samplingActive ? "active" : "idle"), interval: \(status.effectiveIntervalMS.map { "\($0.rawValue) ms" } ?? "—")",
            "Collections: \(status.collectionsTotal), last: \(status.lastCollectionMS) ms, p95: \(status.collectionP95MS) ms",
            "Coverage: \(status.lastCoverage.sampled)/\(status.lastCoverage.enumerated), denied: \(status.lastCoverage.permissionDenied), exited: \(status.lastCoverage.exitedDuringSample)",
            "History: \(Display.bytes(Double(status.historyBytes)))",
        ]
        lines += status.clients.map {
            let cpu = Display.metric($0.cpuPercent, format: Display.percent)
            return "\($0.kind.rawValue) PID \($0.pid): CPU \(cpu.text)\(cpu.reason.map { " (\($0))" } ?? ""), footprint \(Display.bytes(Double($0.footprintBytes)))"
        }
        lines += status.failures.sorted { $0.key < $1.key }.map { "Failure \($0.key): \($0.value)" }
        return lines.joined(separator: "\n")
    }
}
