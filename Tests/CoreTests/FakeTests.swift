import Foundation
import ProcglintCore
import Testing

func fakeProcess(start: UInt64 = 10) -> FakeProcessSource.Process {
    FakeProcessSource.Process(rusage: RawRusage(cpuTimeNS: 100, footprintBytes: 200, rssBytes: 150,
                                                diskReadBytes: 20, diskWrittenBytes: 30, startTimeUS: start),
                              bsdInfo: RawBSDInfo(name: "worker", uid: 501, ppid: 1, startTimeUS: start), path: "/bin/worker")
}

@Test func fakeProcessTable() throws {
    let source = FakeProcessSource()
    #expect(try source.listPIDs().isEmpty)
    #expect(try source.rusage(pid: 42) == nil)
    #expect(try source.bsdInfo(pid: 42) == nil)
    #expect(try source.path(pid: 42) == nil)
    source.addProcess(pid: 42, process: fakeProcess())
    source.addProcess(pid: 7, process: fakeProcess())
    #expect(try source.listPIDs() == [7, 42])
    #expect(try source.rusage(pid: 42) == fakeProcess().rusage)
    #expect(try source.bsdInfo(pid: 42) == fakeProcess().bsdInfo)
    #expect(try source.path(pid: 42) == "/bin/worker")
    var counters = fakeProcess().rusage
    counters.cpuTimeNS = 300
    counters.diskReadBytes = 50
    source.setRusage(pid: 42, rusage: counters)
    #expect(try source.rusage(pid: 42)?.cpuTimeNS == 300)
    #expect(try source.rusage(pid: 42)?.diskReadBytes == 50)
    source.removeProcess(pid: 7)
    #expect(try source.listPIDs() == [42])
    let original = try ProcessIdentity(bootSessionID: source.bootSessionID(), pid: 42, startTimeUS: #require(try source.bsdInfo(pid: 42)).startTimeUS)
    source.removeProcess(pid: 42)
    source.addProcess(pid: 42, process: fakeProcess(start: 99))
    let replacement = try ProcessIdentity(bootSessionID: source.bootSessionID(), pid: 42, startTimeUS: #require(try source.bsdInfo(pid: 42)).startTimeUS)
    #expect(ProcessKey(identity: original) != ProcessKey(identity: replacement))
    #expect(try source.rusage(pid: 42)?.startTimeUS == 99)
}

@Test func fakeProcessFailures() throws {
    let source = FakeProcessSource()
    source.addProcess(pid: 42, process: fakeProcess())
    source.update { $0.enumerationError = .enumerationFailed }
    #expect(throws: ProcessSourceError.enumerationFailed) { try source.listPIDs() }
    #expect(source.state.processes.count == 1)
    source.update {
        $0.enumerationError = nil
        $0.processErrors[42] = .permissionDenied
    }
    #expect(try source.listPIDs() == [42])
    #expect(throws: ProcessSourceError.permissionDenied) { try source.rusage(pid: 42) }
    #expect(throws: ProcessSourceError.permissionDenied) { try source.bsdInfo(pid: 42) }
    #expect(throws: ProcessSourceError.permissionDenied) { try source.path(pid: 42) }
    source.update {
        $0.processErrors[42] = nil
        $0.exitDuringSample.insert(42)
    }
    #expect(try source.listPIDs() == [42])
    #expect(throws: ProcessSourceError.exited) { try source.rusage(pid: 42) }
    #expect(try source.listPIDs().isEmpty)
    #expect(try source.rusage(pid: 42) == nil)
}

@Test func fakeHostValues() {
    let source = FakeProcessSource()
    source.update {
        $0.cpuTicks = RawCPUTicks(user: 1, system: 2, idle: 3, nice: 4)
        $0.vm = RawVMStatistics(activePages: 1, inactivePages: 2, wiredPages: 3, compressorPages: 4, freePages: 5)
        $0.pageSize = 4096
        $0.physicalMemory = 8192
        $0.machTimebase = MachTimebase(numerator: 125, denominator: 3)
        $0.bootSessionID = "new-boot"
    }
    #expect(source.hostCPUTicks() == source.state.cpuTicks)
    #expect(source.vmStatistics() == source.state.vm)
    #expect(source.pageSize == 4096)
    #expect(source.physicalMemory == 8192)
    #expect(source.machTimebase == MachTimebase(numerator: 125, denominator: 3))
    #expect(source.bootSessionID() == "new-boot")
}

@Test(.timeLimit(.minutes(1))) func fakeClockDeadlines() async throws {
    let clock = FakeClock(now: 100)
    try await clock.sleep(until: 100)
    try await clock.sleep(until: 0)
    let first = Task { try await clock.sleep(until: 200) }
    let second = Task { try await clock.sleep(until: 300) }
    // Wait for registration, not an elapsed wall-clock delay.
    while clock.pendingSleepCount != 2 {
        await Task.yield()
    }
    clock.advance(by: 99)
    #expect(clock.pendingSleepCount == 2)
    clock.advance(by: 1)
    try await first.value
    #expect(clock.now == 200)
    #expect(clock.pendingSleepCount == 1)
    clock.advance(by: 100)
    try await second.value
    #expect(clock.pendingSleepCount == 0)
}

@Test(.timeLimit(.minutes(1))) func fakeClockCancellation() async throws {
    let clock = FakeClock()
    let sleeper = Task { try await clock.sleep(until: 100) }
    while clock.pendingSleepCount != 1 {
        await Task.yield()
    }
    sleeper.cancel()
    await #expect(throws: CancellationError.self) { try await sleeper.value }
    #expect(clock.pendingSleepCount == 0)
    let alreadyCancelled = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        try await clock.sleep(until: 100)
    }
    await #expect(throws: CancellationError.self) { try await alreadyCancelled.value }
    #expect(clock.pendingSleepCount == 0)
    clock.advance(by: 100)
}

@Test func inMemorySettings() throws {
    let store = try InMemorySettingsStore(policy: SamplingPolicy(), allowedPermissions: [.observe])
    #expect(store.allowedPermissions() == [.observe])
    let policy = try SamplingPolicy(revision: 1, historyMinutes: 1)
    try store.setSamplingPolicy(policy)
    #expect(store.samplingPolicy() == policy)
    store.setAllowedPermissions([.includePaths])
    #expect(store.allowedPermissions() == [.includePaths])
    var invalid = policy
    invalid.historyMinutes = 0
    invalidArgument { try store.setSamplingPolicy(invalid) }
    #expect(store.samplingPolicy() == policy)
    invalidArgument { try InMemorySettingsStore(policy: invalid) }
}
