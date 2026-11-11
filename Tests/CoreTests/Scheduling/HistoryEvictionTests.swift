import Foundation
import ProcglintCore
import Testing

@Test(.timeLimit(.minutes(1)), arguments: [1, 16])
func sequentialGUISelectionsKeepAllSampledHistory(limit: Int) async throws {
    let clock = FakeClock()
    let processes = try (1 ... 20).map { try storeProcess(pid: Int32($0)) }
    let counter = CountingCollect(clock: clock, processes: processes)
    let scheduler = try SamplingScheduler(clock: clock, policy: SamplingPolicy(maxProcessSeries: limit), collect: { try await counter.collect() })
    var leaseID: String?
    for process in processes {
        let request = try LeaseRequest(kind: .guiWindow, intervalMS: .tenSeconds, processKeys: [process.processKey])
        let lease = try await scheduler.setLease(request, clientID: "gui-a")
        #expect(leaseID == nil || leaseID == lease.leaseID)
        leaseID = lease.leaseID
        clock.advance(by: 1_000_000_000)
        _ = try await scheduler.freshSnapshot(maxAge: 0)
    }
    for process in processes {
        #expect(try await scheduler.history(series: process.processKey.rawValue).points.count == 20)
    }
    await scheduler.shutdown()
}

@Test func explicitOwnershipLimitNeverEvictsAutomaticallyRecordedHistory() throws {
    let clock = FakeClock()
    let processes = try (1 ... 6).map { try storeProcess(pid: Int32($0)) }
    let keys = processes.map(\.processKey)
    var history = try HistoryStore(clock: clock, policy: SamplingPolicy(maxProcessSeries: 2))
    history.record(storeSnapshot(processes: processes))
    try history.pin(key: keys[0], pinned: true)
    try history.track(keys: [keys[1]], owner: "window", until: 100_000_000_000)
    #expect(throws: AgentError.historyLimitReached("Process history limit reached")) {
        try history.track(keys: [keys[2]], owner: "other", until: 100_000_000_000)
    }
    #expect(throws: AgentError.self) { try history.setPolicy(SamplingPolicy(maxProcessSeries: 1)) }
    // Replacement is atomic and may reuse the slot; it must not erase any sampled series.
    try history.track(keys: [keys[2]], owner: "window", until: 100_000_000_000)
    history.untrack(owner: "window")
    try history.setPolicy(SamplingPolicy(maxProcessSeries: 1))
    for key in keys {
        #expect(try history.series(key.rawValue).points.count == 1)
    }
    clock.advance(by: 1_000_000_000)
    history.record(storeSnapshot(2, tick: clock.now, processes: processes))
    for key in keys {
        let series = try history.series(key.rawValue)
        #expect(series.points.count == 2)
        #expect(series.gaps.isEmpty)
    }
}
