import Foundation
import ProcglintCore
import Testing

@Test func agentErrors() throws {
    let errors: [AgentError] = [.invalidArgument("bad argument"), .invalidProcessKey("bad key"), .invalidCursor("bad cursor"),
                                .notFound("gone"), .permissionDenied("denied"), .rateLimited("slow down"),
                                .revisionConflict("retry"), .historyLimitReached("full"), .terminationRejected(.tokenForeign),
                                .agentUnavailable("register the agent"), .internalError("failed")]
    #expect(Set(errors.map(\.code)) == Set(AgentError.Code.allCases))
    for error in errors {
        try roundTrip(error)
    }
    #expect(try json(AgentError.terminationRejected(.tokenForeign)) == #"{"code":"termination_rejected","message":"Termination rejected","rejection":"token_foreign"}"#)
    for invalid in [#"{"code":"termination_rejected","message":"no reason"}"#,
                    #"{"code":"internal","message":"oops","rejection":"exited"}"#,
                    #"{"code":"unknown","message":"oops"}"#]
    {
        #expect(throws: (any Error).self) { try ProcglintJSON.decoder().decode(AgentError.self, from: Data(invalid.utf8)) }
    }
}

@Test func terminationContracts() throws {
    let key = try ProcessKey("p1.boot.42.1")
    try roundTrip(TerminationTicket(token: "0123456789abcdef0123456789abcdef", processKey: key, pid: 42,
                                    name: "worker", signal: .term, expiresAt: testDate))
    try roundTrip(TerminationResult(outcome: .signalSent, exitedConfirmed: false))
    for rejection in TerminationRejection.allCases {
        try roundTrip(TerminationResult(outcome: .rejected, rejection: rejection, exitedConfirmed: false))
    }
    invalidArgument { try TerminationResult(outcome: .rejected, exitedConfirmed: false) }
    invalidArgument { try TerminationResult(outcome: .signalSent, rejection: .exited, exitedConfirmed: true) }
    invalidArgument { try ProcglintJSON.decoder().decode(TerminationResult.self, from: Data(#"{"outcome":"rejected","exited_confirmed":false}"#.utf8)) }
    let audit = AuditEntry(timestamp: testDate, clientKind: .mcp, clientPID: 100, processKey: key, pid: 42,
                           name: "worker", signal: .kill, outcome: "rejected", rejection: .permissionDenied)
    try roundTrip(audit)
    #expect(try json(audit).contains(#""client_pid":100"#))
}

@Test func historyAndObservationContracts() throws {
    let system = HistoryPoint(t: testDate, cpuPercent: .ok(10), memoryUsedBytes: .ok(4096))
    let process = HistoryPoint(t: testDate, cpuPercent: .warmingUp, footprintBytes: .ok(1024), diskReadBps: .warmingUp, diskWriteBps: .warmingUp)
    try roundTrip(HistorySeries(series: "system", points: [system], gaps: [HistoryGap(from: testDate, to: testDate.addingTimeInterval(5))]))
    try roundTrip(HistorySeries(series: "p1.boot.42.1", points: [process]))
    try roundTrip(HistoryRequest(series: ["system", "p1.boot.42.1", "observation"], since: testDate))
    for state in ObservationState.allCases {
        try roundTrip(Observation(observationID: "observation", intervalMS: .oneSecond, startedAt: testDate,
                                  expiresAt: testDate.addingTimeInterval(1), processKeys: [], state: state))
    }
    #expect(try json(system).contains(#""memory_used_bytes":{"status":"ok","value":4096}"#))
    #expect(try !json(system).contains("footprint_bytes"))
    let snapshot = try testSnapshot()
    try roundTrip(ProcessPage(snapshot: snapshot.header, items: snapshot.processes, nextCursor: "cursor", totalMatched: 10))
}

@Test func monitorStatusContract() throws {
    let status = try MonitorStatus(agentInstanceID: "instance", agentPID: 100, agentCPUPercent: .warmingUp, agentFootprintBytes: 1024,
                                   samplingActive: true, effectiveIntervalMS: .oneSecond, collectionsTotal: UInt64.max,
                                   lastCollectionMS: 12.5, collectionP95MS: 20, lastCoverage: Coverage(enumerated: 10, sampled: 10),
                                   failures: ["rusage_failed": 9_007_199_254_740_993],
                                   leases: [.init(kind: .guiWindow, intervalMS: .oneSecond, remainingMS: 30000)],
                                   clients: [.init(clientID: "client", kind: .gui, pid: 200, footprintBytes: 2048, cpuPercent: .ok(1))],
                                   historyBytes: 4096, policy: SamplingPolicy())
    try roundTrip(status)
    let encoded = try json(status)
    for fragment in [#""agent_pid":100"#, #""agent_cpu_percent":{"status":"warming_up","value":null}"#,
                     #""collection_p95_ms":20"#, #""collections_total":"18446744073709551615""#,
                     #""failures":{"rusage_failed":"9007199254740993"}"#, #""interval_ms":1000"#,
                     #""remaining_ms":30000"#, #""client_id":"client""#]
    {
        #expect(encoded.contains(fragment))
    }
}

@Test func unknownEnumsAreErrors() {
    func reject(_ type: (some Decodable).Type) {
        #expect(throws: DecodingError.self) { try ProcglintJSON.decoder().decode(type, from: Data(#""unknown""#.utf8)) }
    }
    reject(SnapshotStatus.self)
    reject(ProcessStatus.self)
    reject(ProcessFilter.self)
    reject(ProcessSort.self)
    reject(ProcglintCore.SortOrder.self)
    reject(ProcessField.self)
    reject(LeaseKind.self)
    reject(ObservationState.self)
    reject(Permission.self)
    reject(TerminationSignal.self)
    reject(TerminationRejection.self)
    reject(TerminationOutcome.self)
    reject(ClientKind.self)
}
