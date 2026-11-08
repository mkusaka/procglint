import Foundation
import ProcglintCore
import Testing

@Test func leaseRequestKeysAreBackwardCompatibleAndValidated() throws {
    let decoder = ProcglintJSON.decoder()
    let legacy = Data(#"{"kind":"gui_window","interval_ms":5000}"#.utf8)
    #expect(try decoder.decode(LeaseRequest.self, from: legacy).processKeys.isEmpty)
    let keyed = Data(#"{"kind":"gui_window","interval_ms":5000,"process_keys":["p1.boot-a.42.10"]}"#.utf8)
    let request = try decoder.decode(LeaseRequest.self, from: keyed)
    #expect(try request.processKeys == [storeProcess().processKey])
    let encoded = try ProcglintJSON.encoder().encode(request)
    #expect(try decoder.decode(LeaseRequest.self, from: encoded) == request)
    let json = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    #expect(json["process_keys"] as? [String] == request.processKeys.map(\.rawValue))
    #expect(try decoder.decode(LeaseRequest.self, from: Data(#"{"kind":"menu_bar","interval_ms":10000}"#.utf8)).processKeys.isEmpty)
    #expect(throws: AgentError.self) {
        try decoder.decode(LeaseRequest.self, from: Data(#"{"kind":"menu_bar","interval_ms":10000,"process_keys":["p1.boot-a.42.10"]}"#.utf8))
    }
    #expect(throws: AgentError.self) {
        try LeaseRequest(kind: .guiWindow, intervalMS: .fiveSeconds, processKeys: Array(repeating: request.processKeys[0], count: 17))
    }
    #expect(throws: AgentError.self) {
        try decoder.decode(LeaseRequest.self, from: Data(#"{"kind":"gui_window","interval_ms":5000,"process_keys":["bad-key"]}"#.utf8))
    }
}

@Test(.timeLimit(.minutes(1))) func guiLeaseRenewalReplacesKeysWithoutBackfill() async throws {
    let clock = FakeClock()
    let first = try storeProcess()
    let second = try storeProcess(pid: 43)
    let counter = CountingCollect(clock: clock, processes: [first, second])
    let scheduler = try SamplingScheduler(clock: clock, policy: SamplingPolicy(), wallNow: {
        Date(timeIntervalSince1970: Double(clock.now) / 1_000_000_000)
    }, collect: { try await counter.collect() })
    _ = try await scheduler.freshSnapshot()
    await waitForTimer(clock)
    clock.advance(by: 1_000_000_000)
    await waitForSnapshot(scheduler, sequence: 2)
    let request = try LeaseRequest(kind: .guiWindow, intervalMS: .tenSeconds, processKeys: [first.processKey])
    let lease = try await scheduler.setLease(request, clientID: "gui-a")
    #expect(try await scheduler.history(series: first.processKey.rawValue).points.isEmpty)
    clock.advance(by: 1_000_000_000)
    _ = try await scheduler.freshSnapshot(maxAge: 0)
    #expect(try await scheduler.history(series: first.processKey.rawValue).points.map(\.t) == [Date(timeIntervalSince1970: 2)])
    let changed = try LeaseRequest(kind: .guiWindow, intervalMS: .tenSeconds, processKeys: [second.processKey])
    #expect(try await scheduler.setLease(changed, clientID: "gui-a").leaseID == lease.leaseID)
    clock.advance(by: 1_000_000_000)
    _ = try await scheduler.freshSnapshot(maxAge: 0)
    #expect(try await scheduler.history(series: first.processKey.rawValue).points.count == 1)
    #expect(try await scheduler.history(series: second.processKey.rawValue).points.map(\.t) == [Date(timeIntervalSince1970: 3)])
    _ = try await scheduler.setLease(request, clientID: "gui-a")
    clock.advance(by: 1_000_000_000)
    _ = try await scheduler.freshSnapshot(maxAge: 0)
    let resumed = try await scheduler.history(series: first.processKey.rawValue)
    #expect(resumed.points.map(\.t) == [Date(timeIntervalSince1970: 2), Date(timeIntervalSince1970: 4)])
    #expect(resumed.gaps == [HistoryGap(from: Date(timeIntervalSince1970: 2), to: Date(timeIntervalSince1970: 4))])
    _ = try await scheduler.setLease(LeaseRequest(kind: .guiWindow, intervalMS: .tenSeconds), clientID: "gui-a")
    clock.advance(by: 1_000_000_000)
    _ = try await scheduler.freshSnapshot(maxAge: 0)
    #expect(try await scheduler.history(series: first.processKey.rawValue).points.count == 2)
    #expect(try await scheduler.history(series: second.processKey.rawValue).points.count == 1)
    await scheduler.shutdown()
}

@Test(.timeLimit(.minutes(1)), arguments: ["release", "expiry", "disconnect"])
func guiLeaseEndUntracksHistory(reason: String) async throws {
    let clock = FakeClock()
    let process = try storeProcess()
    let counter = CountingCollect(clock: clock, processes: [process])
    let scheduler = try SamplingScheduler(clock: clock, policy: SamplingPolicy(), collect: { try await counter.collect() })
    let lease = try await scheduler.setLease(LeaseRequest(kind: .guiWindow, intervalMS: .tenSeconds, processKeys: [process.processKey]), clientID: "gui-a")
    _ = try await scheduler.freshSnapshot()
    await waitForTimer(clock)
    clock.advance(by: 1_000_000_000)
    await waitForSnapshot(scheduler, sequence: 2)
    let before = try await scheduler.history(series: process.processKey.rawValue).points
    switch reason {
    case "release": try await scheduler.releaseLease(id: lease.leaseID, clientID: "gui-a")
    case "disconnect": await scheduler.clientDisconnected("gui-a")
    default:
        clock.advance(by: 30_000_000_000)
        await scheduler.didWake()
    }
    clock.advance(by: 5_000_000_000)
    _ = try await scheduler.freshSnapshot(maxAge: 0)
    #expect(try await scheduler.history(series: process.processKey.rawValue).points == before)
    #expect(await scheduler.effectiveInterval == nil)
    await scheduler.shutdown()
}

@Test(.timeLimit(.minutes(1))) func guiLeaseRenewsTrackingDeadlineAndPreservesOtherOwners() async throws {
    let clock = FakeClock()
    let process = try storeProcess()
    let counter = CountingCollect(clock: clock, processes: [process])
    let scheduler = try SamplingScheduler(clock: clock, policy: SamplingPolicy(), collect: { try await counter.collect() })
    let request = try LeaseRequest(kind: .guiWindow, intervalMS: .tenSeconds, processKeys: [process.processKey])
    let lease = try await scheduler.setLease(request, clientID: "gui-a")
    _ = try await scheduler.freshSnapshot()
    clock.advance(by: 20_000_000_000)
    let renewed = try await scheduler.setLease(request, clientID: "gui-a")
    #expect(renewed.expiresAt > lease.expiresAt)
    clock.advance(by: 11_000_000_000)
    _ = try await scheduler.freshSnapshot(maxAge: 0)
    #expect(try await scheduler.history(series: process.processKey.rawValue).points.last?.t == Date(timeIntervalSince1970: 31))
    let observation = SamplingLease(leaseID: "obs-a", clientID: "mcp-a", kind: .observation, intervalMS: .tenSeconds, expiresAt: clock.now + 30_000_000_000)
    try await scheduler.startObservationLease(observation, keys: [process.processKey])
    try await scheduler.releaseLease(id: lease.leaseID, clientID: "gui-a")
    clock.advance(by: 5_000_000_000)
    _ = try await scheduler.freshSnapshot(maxAge: 0)
    #expect(try await scheduler.history(series: process.processKey.rawValue).points.last?.t == Date(timeIntervalSince1970: 36))
    try await scheduler.pin(key: process.processKey, pinned: true)
    try await scheduler.releaseLease(id: observation.leaseID, clientID: "mcp-a")
    clock.advance(by: 5_000_000_000)
    _ = try await scheduler.freshSnapshot(maxAge: 0)
    #expect(try await scheduler.history(series: process.processKey.rawValue).points.last?.t == Date(timeIntervalSince1970: 41))
    await scheduler.shutdown()
}

@Test(.timeLimit(.minutes(1))) func guiLeaseHistoryLimitFailurePreservesExistingTracking() async throws {
    let clock = FakeClock()
    let first = try storeProcess()
    let second = try storeProcess(pid: 43)
    let counter = CountingCollect(clock: clock, processes: [first, second])
    let scheduler = try SamplingScheduler(clock: clock, policy: SamplingPolicy(maxProcessSeries: 1), collect: { try await counter.collect() })
    try await scheduler.pin(key: first.processKey, pinned: true)
    let request = try LeaseRequest(kind: .guiWindow, intervalMS: .tenSeconds, processKeys: [first.processKey])
    let lease = try await scheduler.setLease(request, clientID: "gui-a")
    _ = try await scheduler.freshSnapshot()
    await #expect(throws: AgentError.historyLimitReached("Process history limit reached")) {
        try await scheduler.setLease(LeaseRequest(kind: .guiWindow, intervalMS: .oneSecond, processKeys: [second.processKey]), clientID: "gui-a")
    }
    #expect(await scheduler.effectiveInterval == .tenSeconds)
    clock.advance(by: 5_000_000_000)
    _ = try await scheduler.freshSnapshot(maxAge: 0)
    #expect(try await scheduler.history(series: first.processKey.rawValue).points.last?.t == Date(timeIntervalSince1970: 5))
    try await scheduler.releaseLease(id: lease.leaseID, clientID: "gui-a")
    await scheduler.shutdown()
}
