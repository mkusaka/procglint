import Foundation
import ProcglintCore
import Testing

func invalidArgument(_ body: () throws -> some Any) {
    do {
        _ = try body()
        Issue.record("Expected invalid_argument")
    } catch let error as AgentError {
        #expect(error.code == .invalidArgument)
    } catch { Issue.record("Unexpected error: \(error)") }
}

@Test func queryValidation() throws {
    for limit in [1, 50, 200] {
        try roundTrip(ProcessQuery(limit: limit))
    }
    for limit in [Int.min, -1, 0, 201, Int.max] {
        invalidArgument { try ProcessQuery(limit: limit) }
    }
    let query = try ProcglintJSON.decoder().decode(ProcessQuery.self, from: Data("{}".utf8))
    #expect(try query == ProcessQuery())
    #expect(query.filter == .mine)
    invalidArgument { try ProcglintJSON.decoder().decode(ProcessQuery.self, from: Data(#"{"limit":201}"#.utf8)) }
    var changed = query
    changed.limit = 0
    invalidArgument { try changed.validate() }
    try roundTrip(ProcessQuery(search: "worker", filter: .all, sort: .diskReadBps, order: .asc, limit: 200,
                               cursor: "opaque", fields: [.processKey, .cpuTimeNS, .path]))
}

@Test func policyValidation() throws {
    #expect(try SamplingPolicy().guiIntervalMS == .fiveSeconds)
    #expect(try SamplingPolicy().menuBarIntervalMS == .tenSeconds)
    for minutes in [1, 10] {
        for series in [1, 16] {
            try roundTrip(SamplingPolicy(historyMinutes: minutes, maxProcessSeries: series))
        }
    }
    for minutes in [0, 11] {
        invalidArgument { try SamplingPolicy(historyMinutes: minutes) }
    }
    for series in [0, 17] {
        invalidArgument { try SamplingPolicy(maxProcessSeries: series) }
    }
    invalidArgument { try SamplingPolicy(revision: -1) }
    var changed = try SamplingPolicy()
    changed.maxProcessSeries = 17
    invalidArgument { try changed.validate() }
    invalidArgument { try ProcglintJSON.decoder().decode(SamplingPolicy.self, from: ProcglintJSON.encoder().encode(changed)) }
    for interval in SamplingInterval.allCases {
        try roundTrip(interval)
        #expect(interval.nanoseconds == UInt64(interval.milliseconds) * 1_000_000)
    }
    for invalid in [0, 999, 1001, 3000, 10001] {
        #expect(throws: DecodingError.self) { try ProcglintJSON.decoder().decode(SamplingInterval.self, from: Data("\(invalid)".utf8)) }
    }
}

@Test func observationValidation() throws {
    let key = try ProcessKey("p1.boot.42.1")
    for duration in [1000, 60000] {
        for count in [0, 16] {
            try roundTrip(ObservationRequest(intervalMS: .oneSecond, durationMS: duration, processKeys: Array(repeating: key, count: count)))
        }
    }
    for duration in [0, 999, 60001, Int.max] {
        invalidArgument { try ObservationRequest(intervalMS: .oneSecond, durationMS: duration) }
    }
    invalidArgument { try ObservationRequest(intervalMS: .oneSecond, durationMS: 1000, processKeys: Array(repeating: key, count: 17)) }
    invalidArgument { try ProcglintJSON.decoder().decode(ObservationRequest.self, from: Data(#"{"interval_ms":1000,"duration_ms":999}"#.utf8)) }
    #expect(throws: DecodingError.self) { try ProcglintJSON.decoder().decode(ObservationRequest.self, from: Data(#"{"interval_ms":1000}"#.utf8)) }
    var changed = try ObservationRequest(intervalMS: .oneSecond, durationMS: 1000)
    changed.durationMS = 60001
    invalidArgument { try changed.validate() }
    invalidArgument { try ProcglintJSON.decoder().decode(ObservationRequest.self, from: ProcglintJSON.encoder().encode(changed)) }
}

@Test func leaseValidation() throws {
    for kind in [LeaseKind.guiWindow, .menuBar] {
        try roundTrip(LeaseRequest(kind: kind, intervalMS: .fiveSeconds))
    }
    invalidArgument { try LeaseRequest(kind: .observation, intervalMS: .oneSecond) }
    invalidArgument { try ProcglintJSON.decoder().decode(LeaseRequest.self, from: Data(#"{"kind":"observation","interval_ms":1000}"#.utf8)) }
    let lease = SamplingLease(leaseID: "lease", clientID: "client", kind: .observation, intervalMS: .oneSecond, expiresAt: UInt64.max)
    try roundTrip(lease)
    #expect(try json(lease).contains(#""expires_at":"18446744073709551615""#))
}

@Test func permissionsIntersection() throws {
    let os: PermissionSet = [.observe, .configure, .terminate, .includeSystem]
    let settings: PermissionSet = [.observe, .terminate, .forceKill]
    let flags: PermissionSet = [.observe, .forceKill, .includePaths]
    #expect(os.intersection(settings).intersection(flags) == [.observe])
    #expect(PermissionSet.all.intersection([]) == [])
    #expect(PermissionSet.all.intersection(os) == os)
    try roundTrip(PermissionSet.all)
    #expect(try json(PermissionSet.all) == #"["configure","force_kill","include_paths","include_system","observe","terminate"]"#)
    #expect(AccessScope(permissions: [.includePaths]) == AccessScope(includePaths: true))
    #expect(AccessScope(permissions: [.includeSystem]).includeSystem)
    #expect(throws: DecodingError.self) { try ProcglintJSON.decoder().decode(PermissionSet.self, from: Data(#"["unknown"]"#.utf8)) }
}
