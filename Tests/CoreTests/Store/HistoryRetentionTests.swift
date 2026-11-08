import Foundation
import ProcglintCore
import Testing

@Test func absentTrackedIdentityRetainsItsEmptyHistory() throws {
    let clock = FakeClock()
    var history = try HistoryStore(clock: clock, policy: SamplingPolicy(), wallNow: {
        Date(timeIntervalSince1970: Double(clock.now) / 1_000_000_000)
    })
    let key = try storeProcess().processKey
    try history.track(keys: [key], owner: "obs-a", until: 2_000_000_000)
    history.record(storeSnapshot())
    clock.advance(by: 3_000_000_000)
    let absent = try history.series(key.rawValue)
    #expect(absent.points.isEmpty)
    #expect(absent.gaps == [HistoryGap(from: Date(timeIntervalSince1970: 0), to: Date(timeIntervalSince1970: 3))])
    clock.advance(by: 601_000_000_000)
    #expect(throws: AgentError.self) { try history.series(key.rawValue) }
}

@Test func gapsAreClippedToMonotonicRetentionAndObservationWindow() throws {
    let clock = FakeClock()
    var history = try HistoryStore(clock: clock, policy: SamplingPolicy(historyMinutes: 1), wallNow: {
        Date(timeIntervalSince1970: Double(clock.now) / 1_000_000_000)
    })
    history.record(storeSnapshot())
    history.recordGap()
    clock.advance(by: 120_000_000_000)
    let gap = try #require(history.series("system").gaps.first)
    #expect(gap.from == Date(timeIntervalSince1970: 60))
    #expect(gap.to == Date(timeIntervalSince1970: 120))
    history.record(storeSnapshot(2, tick: clock.now))
    let clipped = try history.series("system", fromTick: 80_000_000_000, throughTick: 100_000_000_000)
    #expect(clipped.points.isEmpty)
    #expect(clipped.gaps == [HistoryGap(from: Date(timeIntervalSince1970: 80), to: Date(timeIntervalSince1970: 100))])
}

@Test func multipleTrackingOwnersDoNotLoseSharedHistory() throws {
    let clock = FakeClock()
    var history = try HistoryStore(clock: clock, policy: SamplingPolicy())
    let process = try storeProcess()
    try history.track(keys: [process.processKey], owner: "obs-a", until: 5_000_000_000)
    try history.track(keys: [process.processKey], owner: "obs-b", until: 10_000_000_000)
    history.untrack(owner: "obs-a")
    clock.advance(by: 6_000_000_000)
    history.record(storeSnapshot(tick: clock.now, processes: [process]))
    #expect(try history.series(process.processKey.rawValue).points.count == 1)
    try history.pin(key: process.processKey, pinned: true)
    history.untrack(owner: "obs-b")
    clock.advance(by: 5_000_000_000)
    history.record(storeSnapshot(2, tick: clock.now, processes: [process]))
    #expect(try history.series(process.processKey.rawValue).points.count == 2)
}
