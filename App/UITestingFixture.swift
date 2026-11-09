import Foundation
import ProcglintCore
import ProcglintIPC

/// Only selected by --ui-testing; no OS sampling, XPC, registration, or real signals.
@MainActor
final class UITestingFixture: MonitorService {
    private let current: Snapshot
    private var store: SnapshotStore
    private var currentPolicy: SamplingPolicy
    private var pins: Set<ProcessKey> = []
    private var tickets: [String: TerminationTicket] = [:]
    private var audit: [String] = []
    private let auditURL: URL?
    let suiteName = "io.github.mkusaka.procglint.ui-testing.\(UUID().uuidString)"

    var agentRegistered: Bool
    private var loginItemStatus = AgentRegistration.Status.notRegistered

    var loginItem: LoginItemService {
        LoginItemService(status: { self.loginItemStatus },
                         register: { self.loginItemStatus = .enabled },
                         unregister: { self.loginItemStatus = .notRegistered })
    }

    init(unregistered: Bool = false) throws {
        agentRegistered = !unregistered
        currentPolicy = try SamplingPolicy()
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let rows = try (0 ..< 20).map { index in
            let denied = index == 18
            let own = index != 19
            let cpu: Metric = denied ? .permissionDenied : (index == 17 ? .warmingUp : .ok(Double(index + 1)))
            return try ProcessSample(
                processKey: ProcessKey("p1.boot-ui.\(4100 + index).10"), pid: Int32(4100 + index),
                name: [0: "Alpha Worker", 17: "Warming Worker", 18: "Denied Worker", 19: "Other User Worker"][index] ?? "Worker \(index)",
                uid: own ? 501 : 502, user: own ? "fixture-user" : "other-user", isOwn: own,
                status: denied ? .permissionDenied : .ok, cpuPercent: cpu,
                cpuTimeNS: denied ? nil : UInt64(index + 1) * 1_000_000_000,
                footprintBytes: denied ? .permissionDenied : .ok(Double(index + 1) * 1_048_576),
                rssBytes: denied ? .permissionDenied : .ok(2_097_152),
                diskReadBytes: denied ? .permissionDenied : .ok(4096),
                diskWrittenBytes: denied ? .permissionDenied : .ok(8192),
                diskReadBps: cpu.status == .ok ? .ok(1024) : cpu,
                diskWriteBps: cpu.status == .ok ? .ok(2048) : cpu,
                startTime: date, path: "/fixture/worker"
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
                                  memoryPressure: .ok(.normal), swapUsedBytes: .ok(1_073_741_824), swapTotalBytes: .ok(2_147_483_648)),
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
        guard let row = current.processes.first(where: { $0.processKey == key }) else { throw AgentError.notFound("Fixture process") }
        return row
    }

    func history(_ request: HistoryRequest) async throws -> [HistorySeries] {
        let date = current.sampledAt
        return request.series.map { series in
            let points = [-30.0, -20, -5, 0].map { offset in
                HistoryPoint(t: date.addingTimeInterval(offset), cpuPercent: .ok(25),
                             footprintBytes: series == "system" ? nil : .ok(1_048_576),
                             diskReadBps: .ok(1024), diskWriteBps: .ok(2048),
                             memoryUsedBytes: series == "system" ? .ok(4_294_967_296) : nil)
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
