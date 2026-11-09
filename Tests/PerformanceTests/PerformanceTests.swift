import Darwin
import Foundation
@testable import ProcglintCore
import ProcglintIPC
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

private final class CountingSource: SamplingProcessSource {
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
    let usageDenied = Mutex<Set<Int32>>([])
    let startStamps = Mutex<[Int32: UInt64]>([:])
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

    func processCensus() throws -> [SamplingProcess] {
        let pids = try listPIDs()
        let state = fake.state
        return pids.compactMap { pid in
            state.processes[pid].map {
                var bsd = $0.bsdInfo
                bsd.name = String(bsd.name.prefix(16))
                return SamplingProcess(pid: pid, bsd: bsd)
            }
        }
    }

    func bsdInfo(pid: Int32) throws -> RawBSDInfo? {
        counts.withLock { $0.bsd += 1 }
        return try fake.bsdInfo(pid: pid)
    }

    func rusage(pid: Int32) throws -> RawRusage? {
        counts.withLock { $0.usage += 1 }
        if usageDenied.withLock({ $0.contains(pid) }) {
            throw ProcessSourceError.permissionDenied
        }
        return try fake.rusage(pid: pid)
    }

    func samplingUsage(pid: Int32, startTimeUS _: UInt64) throws -> SamplingUsage {
        guard let usage = try rusage(pid: pid) else { throw ProcessSourceError.exited }
        return SamplingUsage(usage: usage, startAbstime: startStamps.withLock { $0[pid] } ?? usage.startTimeUS)
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
    @Test func oneRusagePerKnownPIDAndBSDOnlyForNewIdentities() async throws {
        let source = CountingSource()
        let sampler = try Sampler(source: source, clock: FakeClock(), agentUID: 501)
        for _ in 0 ..< 3 {
            _ = try await sampler.sample()
        }
        // New identities are bracketed BSD → rusage → BSD; known identities compare raw start stamps.
        #expect(source.calls == CountingSource.Counts(lists: 3, bsd: 1000, usage: 1500, paths: 0, host: 3, vm: 3))
        #expect(await sampler.cachedProcessCount == 500)
        #expect(await sampler.cachedUserCount == 1)
    }

    @Test func deniedIdentitiesRetryOnTwelfthSweepOrIdentityChange() async throws {
        let source = CountingSource()
        source.fake.update { $0.processes = [101: $0.processes[101]!] }
        _ = source.usageDenied.withLock { $0.insert(101) }
        let sampler = try Sampler(source: source, clock: FakeClock())
        let first = try await sampler.sample()
        #expect(first.processes.first?.status == .permissionDenied)
        #expect(source.calls.usage == 1)
        for _ in 0 ..< 11 {
            let denied = try await sampler.sample()
            #expect(denied.coverage.permissionDenied == 1)
            #expect(denied.processes.first?.footprintBytes == .permissionDenied)
        }
        #expect(source.calls.usage == 1)
        _ = try await sampler.sample()
        #expect(source.calls.usage == 2)
        source.fake.update {
            $0.processes[101]?.bsdInfo.startTimeUS = 2_000_000
            $0.processes[101]?.rusage.startTimeUS = 2_000_000
        }
        _ = source.usageDenied.withLock { $0.remove(101) }
        let replacement = try await sampler.sample()
        #expect(replacement.processes.first?.status == .ok)
        #expect(replacement.processes.first?.cpuPercent == .warmingUp)
        #expect(replacement.processes.first?.processKey != first.processes.first?.processKey)
        #expect(source.calls.usage == 3)
    }

    @Test func changedRawStampRebracketsEvenWhenWallMicrosecondsCollide() async throws {
        let source = CountingSource()
        source.fake.update { $0.processes = [101: $0.processes[101]!] }
        let clock = FakeClock()
        let sampler = try Sampler(source: source, clock: clock)
        _ = try await sampler.sample()
        source.startStamps.withLock { $0[101] = 7 }
        source.fake.update { $0.processes[101]?.rusage.cpuTimeNS += 1_000_000_000 }
        clock.advance(by: 1_000_000_000)
        let row = try await sampler.sample().processes.first
        #expect(source.calls.bsd == 4)
        #expect(source.calls.usage == 3)
        #expect(row?.cpuPercent == .warmingUp)
        let foreignBoot = try ProcessKey("p1.other-boot.101.1000000")
        await #expect(throws: ProcessSourceError.exited) { try await sampler.path(for: foreignBoot) }
    }

    @Test func rawStampReuseAndExecNeverReuseMetadataOrDeltas() async throws {
        let source = CountingSource()
        source.fake.update {
            $0.processes = [101: $0.processes[101]!]
            $0.processes[101]?.bsdInfo.name = "worker-with-a-long-original-name"
        }
        let sampler = try Sampler(source: source, clock: FakeClock())
        let first = try await sampler.sample()
        let key = try #require(first.processes.first?.processKey)
        #expect(try await sampler.path(for: key) == "/fake/worker")
        source.fake.update {
            $0.processes[101]?.rusage.executableUUID = UUID()
            $0.processes[101]?.bsdInfo.name = "worker-with-a-long-replaced-name"
            $0.processes[101]?.path = "/fake/exec"
        }
        let exec = try await sampler.sample()
        #expect(first.processes.first?.name == "worker-with-a-long-original-name")
        #expect(exec.processes.first?.name == "worker-with-a-long-replaced-name")
        #expect(exec.processes.first?.cpuPercent == .warmingUp)
        #expect(try await sampler.path(for: key) == "/fake/exec")
        source.fake.update {
            $0.processes[101]?.bsdInfo.startTimeUS = 3_000_000
            $0.processes[101]?.rusage.startTimeUS = 3_000_000
        }
        let replaced = try await sampler.sample()
        #expect(replaced.processes.first?.processKey != key)
        #expect(replaced.processes.first?.cpuPercent == .warmingUp)
        await #expect(throws: ProcessSourceError.exited) { try await sampler.path(for: key) }
    }

    @Test func censusListsBSDDeniedRowsAndRefreshesUIDAndParent() async throws {
        let source = CountingSource()
        source.fake.update {
            $0.processes = [101: $0.processes[101]!]
            $0.processErrors[101] = .permissionDenied
        }
        let sampler = try Sampler(source: source, clock: FakeClock(), agentUID: 501)
        let first = try await sampler.sample()
        #expect(first.coverage == Coverage(enumerated: 1, permissionDenied: 1))
        #expect(first.processes.first?.status == .permissionDenied)
        #expect(first.processes.first?.cpuTimeNS == nil)
        source.fake.update {
            $0.processErrors.removeValue(forKey: 101)
            $0.processes[101]?.bsdInfo.uid = 502
            $0.processes[101]?.bsdInfo.ppid = 2
        }
        let next = try await sampler.sample()
        #expect(next.processes.first?.uid == 502)
        #expect(next.processes.first?.ppid == 2)
        #expect(next.processes.first?.isOwn == false)
        #expect(next.processes.first?.status == .ok)
        #expect(next.processes.first?.cpuPercent == .warmingUp)
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
        var cpuDurations: [Double] = []
        var loads = [Double](repeating: 0, count: 3)
        getloadavg(&loads, 3)
        print("PERF sweep load_before=\(loads)")
        var readable: [Int] = []
        var enumerated: [Int] = []
        var rows: [Int] = []
        var denied: [Int] = []
        for _ in 0 ..< 50 {
            let start = DispatchTime.now().uptimeNanoseconds
            let cpuStart = clock_gettime_nsec_np(CLOCK_PROCESS_CPUTIME_ID)
            let snapshot = try await sampler.sample()
            cpuDurations.append(Double(clock_gettime_nsec_np(CLOCK_PROCESS_CPUTIME_ID) - cpuStart) / 1_000_000)
            durations.append(milliseconds(since: start))
            readable.append(snapshot.coverage.sampled)
            enumerated.append(snapshot.coverage.enumerated)
            rows.append(snapshot.processes.count)
            denied.append(snapshot.coverage.permissionDenied)
            #expect(snapshot.processes.contains { $0.pid == getpid() })
        }
        let percentile = p95(durations)
        getloadavg(&loads, 3)
        print("PERF sweep n=50 wall_p50_ms=\(durations.sorted()[24]) wall_p95_ms=\(percentile) cpu_p50_ms=\(cpuDurations.sorted()[24]) cpu_p95_ms=\(p95(cpuDurations)) mean_ms=\(durations.reduce(0, +) / 50) readable=\(readable.min()!)...\(readable.max()!) enumerated=\(enumerated.min()!)...\(enumerated.max()!) rows=\(rows.min()!)...\(rows.max()!) denied=\(denied.min()!)...\(denied.max()!) load_after=\(loads)")
        #if DEBUG
            print("PERF Debug build: reporting only; the 40 ms budget applies to Release")
        #else
            #expect(percentile <= 40, "Release collection p95 must be <= 40 ms")
        #endif
    }

    @Test func memorySysctlSweepCost() async throws {
        let source = try DarwinProcessSource()
        let baselineSource = try DarwinProcessSource(readPressure: { _ in ENOTSUP }, readSwap: { _ in ENOTSUP })
        let measured = try Sampler(source: source, clock: SystemMonotonicClock())
        let baseline = try Sampler(source: baselineSource, clock: SystemMonotonicClock())
        _ = try await measured.sample()
        _ = try await baseline.sample()
        var syscallTimes: [Double] = []
        for _ in 0 ..< 1000 {
            let start = DispatchTime.now().uptimeNanoseconds
            _ = source.systemMemory()
            syscallTimes.append(milliseconds(since: start))
        }
        var withSysctls: [Double] = []
        var withoutSysctls: [Double] = []
        // Alternate the order to avoid always giving one variant warmer OS caches.
        for index in 0 ..< 100 {
            let pair = index.isMultiple(of: 2) ? [baseline, measured] : [measured, baseline]
            for sampler in pair {
                let start = DispatchTime.now().uptimeNanoseconds
                _ = try await sampler.sample()
                let duration = milliseconds(since: start)
                if sampler === measured {
                    withSysctls.append(duration)
                } else {
                    withoutSysctls.append(duration)
                }
            }
        }
        let median = withSysctls.sorted()[49]
        let baselineMedian = withoutSysctls.sorted()[49]
        let syscallP95 = p95(syscallTimes)
        print("PERF memory n=100 paired_sweeps baseline_p50_ms=\(baselineMedian) baseline_p95_ms=\(p95(withoutSysctls)) with_sysctls_p50_ms=\(median) with_sysctls_p95_ms=\(p95(withSysctls)) delta_p50_ms=\(median - baselineMedian) sysctl_pair_n=1000 sysctl_pair_p50_ms=\(syscallTimes.sorted()[499]) sysctl_pair_p95_ms=\(syscallP95)")
        #if !DEBUG
            #expect(syscallP95 < 1, "The two memory sysctls should add less than 1 ms at p95")
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
        var jsonRoundTrips: [Double] = []
        var plistRoundTrips: [Double] = []
        var plistBytes = 0
        var loads = [Double](repeating: 0, count: 3)
        getloadavg(&loads, 3)
        print("PERF encoding load_before=\(loads)")
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
            jsonRoundTrips.append(milliseconds(since: encodingStart))
            let plistStart = DispatchTime.now().uptimeNanoseconds
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            let plist = try encoder.encode(page)
            #expect(try PropertyListDecoder().decode(ProcessPage.self, from: plist) == page)
            plistRoundTrips.append(milliseconds(since: plistStart))
            plistBytes = plist.count
        }
        getloadavg(&loads, 3)
        print("PERF store rows=500 page=200 n=50 query_p95_ms=\(p95(queryTimes)) json_bytes=\(bytes) encode_p95_ms=\(p95(encodingTimes)) json_roundtrip_p50_ms=\(jsonRoundTrips.sorted()[24]) json_roundtrip_p95_ms=\(p95(jsonRoundTrips)) plist_bytes=\(plistBytes) plist_roundtrip_p50_ms=\(plistRoundTrips.sorted()[24]) plist_roundtrip_p95_ms=\(p95(plistRoundTrips)) load_after=\(loads)")
    }

    @Test func cachedMCPPollCost() async throws {
        let clock = FakeClock()
        let sampler = try Sampler(source: populatedSource(), clock: clock, agentUID: 501)
        let snapshot = try await sampler.sample()
        var store = SnapshotStore(clock: clock)
        store.insert(snapshot)
        let scope = AccessScope()
        let query = try ProcessQuery(filter: .all, limit: 50)
        let request = try ProcglintJSON.encoder().encode(AgentRequest.snapshot(top: 50, sort: .cpu))
        var decoding: [Double] = []
        var querying: [Double] = []
        var encoding: [Double] = []
        var replyDecoding: [Double] = []
        var loads = [Double](repeating: 0, count: 3)
        getloadavg(&loads, 3)
        print("PERF MCP load_before=\(loads)")
        for _ in 0 ..< 100 {
            var start = DispatchTime.now().uptimeNanoseconds
            _ = try ProcglintJSON.decoder().decode(AgentRequest.self, from: request)
            decoding.append(milliseconds(since: start))
            start = DispatchTime.now().uptimeNanoseconds
            _ = store.latest(scope: scope)
            let page = try store.listProcesses(query, scope: scope)
            querying.append(milliseconds(since: start))
            start = DispatchTime.now().uptimeNanoseconds
            let data = try ProcglintJSON.encoder().encode(AgentResponse.snapshot(Snapshot(header: page.snapshot, processes: page.items)))
            encoding.append(milliseconds(since: start))
            start = DispatchTime.now().uptimeNanoseconds
            _ = try ProcglintJSON.decoder().decode(AgentResponse.self, from: data)
            replyDecoding.append(milliseconds(since: start))
            #expect(store.responseCacheCount == 1)
            #expect(store.querySortCount == 1)
        }
        getloadavg(&loads, 3)
        print("PERF MCP rows=50 n=100 request_decode_p50_ms=\(decoding.sorted()[49]) scoped_fresh_and_query_p50_ms=\(querying.sorted()[49]) response_encode_p50_ms=\(encoding.sorted()[49]) response_decode_p50_ms=\(replyDecoding.sorted()[49]) cache_entries=\(store.responseCacheCount) sorts=\(store.querySortCount) load_after=\(loads)")
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
        let checkpoint = try #require(try history.series("system").nextCursor)
        history.record(snapshot)
        let full = try history.series("system")
        let delta = full.delta(after: checkpoint)
        #expect(delta.isDelta && delta.points.count == 1)
        var fullTimes: [Double] = []
        var deltaTimes: [Double] = []
        var loads = [Double](repeating: 0, count: 3)
        getloadavg(&loads, 3)
        print("PERF history encoding load_before=\(loads)")
        for _ in 0 ..< 50 {
            var start = DispatchTime.now().uptimeNanoseconds
            _ = try ProcglintJSON.encoder().encode(full.delta(after: nil))
            fullTimes.append(milliseconds(since: start))
            start = DispatchTime.now().uptimeNanoseconds
            _ = try ProcglintJSON.encoder().encode(delta)
            deltaTimes.append(milliseconds(since: start))
        }
        let fullBytes = try ProcglintJSON.encoder().encode(full.delta(after: nil)).count
        let deltaBytes = try ProcglintJSON.encoder().encode(delta).count
        getloadavg(&loads, 3)
        print("PERF history encoding n=50 full_points=\(full.points.count) delta_points=\(delta.points.count) full_bytes=\(fullBytes) delta_bytes=\(deltaBytes) full_p50_ms=\(fullTimes.sorted()[24]) full_p95_ms=\(p95(fullTimes)) delta_p50_ms=\(deltaTimes.sorted()[24]) delta_p95_ms=\(p95(deltaTimes)) load_after=\(loads)")
    }
}
