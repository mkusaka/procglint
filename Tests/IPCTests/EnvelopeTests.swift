import Foundation
import ProcglintCore
import ProcglintIPC
import Testing

private let date = Date(timeIntervalSince1970: 1_704_067_200.125)

private func assertRoundTrip<T: Codable & Equatable>(_ value: T) throws {
    let data = try ProcglintJSON.encoder().encode(value)
    #expect(try ProcglintJSON.decoder().decode(T.self, from: data) == value)
    #expect(try ProcglintJSON.encoder().encode(value) == data)
}

private func json(_ value: some Encodable) throws -> String {
    try #require(String(data: ProcglintJSON.encoder().encode(value), encoding: .utf8))
}

private func sample() throws -> ProcessSample {
    try ProcessSample(processKey: ProcessKey("p1.boot.42.9007199254740993"), pid: 42, name: "worker", uid: 501,
                      user: "me", isOwn: true, status: .ok, cpuPercent: .warmingUp, cpuTimeNS: UInt64.max,
                      footprintBytes: .ok(10), rssBytes: .ok(10), diskReadBytes: .ok(0), diskWrittenBytes: .ok(0),
                      diskReadBps: .warmingUp, diskWriteBps: .warmingUp, startTime: date)
}

@Test func everyRequestRoundTrips() throws {
    let key = try ProcessKey("p1.boot.42.9007199254740993")
    let requests: [AgentRequest] = try [
        .hello(ClientHello(clientKind: .mcp, version: "1.0", mcpFlags: [.observe, .includeSystem])),
        .snapshot(top: 50, sort: .cpu),
        .listProcesses(ProcessQuery(search: "worker", filter: .mine, fields: [.processKey, .cpuTimeNS])),
        .process(key: key), .history(HistoryRequest(series: ["system", key.rawValue], since: date)), .status,
        .setLease(LeaseRequest(kind: .guiWindow, intervalMS: .fiveSeconds)), .releaseLease(id: "lease"),
        .startObservation(ObservationRequest(intervalMS: .oneSecond, durationMS: 60000, processKeys: [key])),
        .stopObservation(id: "observation"), .pin(key: key, pinned: true), .policy,
        .setPolicy(SamplingPolicy(revision: 1), expectedRevision: 0),
        .prepareTermination(key: key, signal: .kill), .terminate(token: "token"),
    ]
    #expect(Set(requests.map(\.method)) == Set(AgentRequest.Method.allCases))
    for request in requests {
        try assertRoundTrip(request)
        #expect(try json(request).contains(#""method":""# + request.method.rawValue + #"""#))
    }
    try assertRoundTrip(AgentRequest.hello(ClientHello(clientKind: .gui, version: "1.0")))
    try assertRoundTrip(AgentRequest.hello(ClientHello(clientKind: .mcp, version: "1.0", mcpFlags: [])))
    try assertRoundTrip(AgentRequest.pin(key: key, pinned: false))
}

@Test func everyResponseRoundTrips() throws {
    let process = try sample()
    let system = SystemMetrics(cpuPercent: .warmingUp, physicalMemoryBytes: 8192, pageSize: 4096, memoryUsedBytes: 4096,
                               wiredBytes: 1024, compressedBytes: 1024, activeBytes: 2048, inactiveBytes: 0, freeBytes: 4096)
    let snapshot = Snapshot(agentInstanceID: "instance", snapshotID: "instance-1", sampledAt: date, intervalMS: 1000, ageMS: 0,
                            status: .ok, coverage: Coverage(enumerated: 1, sampled: 1), system: system, processes: [process])
    let policy = try SamplingPolicy()
    let status = MonitorStatus(agentInstanceID: "instance", agentPID: 100, agentCPUPercent: .warmingUp, agentFootprintBytes: 1024,
                               samplingActive: false, effectiveIntervalMS: nil, collectionsTotal: 9_007_199_254_740_993,
                               lastCollectionMS: 1, collectionP95MS: 1, lastCoverage: snapshot.coverage, failures: [:], leases: [],
                               clients: [.init(clientID: "client", kind: .mcp, pid: 101, footprintBytes: 1024, cpuPercent: .warmingUp)],
                               historyBytes: 0, policy: policy)
    let responses: [AgentResponse] = try [
        .hello(clientID: "client"), .snapshot(snapshot),
        .listProcesses(ProcessPage(snapshot: snapshot.header, items: [process], totalMatched: 1)), .process(process),
        .history([HistorySeries(series: "system", points: [.init(t: date, cpuPercent: .ok(25), memoryUsedBytes: .ok(4096))],
                                gaps: [.init(from: date, to: date.addingTimeInterval(5))])]), .status(status),
        .setLease(SamplingLease(leaseID: "lease", clientID: "client", kind: .guiWindow, intervalMS: .fiveSeconds, expiresAt: UInt64.max)),
        .releaseLease,
        .startObservation(Observation(observationID: "observation", intervalMS: .oneSecond, startedAt: date,
                                      expiresAt: date.addingTimeInterval(60), processKeys: [process.processKey], state: .active)),
        .stopObservation, .pin, .policy(policy), .setPolicy(policy),
        .prepareTermination(TerminationTicket(token: "token", processKey: process.processKey, pid: 42, name: "worker", signal: .term, expiresAt: date)),
        .terminate(TerminationResult(outcome: .signalSent, exitedConfirmed: false)), .error(.terminationRejected(.processChanged)),
    ]
    #expect(Set(responses.compactMap(\.method)) == Set(AgentRequest.Method.allCases))
    for response in responses {
        try assertRoundTrip(response)
    }
    try assertRoundTrip(AgentResponse.error(.agentUnavailable("Run procglint doctor")))
    try assertRoundTrip(AgentResponse.terminate(TerminationResult(outcome: .rejected, rejection: .tokenUsed, exitedConfirmed: false)))
}

@Test func envelopeWireShape() throws {
    let hello = AgentRequest.hello(ClientHello(clientKind: .mcp, version: "1.0", mcpFlags: [.includePaths, .observe]))
    #expect(try json(hello) == #"{"hello":{"client_kind":"mcp","mcp_flags":["include_paths","observe"],"version":"1.0"},"method":"hello"}"#)
    #expect(try json(AgentRequest.snapshot(top: 50, sort: .diskReadBps)) == #"{"method":"snapshot","sort":"disk_read_bps","top":50}"#)
    #expect(try json(AgentResponse.hello(clientID: "client")) == #"{"method":"hello","result":"client"}"#)
    #expect(try json(AgentResponse.releaseLease) == #"{"method":"release_lease","result":null}"#)
    #expect(try json(AgentResponse.error(.invalidCursor("expired"))) == #"{"error":{"code":"invalid_cursor","message":"expired"}}"#)
    #expect(try json(AgentRequest.setPolicy(SamplingPolicy(), expectedRevision: 0)).contains(#""expected_revision":0"#))
    #expect(procglintAgentMachServiceName == "io.github.mkusaka.procglint.agent")
}

@Test func malformedEnvelopesAreRejected() {
    for invalid in [#"{"method":"unknown"}"#, #"{"method":"snapshot","sort":"unknown","top":50}"#,
                    #"{"method":"process","key":"p1.boot.-1.0"}"#, #"{"method":"list_processes","query":{"limit":0}}"#,
                    #"{"method":"hello","hello":{"client_kind":"unknown","version":"1.0"}}"#,
                    #"{"method":"start_observation","request":{"interval_ms":1000,"duration_ms":60001}}"#,
                    #"{"method":"set_policy","expected_revision":0,"policy":{"revision":0,"gui_interval_ms":3000,"menu_bar_interval_ms":10000,"history_minutes":10,"max_process_series":16}}"#]
    {
        #expect(throws: (any Error).self) { try ProcglintJSON.decoder().decode(AgentRequest.self, from: Data(invalid.utf8)) }
    }
    for invalid in [#"{"method":"unknown"}"#, #"{"method":"snapshot","result":null}"#,
                    #"{"method":"status","error":{"code":"internal","message":"bad"}}"#,
                    #"{"error":{"code":"termination_rejected","message":"bad"}}"#]
    {
        #expect(throws: (any Error).self) { try ProcglintJSON.decoder().decode(AgentResponse.self, from: Data(invalid.utf8)) }
    }
}
