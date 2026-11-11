import Foundation
import ProcglintCore
import Testing

@Test func historyCapsAndReusedStorage() throws {
    let clock = FakeClock()
    var history = try HistoryStore(clock: clock, policy: SamplingPolicy(), wallNow: {
        Date(timeIntervalSince1970: Double(clock.now) / 1_000_000_000)
    })
    let process = try storeProcess()
    try history.pin(key: process.processKey, pinned: true)
    for index in 0 ..< 700 {
        history.record(storeSnapshot(index, tick: clock.now, processes: [process]))
        clock.advance(by: 500_000_000)
    }
    let series = try history.series(process.processKey.rawValue)
    #expect(series.points.count == 600)
    #expect(series.points.first?.t == Date(timeIntervalSince1970: 50))
    #expect(try history.series("system").points.count == 600)
    let fullBytes = history.bytesEstimate()
    history.record(storeSnapshot(701, tick: clock.now, processes: [process]))
    #expect(history.bytesEstimate() == fullBytes)
    #expect(fullBytes < 8 * 1024 * 1024)
    clock.advance(by: 601_000_000_000)
    #expect(try history.series(process.processKey.rawValue).points.isEmpty)
    #expect(try history.series("system").points.isEmpty)
}

@Test func historyLimitsAndAtomicReservation() throws {
    let clock = FakeClock()
    var history = try HistoryStore(clock: clock, policy: SamplingPolicy(maxProcessSeries: 2))
    let first = try storeProcess(pid: 1)
    let second = try storeProcess(pid: 2)
    let third = try storeProcess(pid: 3)
    try history.pin(key: first.processKey, pinned: true)
    #expect(throws: AgentError.historyLimitReached("Process history limit reached")) {
        try history.track(keys: [second.processKey, third.processKey], owner: "obs-a", until: 10_000_000_000)
    }
    try history.track(keys: [first.processKey, second.processKey], owner: "obs-b", until: 10_000_000_000)
    history.record(storeSnapshot(processes: [first, second, third]))
    #expect(try history.series(first.processKey.rawValue).points.count == 1)
    #expect(try history.series(third.processKey.rawValue).points.count == 1)
    #expect(throws: AgentError.self) { try history.setPolicy(SamplingPolicy(maxProcessSeries: 1)) }
    history.untrack(owner: "obs-b")
    clock.advance(by: 601_000_000_000)
    try history.pin(key: third.processKey, pinned: true)
    #expect(history.pinned == [first.processKey, third.processKey])
    try history.pin(key: first.processKey, pinned: false)
    try history.setPolicy(SamplingPolicy(historyMinutes: 1, maxProcessSeries: 1))
    history.record(storeSnapshot(2, tick: clock.now, processes: [third]))
    clock.advance(by: 61_000_000_000)
    #expect(try history.series(third.processKey.rawValue).points.isEmpty)
}

@Test func historyGapsAndPIDReuse() throws {
    let clock = FakeClock()
    var history = try HistoryStore(clock: clock, policy: SamplingPolicy(), wallNow: {
        Date(timeIntervalSince1970: Double(clock.now) / 1_000_000_000)
    })
    let original = try storeProcess()
    let replacement = try storeProcess(start: 99)
    try history.pin(key: original.processKey, pinned: true)
    history.record(storeSnapshot(processes: [original]))
    clock.advance(by: 1_000_000_000)
    history.record(storeSnapshot(2, tick: clock.now, processes: [replacement]))
    #expect(try history.series(original.processKey.rawValue).points.count == 1)
    #expect(try history.series(replacement.processKey.rawValue).points.count == 1)
    clock.advance(by: 1_000_000_000)
    history.record(storeSnapshot(3, tick: clock.now, processes: [original]))
    let resumed = try history.series(original.processKey.rawValue)
    #expect(resumed.points.count == 2)
    #expect(resumed.gaps == [HistoryGap(from: Date(timeIntervalSince1970: 0), to: Date(timeIntervalSince1970: 2))])
    history.recordGap()
    clock.advance(by: 10_000_000_000)
    history.record(storeSnapshot(4, tick: clock.now, processes: [original]))
    #expect(try history.series("system").gaps == [HistoryGap(from: Date(timeIntervalSince1970: 2), to: Date(timeIntervalSince1970: 12))])
    try history.pin(key: original.processKey, pinned: false)
    clock.advance(by: 1_000_000_000)
    history.record(storeSnapshot(5, tick: clock.now, processes: [original]))
    #expect(try history.series(original.processKey.rawValue).points.count == 4)
    try history.track(keys: [original.processKey], owner: "obs-a", until: clock.now + 2_000_000_000)
    clock.advance(by: 1_000_000_000)
    history.record(storeSnapshot(6, tick: clock.now, processes: [original]))
    clock.advance(by: 2_000_000_000)
    history.record(storeSnapshot(7, tick: clock.now, processes: [original]))
    let expired = try history.series(original.processKey.rawValue)
    #expect(expired.points.count == 6)
    #expect(expired.gaps.count == 2)
    let clipped = try history.series(original.processKey.rawValue, since: Date(timeIntervalSince1970: 13), until: Date(timeIntervalSince1970: 15))
    #expect(clipped.points.count == 2)
    #expect(clipped.gaps.allSatisfy { $0.from >= Date(timeIntervalSince1970: 13) && $0.to <= Date(timeIntervalSince1970: 15) })
}

@Test func unavailableSnapshotDoesNotMeanAllExited() throws {
    let clock = FakeClock()
    var history = try HistoryStore(clock: clock, policy: SamplingPolicy())
    let process = try storeProcess()
    try history.pin(key: process.processKey, pinned: true)
    history.record(storeSnapshot(processes: [process]))
    var failed = storeSnapshot(2)
    failed.status = .unavailable
    clock.advance(by: 1_000_000_000)
    history.record(failed)
    #expect(try history.series(process.processKey.rawValue).points.count == 1)
    #expect(try history.series("system").points.count == 1)
    #expect(try history.series(process.processKey.rawValue).gaps.count == 1)
}
