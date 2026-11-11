import Foundation
import ProcglintCore
import Testing

@Test func historyCursorAppendsEvenWhenCaptureClocksAndValuesAreIdentical() throws {
    let clock = FakeClock()
    var store = try HistoryStore(clock: clock, policy: SamplingPolicy())
    store.record(storeSnapshot())
    let initial = try store.series("system").delta(after: "")
    #expect(!initial.isDelta)
    #expect(initial.retainedPointCount == 1)
    let cursor = try #require(initial.nextCursor)
    store.record(storeSnapshot())
    let delta = try store.series("system").delta(after: cursor)
    #expect(delta.isDelta)
    #expect(delta.points.count == 1)
    #expect(delta.retainedPointCount == 2)
    let empty = try store.series("system").delta(after: delta.nextCursor)
    #expect(empty.isDelta)
    #expect(empty.points.isEmpty)
    #expect(try store.series("system").delta(after: nil).nextCursor == nil)
}

@Test func historyCursorResetsAfterEvictionRestartUnknownTokenOrGap() throws {
    let clock = FakeClock()
    var store = try HistoryStore(clock: clock, policy: SamplingPolicy())
    store.record(storeSnapshot())
    let cursor = try #require(try store.series("system").nextCursor)
    for _ in 0 ..< 601 {
        store.record(storeSnapshot())
    }
    let evicted = try store.series("system").delta(after: cursor)
    #expect(!evicted.isDelta)
    #expect(evicted.points.count == 600)
    #expect(try !store.series("system").delta(after: "unknown").isDelta)
    var restarted = try HistoryStore(clock: clock, policy: SamplingPolicy())
    restarted.record(storeSnapshot())
    #expect(try !restarted.series("system").delta(after: cursor).isDelta)
    let current = try #require(evicted.nextCursor)
    store.recordGap()
    #expect(try !store.series("system").delta(after: current).isDelta)
    store.record(storeSnapshot())
    let resumed = try store.series("system").delta(after: current)
    #expect(!resumed.isDelta)
    #expect(resumed.gaps.count == 0) // Zero-duration gaps still invalidate the cursor.
}

@Test func historyCursorRejectsAnEvictedAndRecreatedProcessBuffer() throws {
    let clock = FakeClock()
    var store = try HistoryStore(clock: clock, policy: SamplingPolicy(maxProcessSeries: 1))
    let first = try storeProcess(pid: 1)
    try store.track(keys: [first.processKey], owner: "owner-a", until: 1_000_000_000)
    store.record(storeSnapshot(processes: [first]))
    let cursor = try #require(try store.series(first.processKey.rawValue).nextCursor)
    store.untrack(owner: "owner-a")
    clock.advance(by: 601_000_000_000)
    #expect(throws: AgentError.self) { try store.series(first.processKey.rawValue) }
    try store.track(keys: [first.processKey], owner: "owner-a", until: clock.now + 1_000_000_000)
    store.record(storeSnapshot(tick: clock.now, processes: [first]))
    let recreated = try store.series(first.processKey.rawValue).delta(after: cursor)
    #expect(!recreated.isDelta)
    #expect(recreated.points.count == 1)
}

@Test func historyCursorDoesNotAppendAcrossChangedDateFiltersOrNoncontiguousResults() throws {
    let clock = FakeClock()
    var store = try HistoryStore(clock: clock, policy: SamplingPolicy())
    for date in [1, 10, 2] {
        var snapshot = storeSnapshot()
        snapshot.sampledAt = Date(timeIntervalSince1970: Double(date))
        store.record(snapshot)
    }
    let cursor = try #require(try store.series("system", since: Date(timeIntervalSince1970: 5)).nextCursor)
    #expect(try !store.series("system").delta(after: cursor).isDelta)
    var snapshot = storeSnapshot()
    snapshot.sampledAt = Date(timeIntervalSince1970: 11)
    store.record(snapshot)
    let filtered = try store.series("system", since: Date(timeIntervalSince1970: 5)).delta(after: cursor)
    #expect(!filtered.isDelta)
    #expect(filtered.nextCursor == nil)
    #expect(filtered.points.count == 2)
}

@Test func historyCursorWireExtensionIsOptInAndValidatesDeltaMetadata() throws {
    let full = HistorySeries(series: "system", points: [])
    let json = try ProcglintJSON.encoder().encode(full)
    #expect(String(data: json, encoding: .utf8) == #"{"gaps":[],"points":[],"series":"system"}"#)
    #expect(try ProcglintJSON.decoder().decode(HistorySeries.self, from: json) == full)
    let request = HistoryRequest(series: ["system"], cursor: "cursor-a")
    #expect(try ProcglintJSON.decoder().decode(HistoryRequest.self, from: ProcglintJSON.encoder().encode(request)) == request)
    let invalid = Data(#"{"series":"system","points":[],"gaps":[],"is_delta":true}"#.utf8)
    #expect(throws: DecodingError.self) { try ProcglintJSON.decoder().decode(HistorySeries.self, from: invalid) }
    #expect(throws: EncodingError.self) {
        try ProcglintJSON.encoder().encode(HistorySeries(series: "system", points: [], isDelta: true))
    }
    let oversized = HistorySeries(series: "system", points: [], nextCursor: "cursor-a", isDelta: true, retainedPointCount: 601)
    #expect(throws: EncodingError.self) { try ProcglintJSON.encoder().encode(oversized) }
}
