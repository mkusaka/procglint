import Foundation
import ProcglintCore
import ProcglintIPC

/// Only selected by --ui-testing; no OS sampling, XPC, registration, or real signals.
@MainActor
final class UITestingFixture: MonitorService {
    enum BatteryState: String, CaseIterable {
        case charging, discharging, charged, unknown, none

        var metrics: BatteryMetrics? {
            guard self != .none else { return nil }
            if self == .unknown {
                return BatteryMetrics()
            }
            return BatteryMetrics(percent: .ok(self == .charged ? 100 : 69), isCharging: self == .charging,
                                  externalPower: self != .discharging,
                                  timeRemainingMinutes: self == .charged ? .unsupported : .ok(self == .charging ? 113 : 190),
                                  cycleCount: .ok(5), healthPercent: .ok(100),
                                  systemPowerMW: .ok(33100), adapterPowerMW: .ok(self == .discharging ? 0 : 67000),
                                  batteryPowerMW: .ok(self == .discharging ? -12400 : (self == .charging ? 28000 : 0)))
        }
    }

    private let current: Snapshot
    private var store: SnapshotStore
    private var currentPolicy: SamplingPolicy
    private var pins: Set<ProcessKey> = []
    private var tickets: [String: TerminationTicket] = [:]
    private var audit: [String] = []
    private let auditURL: URL?
    let suiteName = "io.github.mkusaka.procglint.ui-testing.\(UUID().uuidString)"

    var agentRegistrationStatus: AgentRegistration.Status
    private let requiresApproval: Bool
    var agentRegistered: Bool {
        get { agentRegistrationStatus == .enabled }
        set { agentRegistrationStatus = newValue ? .enabled : .notRegistered }
    }

    func registerAgent() {
        agentRegistrationStatus = requiresApproval ? .requiresApproval : .enabled
    }

    private var loginItemStatus = AgentRegistration.Status.notRegistered

    var loginItem: LoginItemService {
        LoginItemService(status: { self.loginItemStatus },
                         register: { self.loginItemStatus = .enabled },
                         unregister: { self.loginItemStatus = .notRegistered })
    }

    init(unregistered: Bool = false, requiresApproval: Bool = false, battery: BatteryState = .charging) throws {
        self.requiresApproval = requiresApproval
        agentRegistrationStatus = unregistered ? .notRegistered : (requiresApproval ? .requiresApproval : .enabled)
        currentPolicy = try SamplingPolicy()
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let rows = try (0 ..< 20).map { index in
            let denied = index == 18
            let own = index != 19
            let cpu: Metric = denied ? .permissionDenied : (index == 17 ? .warmingUp : .ok(Double(index + 1)))
            return try ProcessSample(
                processKey: ProcessKey("p1.boot-ui.\(4100 + index).10"), pid: Int32(4100 + index), ppid: index == 0 ? 4101 : 1,
                name: [0: "Alpha Worker", 1: "Fixture Terminal", 17: "Warming Worker", 18: "Denied Worker", 19: "Other User Worker"][index] ?? "Worker \(index)",
                uid: own ? 501 : 502, user: own ? "fixture-user" : "other-user", isOwn: own,
                status: denied ? .permissionDenied : .ok, cpuPercent: cpu,
                cpuTimeNS: denied ? nil : UInt64(index + 1) * 1_000_000_000,
                footprintBytes: denied ? .permissionDenied : .ok(Double(index + 1) * 1_048_576),
                rssBytes: denied ? .permissionDenied : .ok(2_097_152),
                diskReadBytes: denied ? .permissionDenied : .ok(4096),
                diskWrittenBytes: denied ? .permissionDenied : .ok(8192),
                diskReadBps: cpu.status == .ok ? .ok(1024) : cpu,
                diskWriteBps: cpu.status == .ok ? .ok(2048) : cpu,
                startTime: date, path: "/fixture/worker",
                powerMW: !own || denied ? .permissionDenied : (cpu.status == .ok ? .ok(index == 1 ? 12 : Double(index + 1) * 1030) : cpu),
                networkReceiveBps: !own || denied ? .permissionDenied : (cpu.status == .ok ? .ok(Double(index + 1) * 1_200_000) : cpu),
                networkSendBps: !own || denied ? .permissionDenied : (cpu.status == .ok ? .ok(Double(index + 1) * 340_000) : cpu),
                networkReceivedBytes: !own || denied ? .permissionDenied : .ok(Double(index + 1) * 12_000_000),
                networkSentBytes: !own || denied ? .permissionDenied : .ok(Double(index + 1) * 3_400_000)
            )
        }
        current = Snapshot(
            agentInstanceID: "agent-ui", snapshotID: "agent-ui-1", sampledAt: date,
            intervalMS: 5000, ageMS: 0, status: .ok,
            coverage: Coverage(enumerated: 20, sampled: 19, permissionDenied: 1),
            system: SystemMetrics(cpuPercent: .ok(25), physicalMemoryBytes: 8_589_934_592, pageSize: 16384,
                                  memoryUsedBytes: 4_294_967_296, wiredBytes: 1_073_741_824,
                                  compressedBytes: 536_870_912, activeBytes: 2_684_354_560,
                                  inactiveBytes: 1_073_741_824, freeBytes: 3_221_225_472,
                                  memoryPressure: .ok(.normal), memoryPressurePercent: .ok(39), swapUsedBytes: .ok(1_073_741_824), swapTotalBytes: .ok(2_147_483_648),
                                  battery: battery.metrics, networkReceiveBps: .ok(12_400_000), networkSendBps: .ok(1_200_000)),
            processes: rows
        )
        store = SnapshotStore(clock: FakeClock())
        store.insert(current)
        auditURL = ProcessInfo.processInfo.environment["PROCGLINT_UI_TEST_AUDIT_PATH"].map { URL(fileURLWithPath: $0) }
        try writeAudit()
    }

    func preferences() throws -> AppPreferences {
        let preferences = AppPreferences(suiteName: suiteName)
        preferences.defaults.removePersistentDomain(forName: suiteName)
        try preferences.store.setAllowedPermissions(.all)
        return preferences
    }

    func cleanUp() {
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
    }

    func snapshot(top: Int, sort: ProcessSort) async throws -> Snapshot {
        let page = try store.listProcesses(ProcessQuery(filter: .all, sort: sort, limit: top), scope: AccessScope(includeSystem: true))
        return Snapshot(header: page.snapshot, processes: page.items)
    }

    func listProcesses(_ query: ProcessQuery) async throws -> ProcessPage {
        try requireAgent()
        return try store.listProcesses(query, scope: AccessScope(includeSystem: true, includePaths: true), pinned: pins)
    }

    func process(key: ProcessKey) async throws -> ProcessSample {
        guard var row = current.processes.first(where: { $0.processKey == key }) else { throw AgentError.notFound("Fixture process") }
        var root = row
        root.pid = 1
        root.ppid = 0
        root.name = "launchd"
        root.processKey = try ProcessKey("p1.boot-ui.1.1")
        row.addLineage(from: current.processes + [root])
        let permissions = try UserDefaultsSettingsStore(suiteName: suiteName).allowedPermissions()
        if permissions.contains(.includeCommandLines) {
            row.commandLine = row.isOwn ? ProcessCommandLine(arguments: ["node", "server.js", "--token", "ui-secret"]) : ProcessCommandLine(unavailable: .permissionDenied)
            row.cwd = row.isOwn ? WorkingDirectory(value: "/fixture/project") : WorkingDirectory(unavailable: .permissionDenied)
            row.ancestors = row.ancestors?.map {
                var ancestor = $0
                ancestor.commandLine = ancestor.pid == 1 ? ProcessCommandLine(unavailable: .permissionDenied) : ProcessCommandLine(arguments: [ancestor.name, "--auth=ui-secret"])
                return ancestor
            }
        }
        if !permissions.contains(.includePaths) {
            row.path = nil
        }
        return row
    }

    func history(_ request: HistoryRequest) async throws -> [HistorySeries] {
        let date = current.sampledAt
        return request.series.map { series in
            let process = current.processes.first { $0.processKey.rawValue == series }
            let power = process?.powerMW ?? .unsupported
            let receive = series == "system" ? current.system.networkReceiveBps : (process?.networkReceiveBps ?? .unsupported)
            let send = series == "system" ? current.system.networkSendBps : (process?.networkSendBps ?? .unsupported)
            let systemPower = current.system.battery?.systemPowerMW
            let points = stride(from: -600.0, through: 0, by: 5).map { offset in
                let level: MemoryPressure = (-210.0 ... -190).contains(offset) ? .critical : ((-240.0 ... -160).contains(offset) ? .warning : .normal)
                let pressureBase: Double = switch level {
                case .normal: 39
                case .warning: 65
                case .critical: 88
                }
                let cpu = 25 + 8 * sin(offset / 25)
                let memory = 4_294_967_296 + 268_435_456 * sin(offset / 80)
                let read = 1024 * (1 + 0.2 * sin(offset / 20))
                let write = 2048 * (1 + 0.25 * sin(offset / 40))
                return HistoryPoint(t: date.addingTimeInterval(offset), cpuPercent: .ok(cpu),
                                    footprintBytes: series == "system" ? nil : .ok(1_048_576),
                                    diskReadBps: .ok(read), diskWriteBps: .ok(write),
                                    memoryUsedBytes: series == "system" ? .ok(memory) : nil,
                                    memoryPressurePercent: series == "system" ? .ok(pressureBase + 4 * sin(offset / 35)) : nil,
                                    memoryPressure: series == "system" ? level : nil,
                                    systemPowerMW: series == "system" ? systemPower.map { metric in
                                        metric.value.map { .ok($0 + 2500 * sin(offset / 35)) } ?? metric
                                    } : nil,
                                    batteryPercent: series == "system" ? current.system.battery?.percent : nil,
                                    powerMW: series == "system" ? nil : (power.value.map { .ok($0 * (1 + 0.2 * sin(offset / 30))) } ?? power),
                                    networkReceiveBps: receive.value.map { .ok($0 * (1 + 0.3 * sin(offset / 30))) } ?? receive,
                                    networkSendBps: send.value.map { .ok($0 * (1 + 0.2 * sin(offset / 40))) } ?? send)
            }
            return HistorySeries(series: series, points: points,
                                 gaps: [HistoryGap(from: date.addingTimeInterval(-19), to: date.addingTimeInterval(-6))])
        }
    }

    func status() async throws -> MonitorStatus {
        try requireAgent()
        return MonitorStatus(agentInstanceID: current.agentInstanceID, agentPID: 4000, agentCPUPercent: .ok(0.1),
                             agentFootprintBytes: 1_048_576, samplingActive: true, effectiveIntervalMS: .fiveSeconds,
                             collectionsTotal: 2, lastCollectionMS: 1, collectionP95MS: 1, lastCoverage: current.coverage,
                             failures: [:], leases: [], clients: [], historyBytes: 4096, policy: currentPolicy)
    }

    func setLease(_ request: LeaseRequest) async throws -> SamplingLease {
        try requireAgent()
        try request.validate()
        return SamplingLease(leaseID: request.kind.rawValue, clientID: "gui-ui", kind: request.kind,
                             intervalMS: request.intervalMS, expiresAt: 30_000_000_000)
    }

    func releaseLease(id _: String) async throws {}

    func startObservation(_: ObservationRequest) async throws -> Observation {
        throw AgentError.permissionDenied("Not used by the GUI fixture")
    }

    func stopObservation(id _: String) async throws {
        throw AgentError.permissionDenied("Not used by the GUI fixture")
    }

    func pin(key: ProcessKey, pinned: Bool) async throws {
        _ = try await process(key: key)
        if pinned {
            pins.insert(key)
        } else {
            pins.remove(key)
        }
    }

    func policy() async throws -> SamplingPolicy {
        currentPolicy
    }

    func setPolicy(_ policy: SamplingPolicy, expectedRevision: Int) async throws -> SamplingPolicy {
        guard expectedRevision == currentPolicy.revision else { throw AgentError.revisionConflict("Fixture policy changed") }
        try policy.validate()
        currentPolicy = policy
        currentPolicy.revision += 1
        return currentPolicy
    }

    func prepareTermination(key: ProcessKey, signal: TerminationSignal) async throws -> TerminationTicket {
        let row = try await process(key: key)
        guard row.isOwn, row.status == .ok else { throw AgentError.permissionDenied("Fixture target is not terminable") }
        let token = "tok-\(audit.count + 1)"
        let ticket = TerminationTicket(token: token, processKey: key, pid: row.pid, name: row.name,
                                       signal: signal, expiresAt: current.sampledAt.addingTimeInterval(30))
        tickets[token] = ticket
        audit.append("prepare \(row.pid) \(signal.rawValue)")
        try writeAudit()
        return ticket
    }

    func terminate(token: String) async throws -> TerminationResult {
        guard let ticket = tickets.removeValue(forKey: token) else { throw AgentError.permissionDenied("Unknown or used fixture ticket") }
        audit.append("signal \(ticket.pid) \(ticket.signal.rawValue)")
        try writeAudit()
        return try TerminationResult(outcome: .signalSent, exitedConfirmed: false)
    }

    private func requireAgent() throws {
        guard agentRegistered else { throw AgentError.agentUnavailable("UI fixture agent is not registered") }
    }

    private func writeAudit() throws {
        // The runner reads this spy journal to prove Cancel never calls prepare/terminate.
        if let auditURL {
            try audit.joined(separator: "\n").write(to: auditURL, atomically: true, encoding: .utf8)
        }
    }
}
