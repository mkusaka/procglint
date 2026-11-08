import Foundation
import ProcglintCore

func sample(pid: Int32 = 42, key: String = "p1.boot-a.42.10", cpu: Metric = .ok(12.5)) throws -> ProcessSample {
    try ProcessSample(processKey: ProcessKey(key), pid: pid, name: "worker", uid: 501, user: "tester", isOwn: true,
                      status: .ok, cpuPercent: cpu, cpuTimeNS: 2_000_000_000, footprintBytes: .ok(2048),
                      rssBytes: .ok(4096), diskReadBytes: .ok(8192), diskWrittenBytes: .permissionDenied,
                      diskReadBps: .warmingUp, diskWriteBps: .ok(1024), startTime: Date(timeIntervalSince1970: 10))
}

func snapshot(_ rows: [ProcessSample] = [], instance: String = "agent-a", id: String = "sample-1", status: SnapshotStatus = .ok) -> Snapshot {
    Snapshot(agentInstanceID: instance, snapshotID: id, sampledAt: Date(timeIntervalSince1970: 100), intervalMS: 5000,
             ageMS: 0, status: status, coverage: Coverage(enumerated: rows.count, sampled: rows.count),
             system: SystemMetrics(cpuPercent: status == .warmingUp ? .warmingUp : .ok(25), physicalMemoryBytes: 8192,
                                   pageSize: 4096, memoryUsedBytes: 4096, wiredBytes: 1024, compressedBytes: 512,
                                   activeBytes: 2560, inactiveBytes: 0, freeBytes: 4096), processes: rows)
}

@MainActor
final class FakeMonitorService: MonitorService {
    var current: Snapshot
    var currentPolicy: SamplingPolicy
    var queries: [ProcessQuery] = []
    var leaseRequests: [LeaseRequest] = []
    var released: [String] = []
    var terminationCalls: [String] = []
    var processCalls: [ProcessKey] = []
    var historyRequests: [HistoryRequest] = []
    var pinned: Set<ProcessKey> = []
    var snapshotCalls = 0
    var nextCursor: String?
    var pageOverride: ProcessPage?
    var pagesByCursor: [String: ProcessPage] = [:]
    var snapshotError: AgentError?
    var prepareError: AgentError?
    var historyError: AgentError?
    var beforeSnapshot: (@MainActor () async -> Void)?
    var beforeList: (@MainActor () async -> Void)?
    var beforeProcess: (@MainActor () async -> Void)?
    var terminationResult: TerminationResult
    var expectedRevisions: [Int] = []

    init(rows: [ProcessSample] = []) throws {
        current = AppTests.snapshot(rows)
        currentPolicy = try SamplingPolicy()
        terminationResult = try TerminationResult(outcome: .signalSent, exitedConfirmed: false)
    }

    func snapshot(top _: Int, sort _: ProcessSort) async throws -> Snapshot {
        snapshotCalls += 1
        await beforeSnapshot?()
        if let snapshotError {
            throw snapshotError
        }
        return current
    }

    func listProcesses(_ query: ProcessQuery) async throws -> ProcessPage {
        queries.append(query)
        await beforeList?()
        if let pageOverride {
            return pageOverride
        }
        if let cursor = query.cursor, let page = pagesByCursor[cursor] {
            return page
        }
        var rows = current.processes
        if query.filter == .pinned {
            rows = rows.filter { pinned.contains($0.processKey) }
        }
        return ProcessPage(snapshot: current.header, items: rows, nextCursor: nextCursor, totalMatched: rows.count)
    }

    func process(key: ProcessKey) async throws -> ProcessSample {
        processCalls.append(key)
        await beforeProcess?()
        guard var process = current.processes.first(where: { $0.processKey == key }) else { throw AgentError.notFound("process") }
        process.path = "/Applications/Worker.app/Contents/MacOS/worker"
        return process
    }

    func history(_ request: HistoryRequest) async throws -> [HistorySeries] {
        historyRequests.append(request)
        if let historyError {
            throw historyError
        }
        return request.series.map { HistorySeries(series: $0, points: []) }
    }

    func status() async throws -> MonitorStatus {
        MonitorStatus(agentInstanceID: current.agentInstanceID, agentPID: 20, agentCPUPercent: .warmingUp,
                      agentFootprintBytes: 4096, samplingActive: true, effectiveIntervalMS: .fiveSeconds,
                      collectionsTotal: 7, lastCollectionMS: 2, collectionP95MS: 4, lastCoverage: current.coverage,
                      failures: ["denied": 3], leases: [], clients: [
                          .init(clientID: "client-a", kind: .mcp, pid: 30, footprintBytes: 2048, cpuPercent: .ok(1)),
                      ], historyBytes: 1024, policy: currentPolicy)
    }

    func setLease(_ request: LeaseRequest) async throws -> SamplingLease {
        leaseRequests.append(request)
        if let snapshotError {
            throw snapshotError
        }
        return SamplingLease(leaseID: request.kind.rawValue, clientID: "gui-a", kind: request.kind, intervalMS: request.intervalMS, expiresAt: 30_000_000_000)
    }

    func releaseLease(id: String) async throws {
        released.append(id)
    }

    func startObservation(_: ObservationRequest) async throws -> Observation {
        throw AgentError.permissionDenied("not used by GUI")
    }

    func stopObservation(id _: String) async throws {
        throw AgentError.permissionDenied("not used by GUI")
    }

    func pin(key: ProcessKey, pinned: Bool) async throws {
        if pinned {
            self.pinned.insert(key)
        } else {
            self.pinned.remove(key)
        }
    }

    func policy() async throws -> SamplingPolicy {
        currentPolicy
    }

    func setPolicy(_ policy: SamplingPolicy, expectedRevision: Int) async throws -> SamplingPolicy {
        expectedRevisions.append(expectedRevision)
        guard expectedRevision == currentPolicy.revision else { throw AgentError.revisionConflict("policy changed") }
        try policy.validate()
        currentPolicy = policy
        currentPolicy.revision += 1
        return currentPolicy
    }

    func prepareTermination(key: ProcessKey, signal: TerminationSignal) async throws -> TerminationTicket {
        terminationCalls.append("prepare:\(key.rawValue):\(signal.rawValue)")
        if let prepareError {
            throw prepareError
        }
        return TerminationTicket(token: "tok-1", processKey: key, pid: 42, name: "worker", signal: signal, expiresAt: Date(timeIntervalSince1970: 130))
    }

    func terminate(token: String) async throws -> TerminationResult {
        terminationCalls.append("terminate:\(token)")
        return terminationResult
    }
}

@MainActor
final class RequestGate {
    private var entered = false
    private var started: CheckedContinuation<Void, Never>?
    private var blocked: CheckedContinuation<Void, Never>?

    func suspend() async {
        entered = true
        await withCheckedContinuation { continuation in
            blocked = continuation
            started?.resume()
            started = nil
        }
    }

    func waitUntilEntered() async {
        if entered {
            return
        }
        await withCheckedContinuation { started = $0 }
    }

    func resume() {
        blocked?.resume(); blocked = nil
    }
}
