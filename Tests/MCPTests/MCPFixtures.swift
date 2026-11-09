import Foundation
import ProcglintCore
@testable import ProcglintMCPKit

let testDate = Date(timeIntervalSince1970: 1000)

func sample(name: String = "worker") throws -> ProcessSample {
    try ProcessSample(processKey: ProcessKey("p1.boot-a.42.1"), pid: 42, name: name, uid: 501, user: "tester", isOwn: true, status: .ok,
                      cpuPercent: .ok(125), cpuTimeNS: 9_007_199_254_740_993, footprintBytes: .ok(1024), rssBytes: .ok(2048),
                      diskReadBytes: .ok(10), diskWrittenBytes: .ok(20), diskReadBps: .warmingUp, diskWriteBps: .permissionDenied,
                      startTime: testDate)
}

func makeSnapshot(name: String = "worker") throws -> Snapshot {
    let system = SystemMetrics(cpuPercent: .ok(25), physicalMemoryBytes: 4096, pageSize: 16384, memoryUsedBytes: 1024,
                               wiredBytes: 128, compressedBytes: 128, activeBytes: 768, inactiveBytes: 512, freeBytes: 2560,
                               memoryPressure: .ok(.warning), memoryPressurePercent: .ok(65), swapUsedBytes: .ok(1024), swapTotalBytes: .ok(2048))
    return try Snapshot(agentInstanceID: "agent-a", snapshotID: "agent-a-1", sampledAt: testDate, intervalMS: nil, ageMS: 0,
                        status: .warmingUp, coverage: Coverage(enumerated: 1, sampled: 1), system: system, processes: [sample(name: name)])
}

actor TestMonitor: MonitorService {
    var failure: AgentError?
    var largeName: String?
    var snapshotFailure: AgentError?
    var unavailableMemory = false
    var detail: ProcessSample?
    var calls: [(String, JSONValue)] = []
    var blocked = false
    let clock = FakeClock()
    private var enteredWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func configure(failure: AgentError? = nil, largeName: String? = nil, blocked: Bool = false, detail: ProcessSample? = nil) {
        self.failure = failure
        self.largeName = largeName
        self.blocked = blocked
        self.detail = detail
    }

    func configureMemory(unavailable: Bool = false, snapshotFailure: AgentError? = nil) {
        unavailableMemory = unavailable
        self.snapshotFailure = snapshotFailure
    }

    func waitForCalls(_ count: Int) async {
        if calls.count >= count {
            return
        }
        await withCheckedContinuation { enteredWaiters.append((count, $0)) }
    }

    private func record(_ name: String, _ value: JSONValue = [:]) async throws {
        calls.append((name, value))
        let ready = enteredWaiters.filter { $0.0 <= calls.count }
        enteredWaiters.removeAll { $0.0 <= calls.count }
        for (_, continuation) in ready {
            continuation.resume()
        }
        if let failure {
            throw failure
        }
        if blocked {
            try await clock.sleep(until: 1_000_000_000)
        }
        try Task.checkCancellation()
    }

    func snapshot(top: Int, sort: ProcessSort) async throws -> Snapshot {
        try await record("get_snapshot", ["top": .number(.init(top)), "sort": .string(sort.rawValue)])
        if let snapshotFailure {
            throw snapshotFailure
        }
        var snapshot = try makeSnapshot(name: largeName ?? "worker")
        if unavailableMemory {
            snapshot.system.memoryPressure = .unsupported
            snapshot.system.memoryPressurePercent = .unsupported
            snapshot.system.swapUsedBytes = .unsupported
            snapshot.system.swapTotalBytes = .unsupported
        }
        return snapshot
    }

    func listProcesses(_ query: ProcessQuery) async throws -> ProcessPage {
        try await record("list_processes", .encoded(query))
        return try ProcessPage(snapshot: makeSnapshot().header, items: [sample()], nextCursor: "cursor-a", totalMatched: 1)
    }

    func process(key: ProcessKey) async throws -> ProcessSample {
        try await record("get_process", .encoded(key)); return try detail ?? sample()
    }

    func history(_ request: HistoryRequest) async throws -> [HistorySeries] {
        try await record("get_history", .encoded(request))
        return request.series.map { HistorySeries(series: $0, points: [HistoryPoint(t: testDate, cpuPercent: .warmingUp, memoryPressurePercent: .ok(65), memoryPressure: .warning)],
                                                  gaps: [HistoryGap(from: testDate, to: testDate)]) }
    }

    func status() async throws -> MonitorStatus {
        try await record("get_monitor_status")
        return try MonitorStatus(agentInstanceID: "agent-a", agentPID: 100, agentCPUPercent: .ok(0.1), agentFootprintBytes: 4096,
                                 samplingActive: false, effectiveIntervalMS: nil, collectionsTotal: 9_007_199_254_740_993,
                                 lastCollectionMS: 2, collectionP95MS: 3, lastCoverage: Coverage(), failures: ["example": 1],
                                 leases: [], clients: [], historyBytes: 0, policy: SamplingPolicy())
    }

    func startObservation(_ request: ObservationRequest) async throws -> Observation {
        try await record("start_observation", .encoded(request))
        return Observation(observationID: "obs-a", intervalMS: request.intervalMS, startedAt: testDate,
                           expiresAt: testDate.addingTimeInterval(Double(request.durationMS) / 1000), processKeys: request.processKeys, state: .active)
    }

    func stopObservation(id: String) async throws {
        try await record("stop_observation", .string(id))
    }

    func setPolicy(_ policy: SamplingPolicy, expectedRevision: Int) async throws -> SamplingPolicy {
        try await record("set_sampling_policy", ["policy": .encoded(policy), "expected_revision": .number(.init(expectedRevision))])
        var result = policy
        result.revision += 1
        return result
    }

    func prepareTermination(key: ProcessKey, signal: TerminationSignal) async throws -> TerminationTicket {
        try await record("prepare_termination", ["process_key": .encoded(key), "signal": .encoded(signal)])
        return TerminationTicket(token: "tok-a", processKey: key, pid: 42, name: "worker", signal: signal, expiresAt: testDate.addingTimeInterval(30))
    }

    func terminate(token: String) async throws -> TerminationResult {
        try await record("terminate_process", .string(token))
        return try TerminationResult(outcome: .signalSent, exitedConfirmed: false)
    }

    func policy() async throws -> SamplingPolicy {
        try SamplingPolicy()
    }

    func setLease(_: LeaseRequest) async throws -> SamplingLease {
        throw AgentError.internalError("Not used by MCP")
    }

    func releaseLease(id _: String) async throws {
        throw AgentError.internalError("Not used by MCP")
    }

    func pin(key _: ProcessKey, pinned _: Bool) async throws {
        throw AgentError.internalError("Not used by MCP")
    }
}

let modernMeta: JSONValue = [
    "io.modelcontextprotocol/protocolVersion": "2026-07-28",
    "io.modelcontextprotocol/clientInfo": ["name": "test", "version": "1"],
    "io.modelcontextprotocol/clientCapabilities": [:],
]

func request(_ method: String, params: [String: JSONValue] = [:], id: JSONValue? = 1, modern: Bool = true) throws -> String {
    var params = params
    if modern {
        params["_meta"] = modernMeta
    }
    var value: [String: JSONValue] = ["jsonrpc": "2.0", "method": .string(method), "params": .object(params)]
    if let id {
        value["id"] = id
    }
    return try JSONValue.object(value).text()
}

func response(_ server: MCPServer, _ method: String, params: [String: JSONValue] = [:], id: JSONValue = 1, modern: Bool = true) async throws -> JSONValue {
    let line = try request(method, params: params, id: id, modern: modern)
    guard let output = await server.handle(line: line) else { throw AgentError.internalError("Expected response") }
    return try ProcglintJSON.decoder().decode(JSONValue.self, from: Data(output.utf8))
}

func call(_ server: MCPServer, _ name: String, _ arguments: JSONValue = [:], id: JSONValue = 1) async throws -> JSONValue {
    try await response(server, "tools/call", params: ["name": .string(name), "arguments": arguments], id: id)
}
