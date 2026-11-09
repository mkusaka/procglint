import Foundation
@testable import ProcglintCore
import Synchronization
import Testing

struct SamplerTests {
    private func process(start: UInt64 = 1_000_000, uid: UInt32 = 501, name: String = "worker",
                         cpu: UInt64 = 1_000_000_000, read: UInt64 = 100, written: UInt64 = 200) -> FakeProcessSource.Process
    {
        FakeProcessSource.Process(
            rusage: RawRusage(cpuTimeNS: cpu, footprintBytes: 4096, rssBytes: 8192,
                              diskReadBytes: read, diskWrittenBytes: written, startTimeUS: start),
            bsdInfo: RawBSDInfo(name: name, uid: uid, ppid: 1, startTimeUS: start), path: "/fake/worker"
        )
    }

    @Test func warmingUpAndActualIntervalUnits() async throws {
        let source = FakeProcessSource()
        source.addProcess(pid: 42, process: process())
        source.update {
            $0.machTimebase = MachTimebase(numerator: 125, denominator: 3)
            $0.cpuTicks = RawCPUTicks(user: 100, system: 50, idle: 200, nice: 10)
            $0.vm = RawVMStatistics(activePages: 10, inactivePages: 20, wiredPages: 3, compressorPages: 2, freePages: 30)
        }
        let clock = FakeClock()
        let sampler = try Sampler(source: source, clock: clock, agentInstanceID: "agent-a", agentUID: 501)
        let first = try await sampler.sample()
        let initial = try #require(first.processes.first)
        #expect(first.status == .warmingUp)
        #expect(first.intervalMS == nil)
        #expect(first.system.cpuPercent == .warmingUp)
        #expect(initial.cpuPercent == .warmingUp)
        #expect(initial.diskReadBps == .warmingUp)
        #expect(initial.diskWriteBps == .warmingUp)
        #expect(initial.cpuTimeNS == 1_000_000_000)
        #expect(initial.footprintBytes == .ok(4096))
        #expect(initial.rssBytes == .ok(8192))
        #expect(initial.isOwn)
        #expect(initial.path == nil)
        #expect(initial.startTime == Date(timeIntervalSince1970: 1))
        #expect(first.system.memoryUsedBytes == 15 * source.pageSize)
        #expect(first.system.inactiveBytes == 20 * source.pageSize)
        #expect(first.system.freeBytes == 30 * source.pageSize)

        clock.advance(by: 2_000_000_000)
        source.setRusage(pid: 42, rusage: process(cpu: 5_000_000_000, read: 4100, written: 8200).rusage)
        source.update { $0.cpuTicks = RawCPUTicks(user: 120, system: 60, idle: 270, nice: 10) }
        let second = try await sampler.sample()
        let current = try #require(second.processes.first)
        #expect(second.status == .ok)
        #expect(second.intervalMS == 2000)
        #expect(second.snapshotID != first.snapshotID)
        #expect(second.coverage == Coverage(enumerated: 1, sampled: 1))
        #expect(current.cpuPercent == .ok(200))
        #expect(current.diskReadBps == .ok(2000))
        #expect(current.diskWriteBps == .ok(4000))
        #expect(second.system.cpuPercent == .ok(30))
    }

    @Test func reusedPIDHasNewIdentityAndNoDelta() async throws {
        let source = FakeProcessSource()
        source.addProcess(pid: 42, process: process())
        let clock = FakeClock()
        let sampler = try Sampler(source: source, clock: clock, agentUID: 501)
        let first = try await sampler.sample()
        source.addProcess(pid: 42, process: process(start: 2_000_000, uid: 502, name: "replacement", cpu: 9_000_000_000))
        clock.advance(by: 1_000_000_000)
        let second = try await sampler.sample()
        let row = try #require(second.processes.first)
        #expect(row.processKey != first.processes.first?.processKey)
        #expect(row.cpuPercent == .warmingUp)
        #expect(row.diskReadBps == .warmingUp)
        #expect(row.name == "replacement")
        #expect(row.uid == 502)
        #expect(!row.isOwn)
        #expect(await sampler.cachedProcessCount == 1)
        #expect(await sampler.cachedUserCount == 1)
    }

    @Test func enumerationFailurePreservesBaselinesAndCaches() async throws {
        let source = FakeProcessSource()
        source.addProcess(pid: 42, process: process())
        source.update {
            $0.cpuTicks = RawCPUTicks(user: 100, idle: 100)
            $0.vm = RawVMStatistics(activePages: 10)
        }
        let clock = FakeClock()
        let sampler = try Sampler(source: source, clock: clock)
        let first = try await sampler.sample()
        let key = try #require(first.processes.first?.processKey)
        #expect(try await sampler.path(for: key) == "/fake/worker")
        clock.advance(by: 1_000_000_000)
        source.update {
            $0.enumerationError = .enumerationFailed
            $0.cpuTicks = RawCPUTicks(user: 150, idle: 150)
        }
        let failed = try await sampler.sample()
        #expect(failed.status == .unavailable)
        #expect(failed.snapshotID != first.snapshotID)
        #expect(failed.intervalMS == 1000)
        #expect(failed.coverage == Coverage())
        #expect(failed.processes.isEmpty)
        #expect(failed.system.memoryUsedBytes == 10 * source.pageSize)
        #expect(await sampler.cachedProcessCount == 1)
        #expect(await sampler.cachedReadingCount == 1)
        #expect(await sampler.cachedUserCount == 1)
        #expect(try await sampler.path(for: key) == "/fake/worker")
        clock.advance(by: 1_000_000_000)
        source.update {
            $0.enumerationError = nil
            $0.cpuTicks = RawCPUTicks(user: 200, idle: 400)
        }
        source.setRusage(pid: 42, rusage: process(cpu: 5_000_000_000, read: 4100, written: 8200).rusage)
        let recovered = try await sampler.sample()
        #expect(recovered.status == .ok)
        #expect(recovered.snapshotID != failed.snapshotID)
        #expect(recovered.intervalMS == 2000)
        #expect(recovered.processes.first?.processKey == key)
        #expect(recovered.processes.first?.cpuPercent == .ok(200))
        #expect(recovered.processes.first?.diskReadBps == .ok(2000))
        #expect(recovered.processes.first?.diskWriteBps == .ok(4000))
        #expect(recovered.system.cpuPercent == .ok(25))
    }

    @Test func enumerationFailureOnColdStartDoesNotCreateBaselines() async throws {
        let source = FakeProcessSource()
        source.addProcess(pid: 42, process: process())
        source.update { $0.enumerationError = .enumerationFailed }
        let clock = FakeClock()
        let sampler = try Sampler(source: source, clock: clock)
        let failed = try await sampler.sample()
        #expect(failed.status == .unavailable)
        #expect(failed.intervalMS == nil)
        #expect(failed.coverage == Coverage())
        #expect(failed.processes.isEmpty)
        #expect(failed.system.cpuPercent == .warmingUp)
        #expect(await sampler.cachedProcessCount == 0)
        #expect(await sampler.cachedReadingCount == 0)
        clock.advance(by: 1_000_000_000)
        source.update { $0.enumerationError = nil }
        let first = try await sampler.sample()
        #expect(first.status == .warmingUp)
        #expect(first.intervalMS == nil)
        #expect(first.processes.first?.cpuPercent == .warmingUp)
        #expect(first.snapshotID != failed.snapshotID)
        source.removeProcess(pid: 42)
        clock.advance(by: 1_000_000_000)
        let empty = try await sampler.sample()
        #expect(empty.status == .ok)
        #expect(empty.processes.isEmpty)
        #expect(await sampler.cachedProcessCount == 0)
    }

    @Test func permissionDeniedWithBSDInfoStillListsProcess() async throws {
        let source = SamplingProbe()
        source.fake.addProcess(pid: 42, process: process())
        source.update { $0.usageErrors[42] = .permissionDenied }
        let clock = FakeClock()
        let sampler = try Sampler(source: source, clock: clock)
        let snapshot = try await sampler.sample()
        let row = try #require(snapshot.processes.first)
        #expect(snapshot.coverage == Coverage(enumerated: 1, permissionDenied: 1))
        #expect(row.pid == 42)
        #expect(row.name == "worker")
        #expect(row.status == .permissionDenied)
        #expect(row.cpuTimeNS == nil)
        for metric in [row.cpuPercent, row.footprintBytes, row.rssBytes, row.diskReadBytes,
                       row.diskWrittenBytes, row.diskReadBps, row.diskWriteBps, row.powerMW]
        {
            #expect(metric == .permissionDenied)
        }
        source.update { $0.usageErrors.removeValue(forKey: 42) }
        clock.advance(by: 1_000_000_000)
        let recovered = try await sampler.sample()
        #expect(recovered.processes.first?.processKey == row.processKey)
        #expect(recovered.processes.first?.cpuPercent == .warmingUp)
    }

    @Test func inaccessibleIdentityIsCountedWithoutInventingAKey() async throws {
        let source = FakeProcessSource()
        source.addProcess(pid: 42, process: process())
        source.update { $0.processErrors[42] = .permissionDenied }
        let sampler = try Sampler(source: source, clock: FakeClock())
        let snapshot = try await sampler.sample()
        #expect(snapshot.coverage == Coverage(enumerated: 1, permissionDenied: 1))
        #expect(snapshot.processes.isEmpty)
    }

    @Test func exitDuringSampleIsOmittedAndPruned() async throws {
        let source = FakeProcessSource()
        source.addProcess(pid: 42, process: process())
        let clock = FakeClock()
        let sampler = try Sampler(source: source, clock: clock)
        _ = try await sampler.sample()
        source.update { $0.exitDuringSample.insert(42) }
        clock.advance(by: 1_000_000_000)
        let snapshot = try await sampler.sample()
        #expect(snapshot.processes.isEmpty)
        #expect(snapshot.coverage == Coverage(enumerated: 1, exitedDuringSample: 1))
        #expect(await sampler.cachedProcessCount == 0)
        #expect(await sampler.cachedUserCount == 0)
    }

    @Test func allProcessesAreSweptAndExitedCachesAreBounded() async throws {
        let source = SamplingProbe()
        for pid in Int32(1) ... 300 {
            source.fake.addProcess(pid: pid, process: process(uid: pid.isMultiple(of: 2) ? 501 : 502))
        }
        let sampler = try Sampler(source: source, clock: FakeClock())
        let snapshot = try await sampler.sample()
        #expect(snapshot.coverage.sampled == 300)
        #expect(snapshot.processes.count == 300)
        #expect(source.state.usageCalls == 300)
        #expect(source.state.pathCalls == 0)
        #expect(await sampler.cachedProcessCount == 300)
        #expect(await sampler.cachedUserCount == 2)
        source.fake.update { $0.processes = [42: process()] }
        _ = try await sampler.sample()
        #expect(await sampler.cachedProcessCount == 1)
        #expect(await sampler.cachedUserCount == 1)
    }

    @Test func zeroIntervalAndCounterResetsNeverProduceNegativeRates() async throws {
        let source = FakeProcessSource()
        source.addProcess(pid: 42, process: process())
        let clock = FakeClock()
        let sampler = try Sampler(source: source, clock: clock)
        _ = try await sampler.sample()
        let immediate = try await sampler.sample()
        #expect(immediate.processes.first?.cpuPercent == .warmingUp)
        clock.advance(by: 1_000_000_000)
        source.setRusage(pid: 42, rusage: process(cpu: 0, read: 0, written: 0).rusage)
        let reset = try await sampler.sample()
        #expect(reset.processes.first?.cpuPercent == .warmingUp)
        #expect(reset.processes.first?.diskReadBps == .warmingUp)
        #expect(reset.processes.first?.diskWriteBps == .warmingUp)
    }

    @Test func hostTicksWrapAt32Bits() async throws {
        let source = FakeProcessSource()
        source.update { $0.cpuTicks = RawCPUTicks(user: UInt64(UInt32.max) - 9, idle: 100) }
        let sampler = try Sampler(source: source, clock: FakeClock())
        _ = try await sampler.sample()
        source.update { $0.cpuTicks = RawCPUTicks(user: 10, idle: 120) }
        let snapshot = try await sampler.sample()
        #expect(snapshot.system.cpuPercent == .ok(50))
    }

    @Test func pathsAreLazyCachedAndInvalidatedByNameAndExecutable() async throws {
        let source = SamplingProbe()
        source.fake.addProcess(pid: 42, process: process())
        let sampler = try Sampler(source: source, clock: FakeClock())
        let snapshot = try await sampler.sample()
        let key = try #require(snapshot.processes.first?.processKey)
        #expect(source.state.pathCalls == 0)
        #expect(try await sampler.path(for: key) == "/fake/worker")
        #expect(try await sampler.path(for: key) == "/fake/worker")
        #expect(source.state.pathCalls == 1)
        let afterPathLookup = try await sampler.sample()
        #expect(afterPathLookup.processes.first?.path == nil)
        source.fake.update {
            $0.processes[42]?.bsdInfo.name = "renamed"
            $0.processes[42]?.path = "/fake/renamed"
        }
        _ = try await sampler.sample()
        #expect(try await sampler.path(for: key) == "/fake/renamed")
        source.fake.update {
            $0.processes[42]?.rusage.executableUUID = UUID()
            $0.processes[42]?.path = "/fake/exec"
        }
        _ = try await sampler.sample()
        #expect(try await sampler.path(for: key) == "/fake/exec")
        #expect(source.state.pathCalls == 3)
        source.fake.addProcess(pid: 42, process: process(start: 2_000_000))
        await #expect(throws: ProcessSourceError.exited) { try await sampler.path(for: key) }
        #expect(source.state.pathCalls == 3)
    }

    @Test func identityChangeDuringSweepIsNotJoinedToOldMetadata() async throws {
        let source = FakeProcessSource()
        var replacement = process()
        replacement.rusage.startTimeUS = 2_000_000
        source.addProcess(pid: 42, process: replacement)
        let sampler = try Sampler(source: source, clock: FakeClock())
        let snapshot = try await sampler.sample()
        #expect(snapshot.coverage.exitedDuringSample == 1)
        #expect(snapshot.processes.isEmpty)
    }

    @Test func deltasUseReadingTimesNotSweepStartTimes() async throws {
        let clock = FakeClock()
        let source = SamplingProbe(clock: clock)
        source.fake.addProcess(pid: 42, process: process())
        source.fake.update { $0.processes[42]?.rusage.energyNJ = 1_000_000_000 }
        source.update { $0.readingDelay = 1_000_000_000 }
        let sampler = try Sampler(source: source, clock: clock)
        _ = try await sampler.sample()
        clock.advance(by: 1_000_000_000)
        source.update { $0.readingDelay = 3_000_000_000 }
        source.fake.setRusage(pid: 42, rusage: process(cpu: 9_000_000_000).rusage)
        source.fake.update { $0.processes[42]?.rusage.energyNJ = 9_000_000_000 }
        let snapshot = try await sampler.sample()
        #expect(snapshot.intervalMS == 2000)
        #expect(snapshot.processes.first?.cpuPercent == .ok(200))
        #expect(snapshot.processes.first?.powerMW == .ok(2000))
    }

    @Test func identityIsRecheckedAfterLazyPathRead() async throws {
        let source = SamplingProbe()
        source.fake.addProcess(pid: 42, process: process())
        let sampler = try Sampler(source: source, clock: FakeClock())
        let snapshot = try await sampler.sample()
        let key = try #require(snapshot.processes.first?.processKey)
        source.update { $0.replacementDuringPathRead = process(start: 2_000_000) }
        await #expect(throws: ProcessSourceError.exited) { try await sampler.path(for: key) }
        #expect(source.state.pathCalls == 1)
    }

    @Test func unexpectedPerProcessFailureDoesNotCommitPartialState() async throws {
        let source = SamplingProbe()
        source.fake.addProcess(pid: 42, process: process())
        let clock = FakeClock()
        let sampler = try Sampler(source: source, clock: clock)
        _ = try await sampler.sample()
        source.update { $0.usageErrors[42] = .unavailable("test failure") }
        clock.advance(by: 1_000_000_000)
        await #expect(throws: ProcessSourceError.unavailable("test failure")) { try await sampler.sample() }
        #expect(await sampler.cachedProcessCount == 1)
        source.update { $0.usageErrors = [:] }
        source.fake.setRusage(pid: 42, rusage: process(cpu: 5_000_000_000).rusage)
        clock.advance(by: 1_000_000_000)
        let snapshot = try await sampler.sample()
        #expect(snapshot.processes.first?.cpuPercent == .ok(200))
    }
}

/// The shared fake denies BSD and rusage together; this probe isolates rusage failures and lazy path calls.
private final class SamplingProbe: ProcessSource {
    struct State: Sendable {
        var usageErrors: [Int32: ProcessSourceError] = [:]
        var usageCalls = 0
        var pathCalls = 0
        var readingDelay: UInt64 = 0
        var replacementDuringPathRead: FakeProcessSource.Process?
    }

    let fake = FakeProcessSource()
    private let clock: FakeClock?
    private let storage = Mutex(State())

    init(clock: FakeClock? = nil) {
        self.clock = clock
    }

    var state: State {
        storage.withLock { $0 }
    }

    func update(_ body: (inout State) -> Void) {
        storage.withLock { body(&$0) }
    }

    func listPIDs() throws -> [Int32] {
        try fake.listPIDs()
    }

    func bsdInfo(pid: Int32) throws -> RawBSDInfo? {
        try fake.bsdInfo(pid: pid)
    }

    func rusage(pid: Int32) throws -> RawRusage? {
        let error = storage.withLock { state in
            state.usageCalls += 1
            return state.usageErrors[pid]
        }
        if let error {
            throw error
        }
        clock?.advance(by: state.readingDelay)
        return try fake.rusage(pid: pid)
    }

    func path(pid: Int32) throws -> String? {
        let replacement = storage.withLock { state in
            state.pathCalls += 1
            return state.replacementDuringPathRead
        }
        let path = try fake.path(pid: pid)
        if let replacement {
            fake.addProcess(pid: pid, process: replacement)
        }
        return path
    }

    func hostCPUTicks() throws -> RawCPUTicks {
        fake.hostCPUTicks()
    }

    func vmStatistics() throws -> RawVMStatistics {
        fake.vmStatistics()
    }

    func bootSessionID() throws -> String {
        fake.bootSessionID()
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
}
