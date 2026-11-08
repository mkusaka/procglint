import Foundation
import ProcglintCore
import Testing

@Test(.timeLimit(.minutes(1)), arguments: [1, 16])
func sequentialGUISelectionsReuseHistorySlots(limit: Int) async throws {
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
        let selected = try await scheduler.history(series: process.processKey.rawValue)
        #expect(!selected.points.isEmpty)
    }
    var retained: [ProcessKey] = []
    for process in processes where await (try? scheduler.history(series: process.processKey.rawValue)) != nil {
        retained.append(process.processKey)
    }
    #expect(retained == processes.suffix(limit).map(\.processKey))
    #expect(try await scheduler.history(series: "system").points.count > 0)
    await scheduler.shutdown()
}

@Test func historyEvictionProtectsPinsAndAllOtherTrackingOwners() throws {
    let clock = FakeClock()
    let processes = try (1 ... 6).map { try storeProcess(pid: Int32($0)) }
    let keys = processes.map(\.processKey)
    var history = try HistoryStore(clock: clock, policy: SamplingPolicy(maxProcessSeries: 4))
    try history.pin(key: keys[0], pinned: true)
    try history.track(keys: [keys[1]], owner: "obs-a", until: 100_000_000_000)
    try history.track(keys: [keys[2]], owner: "other-window", until: 100_000_000_000)
    try history.track(keys: [keys[3]], owner: "window", until: 100_000_000_000)
    history.record(storeSnapshot(processes: processes))
    try history.track(keys: [keys[4]], owner: "window", until: 100_000_000_000)
    #expect(throws: AgentError.notFound("History series is not retained")) { try history.series(keys[3].rawValue) }
    for key in keys.prefix(3) {
        #expect(try history.series(key.rawValue).points.count == 1)
    }
    try history.track(keys: [keys[4]], owner: "obs-shared", until: 100_000_000_000)
    #expect(throws: AgentError.historyLimitReached("Process history limit reached")) {
        try history.track(keys: [keys[5]], owner: "window", until: 100_000_000_000)
    }
    #expect(throws: AgentError.historyLimitReached("Process history limit reached")) {
        try history.pin(key: keys[5], pinned: true)
    }
    history.untrack(owner: "obs-shared")
    clock.advance(by: 1_000_000_000)
    history.record(storeSnapshot(2, tick: clock.now, processes: processes))
    #expect(try history.series(keys[4].rawValue).points.count == 1)
    for key in keys.prefix(3) {
        #expect(try history.series(key.rawValue).points.count == 2)
    }
}

@Test func historyEvictsOldestUntrackedRatherThanOldestSampleOrCreation() throws {
    let clock = FakeClock()
    let processes = try (1 ... 6).map { try storeProcess(pid: Int32($0)) }
    let keys = processes.map(\.processKey)
    var history = try HistoryStore(clock: clock, policy: SamplingPolicy(maxProcessSeries: 3))
    for index in 0 ..< 3 {
        try history.track(keys: [keys[index]], owner: "owner-\(index)", until: 100_000_000_000)
        clock.advance(by: 1_000_000_000)
    }
    history.record(storeSnapshot(tick: clock.now, processes: processes))
    history.untrack(owner: "owner-1")
    clock.advance(by: 1_000_000_000)
    history.untrack(owner: "owner-0")
    clock.advance(by: 1_000_000_000)
    history.untrack(owner: "owner-2")
    clock.advance(by: 1_000_000_000)
    try history.pin(key: keys[0], pinned: true)
    clock.advance(by: 1_000_000_000)
    try history.pin(key: keys[0], pinned: false)
    for key in keys.prefix(3) {
        #expect(try history.series(key.rawValue).points.count == 1)
    }
    try history.track(keys: [keys[3]], owner: "window", until: 100_000_000_000)
    #expect(throws: AgentError.notFound("History series is not retained")) { try history.series(keys[1].rawValue) }
    #expect(try history.series(keys[0].rawValue).points.count == 1)
    #expect(try history.series(keys[2].rawValue).points.count == 1)
    try history.pin(key: keys[4], pinned: true)
    #expect(throws: AgentError.notFound("History series is not retained")) { try history.series(keys[2].rawValue) }
    #expect(try history.series(keys[0].rawValue).points.count == 1)
    try history.track(keys: [keys[5]], owner: "second-window", until: 100_000_000_000)
    #expect(throws: AgentError.notFound("History series is not retained")) { try history.series(keys[0].rawValue) }
}

@Test func historyReservationProtectsRequestedRetainedSeriesAndIsAtomic() throws {
    let clock = FakeClock()
    let processes = try (1 ... 5).map { try storeProcess(pid: Int32($0)) }
    let keys = processes.map(\.processKey)
    var history = try HistoryStore(clock: clock, policy: SamplingPolicy(maxProcessSeries: 2))
    try history.track(keys: [keys[0]], owner: "first", until: 100_000_000_000)
    try history.track(keys: [keys[1]], owner: "second", until: 100_000_000_000)
    history.record(storeSnapshot(processes: processes))
    history.untrack(owner: "first")
    clock.advance(by: 1_000_000_000)
    history.untrack(owner: "second")
    #expect(throws: AgentError.historyLimitReached("Process history limit reached")) {
        try history.track(keys: Array(keys.suffix(3)), owner: "window", until: 100_000_000_000)
    }
    for key in keys.prefix(2) {
        #expect(try history.series(key.rawValue).points.count == 1)
    }
    try history.track(keys: [keys[0], keys[2]], owner: "window", until: 100_000_000_000)
    #expect(try history.series(keys[0].rawValue).points.count == 1)
    #expect(try history.series(keys[2].rawValue).points.isEmpty)
    #expect(throws: AgentError.notFound("History series is not retained")) { try history.series(keys[1].rawValue) }
}

@Test func expiredHistoryOwnersUseTheirLastDeadlineForEvictionOrder() throws {
    let clock = FakeClock()
    let processes = try (1 ... 3).map { try storeProcess(pid: Int32($0)) }
    let keys = processes.map(\.processKey)
    var history = try HistoryStore(clock: clock, policy: SamplingPolicy(maxProcessSeries: 2))
    try history.track(keys: [keys[0]], owner: "later", until: 20_000_000_000)
    try history.track(keys: [keys[1]], owner: "earlier", until: 10_000_000_000)
    try history.track(keys: [keys[1]], owner: "shared", until: 15_000_000_000)
    history.record(storeSnapshot(processes: processes))
    clock.advance(by: 30_000_000_000)
    try history.track(keys: [keys[2]], owner: "window", until: 100_000_000_000)
    #expect(throws: AgentError.notFound("History series is not retained")) { try history.series(keys[1].rawValue) }
    #expect(try history.series(keys[0].rawValue).points.count == 1)
    #expect(try history.series(keys[2].rawValue).points.isEmpty)
}
