import Foundation
@testable import ProcglintCore
import Testing

@Test func unselectedCensusHistoryPreservesEveryProcessMetricAndStatus() throws {
    let clock = FakeClock()
    var store = try HistoryStore(clock: clock, policy: SamplingPolicy(maxProcessSeries: 1))
    var process = try storeProcess()
    for (index, status) in MetricStatus.allCases.enumerated() {
        let metric = try Metric(value: status == .ok ? 12.3456789 : nil, status: status)
        process.cpuPercent = metric
        process.footprintBytes = metric
        process.diskReadBps = metric
        process.diskWriteBps = metric
        process.powerMW = metric
        process.networkReceiveBps = metric
        process.networkSendBps = metric
        store.record(storeSnapshot(index, tick: clock.now, processes: [process]))
        clock.advance(by: 1_000_000_000)
    }
    let series = try store.series(process.processKey.rawValue)
    #expect(series.points.count == MetricStatus.allCases.count)
    for (point, status) in zip(series.points, MetricStatus.allCases) {
        let metrics = [point.cpuPercent, point.footprintBytes, point.diskReadBps, point.diskWriteBps,
                       point.powerMW, point.networkReceiveBps, point.networkSendBps]
        #expect(metrics.allSatisfy { $0?.status == status })
        if status == .ok {
            #expect(metrics.allSatisfy { abs(($0?.value ?? 0) - 12.3456789) < 0.00001 })
        } else {
            #expect(metrics.allSatisfy { $0?.value == nil })
        }
        #expect(point.memoryUsedBytes == nil && point.systemPowerMW == nil && point.batteryPercent == nil)
    }
    #expect(store.isOwnProcess(process.processKey) == process.isOwn)
    let cursor = try #require(series.nextCursor)
    store.record(storeSnapshot(10, tick: clock.now, processes: [process]))
    let delta = try store.series(process.processKey.rawValue).delta(after: cursor)
    #expect(delta.isDelta && delta.points.count == 1)
}

@Test func exitedUnselectedSeriesExpiresByNewestPointNotByGapOrQuery() throws {
    let clock = FakeClock()
    var store = try HistoryStore(clock: clock, policy: SamplingPolicy(historyMinutes: 1))
    let original = try storeProcess()
    let reused = try storeProcess(start: 99)
    store.record(storeSnapshot(processes: [original]))
    clock.advance(by: 30_000_000_000)
    store.record(storeSnapshot(2, tick: clock.now, processes: [original]))
    clock.advance(by: 30_000_000_000)
    store.record(storeSnapshot(3, tick: clock.now, processes: [reused]))
    #expect(try store.series(original.processKey.rawValue).points.count == 2)
    clock.advance(by: 1_000_000_000)
    #expect(try store.series(original.processKey.rawValue).points.count == 1)
    #expect(try store.series(original.processKey.rawValue).gaps.count == 1)
    clock.advance(by: 30_000_000_000)
    #expect(throws: AgentError.self) { try store.series(original.processKey.rawValue) }
    #expect(store.isOwnProcess(original.processKey) == nil)
    #expect(try store.series(reused.processKey.rawValue).points.count == 1)
    #expect(try store.series("system").points.count == 1)
}

@Test func nineHundredProcessHistoryUsesCompactBoundedStorage() throws {
    let clock = FakeClock()
    let processes = try (1 ... 900).map { try storeProcess(pid: Int32($0)) }
    var store = try HistoryStore(clock: clock, policy: SamplingPolicy())
    for index in 0 ..< 120 {
        store.record(storeSnapshot(index, tick: clock.now, processes: processes))
        clock.advance(by: 5_000_000_000)
    }
    let bytes = store.bytesEstimate()
    #expect(MemoryLayout<CompactProcessPoint>.stride <= 48)
    #expect(bytes < 8 * 1024 * 1024)
    #expect(try store.series(processes[899].processKey.rawValue).points.count == 120)
    // Long-running live identities reuse the same rings rather than growing each window.
    for index in 120 ..< 250 {
        store.record(storeSnapshot(index, tick: clock.now, processes: processes))
        clock.advance(by: 5_000_000_000)
    }
    #expect(store.bytesEstimate() == bytes)
    clock.advance(by: 601_000_000_000)
    store.record(storeSnapshot(251, tick: clock.now))
    #expect(store.bytesEstimate() < 1024 * 1024)
}
