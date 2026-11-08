import Darwin
import Foundation
@testable import ProcglintCore
import Synchronization
import Testing

private func milliseconds(since start: UInt64) -> Double {
    Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
}

private func p95(_ values: [Double]) -> Double {
    values.sorted()[Int(ceil(Double(values.count) * 0.95)) - 1]
}

private func populatedSource(count: Int = 500) -> FakeProcessSource {
    let source = FakeProcessSource()
    source.update { state in
        for index in 1 ... count {
            let pid = Int32(index + 100)
            let start = UInt64(index) * 1_000_000
            state.processes[pid] = FakeProcessSource.Process(
                rusage: RawRusage(cpuTimeNS: UInt64(index) * 1000, footprintBytes: 4096, rssBytes: 8192,
                                  diskReadBytes: 100, diskWrittenBytes: 200, startTimeUS: start),
                bsdInfo: RawBSDInfo(name: "worker-\(index)", uid: 501, ppid: 1, startTimeUS: start), path: "/fake/worker"
            )
        }
    }
    return source
}

private final class CountingSource: ProcessSource {
    struct Counts: Equatable {
        var lists = 0
        var bsd = 0
        var usage = 0
        var paths = 0
        var host = 0
        var vm = 0
    }

    let fake = populatedSource()
    private let counts = Mutex(Counts())
    var calls: Counts {
        counts.withLock { $0 }
    }

    var physicalMemory: UInt64 {
        fake.physicalMemory
    }

    var pageSize: UInt64 {
        fake.pageSize
    }

    var machTimebase: MachTimebase {
        fake.machTimebase
    }

    func bootSessionID() -> String {
        fake.bootSessionID()
    }

    func listPIDs() throws -> [Int32] {
        counts.withLock { $0.lists += 1 }
        return try fake.listPIDs()
    }

    func bsdInfo(pid: Int32) throws -> RawBSDInfo? {
        counts.withLock { $0.bsd += 1 }
        return try fake.bsdInfo(pid: pid)
    }

    func rusage(pid: Int32) throws -> RawRusage? {
        counts.withLock { $0.usage += 1 }
        return try fake.rusage(pid: pid)
    }

    func path(pid: Int32) throws -> String? {
        counts.withLock { $0.paths += 1 }
        return try fake.path(pid: pid)
    }

    func hostCPUTicks() -> RawCPUTicks {
        counts.withLock { $0.host += 1 }
        return fake.hostCPUTicks()
    }

    func vmStatistics() -> RawVMStatistics {
        counts.withLock { $0.vm += 1 }
        return fake.vmStatistics()
    }
}

struct PerformanceRegressionTests {
    @Test func oneBSDAndOneRusagePerProcessNoEagerPaths() async throws {
        let source = CountingSource()
        let sampler = try Sampler(source: source, clock: FakeClock(), agentUID: 501)
        for _ in 0 ..< 3 {
            _ = try await sampler.sample()
        }
        // Darwin rusage adds one post-counter BSD check; this guards the sampler-facing call budget.
        #expect(source.calls == CountingSource.Counts(lists: 3, bsd: 1500, usage: 1500, paths: 0, host: 3, vm: 3))
        #expect(await sampler.cachedProcessCount == 500)
        #expect(await sampler.cachedUserCount == 1)
    }

    @Test func mismatchedPostRusageIdentityNeverProducesARow() async throws {
        let source = CountingSource()
        source.fake.update { $0.processes[101]?.rusage.startTimeUS = 2_000_000 }
        let sampler = try Sampler(source: source, clock: FakeClock())
        let snapshot = try await sampler.sample()
        #expect(snapshot.coverage.exitedDuringSample == 1)
        #expect(!snapshot.processes.contains { $0.pid == 101 })
    }
}

@Suite(.enabled(if: ProcessInfo.processInfo.environment["PROCGLINT_PERF"] == "1"), .serialized)
struct PerformanceMeasurements {
    @Test func realOSSweep() async throws {
        let sampler = try Sampler(source: DarwinProcessSource(), clock: SystemMonotonicClock())
        _ = try await sampler.sample()
        var durations: [Double] = []
        var readable: [Int] = []
        var enumerated: [Int] = []
        for _ in 0 ..< 50 {
            let start = DispatchTime.now().uptimeNanoseconds
            let snapshot = try await sampler.sample()
            durations.append(milliseconds(since: start))
            readable.append(snapshot.coverage.sampled)
            enumerated.append(snapshot.coverage.enumerated)
            #expect(snapshot.processes.contains { $0.pid == getpid() })
        }
        let percentile = p95(durations)
        print("PERF sweep n=50 p95_ms=\(percentile) mean_ms=\(durations.reduce(0, +) / 50) readable=\(readable.min()!)...\(readable.max()!) enumerated=\(enumerated.min()!)...\(enumerated.max()!)")
        #if DEBUG
            print("PERF Debug build: reporting only; the 40 ms budget applies to Release")
        #else
            #expect(percentile <= 40, "Release collection p95 must be <= 40 ms")
        #endif
    }

    @Test func storeAndJSON() async throws {
        let clock = FakeClock()
        let sampler = try Sampler(source: populatedSource(), clock: clock, agentUID: 501)
        _ = try await sampler.sample()
        clock.advance(by: 5_000_000_000)
        var snapshot = try await sampler.sample()
        snapshot.sampledAt = Date(timeIntervalSince1970: 1000)
        var store = SnapshotStore(clock: clock)
        store.insert(snapshot)
        let query = try ProcessQuery(filter: .all, limit: 200)
        var queryTimes: [Double] = []
        var encodingTimes: [Double] = []
        var bytes = 0
        for _ in 0 ..< 50 {
            let start = DispatchTime.now().uptimeNanoseconds
            let page = try store.listProcesses(query, scope: AccessScope(includeSystem: true))
            queryTimes.append(milliseconds(since: start))
            #expect(page.totalMatched == 500)
            #expect(page.items.count == 200)
            let encodingStart = DispatchTime.now().uptimeNanoseconds
            let data = try ProcglintJSON.encoder().encode(page)
            encodingTimes.append(milliseconds(since: encodingStart))
            bytes = data.count
            #expect(try ProcglintJSON.decoder().decode(ProcessPage.self, from: data) == page)
        }
        print("PERF store rows=500 page=200 n=50 query_p95_ms=\(p95(queryTimes)) json_bytes=\(bytes) encode_p95_ms=\(p95(encodingTimes))")
    }

    @Test func historyAtFullCaps() async throws {
        let clock = FakeClock()
        let sampler = try Sampler(source: populatedSource(count: 16), clock: clock, agentUID: 501)
        let snapshot = try await sampler.sample()
        var history = try HistoryStore(clock: clock, policy: SamplingPolicy())
        for process in snapshot.processes {
            try history.pin(key: process.processKey, pinned: true)
        }
        for _ in 0 ..< 600 {
            history.record(snapshot)
            clock.advance(by: 1_000_000_000)
        }
        for name in ["system"] + snapshot.processes.map(\.processKey.rawValue) {
            #expect(try history.series(name).points.count == 600)
        }
        let bytes = history.bytesEstimate()
        print("PERF history series=17 points_per_series=600 estimated_bytes=\(bytes)")
        #expect(bytes <= 8 * 1024 * 1024)
    }
}
