import Foundation
import ProcglintCore
import Testing

@Test(.timeLimit(.minutes(1))) func idleConnectionsDoNotSample() async throws {
    let clock = FakeClock()
    let counter = CountingCollect(clock: clock)
    let scheduler = try SamplingScheduler(clock: clock, policy: SamplingPolicy(), collect: { try await counter.collect() })
    await scheduler.clientConnected("mcp-a")
    clock.advance(by: 3_600_000_000_000)
    #expect(await scheduler.effectiveInterval == nil)
    #expect(await counter.count == 0)
    #expect(clock.pendingSleepCount == 0)
    #expect(await scheduler.hasBeenIdle() == false)
    await scheduler.clientDisconnected("mcp-a")
    clock.advance(by: 59_999_000_000)
    #expect(await scheduler.hasBeenIdle() == false)
    clock.advance(by: 1_000_000)
    #expect(await scheduler.hasBeenIdle())
    await scheduler.shutdown()
}

@Test(.timeLimit(.minutes(1))) func sharedFreshColdStartAndThrottle() async throws {
    let clock = FakeClock()
    let process = try storeProcess()
    let counter = CountingCollect(clock: clock, processes: [process])
    await counter.configure(hold: true)
    let scheduler = try SamplingScheduler(clock: clock, policy: SamplingPolicy(), collect: { try await counter.collect() })
    let first = Task { try await scheduler.freshSnapshot(maxAge: 0) }
    let second = Task { try await scheduler.freshSnapshot(maxAge: 0) }
    let third = Task { try await scheduler.freshSnapshot(maxAge: 0) }
    await schedulerWait { await counter.count == 1 }
    await counter.release()
    let values = try await [first.value, second.value, third.value]
    #expect(Set(values.map(\.snapshotID)) == ["agent-a-1"])
    #expect(values.allSatisfy { $0.status == .warmingUp && $0.system.cpuPercent == .warmingUp })
    #expect(values.first?.processes.first?.cpuPercent == .warmingUp)
    #expect(await counter.count == 1)
    await waitForTimer(clock)
    clock.advance(by: 100_000_000)
    let forced = Task { try await scheduler.freshSnapshot(maxAge: 0) }
    // The timer and request share the same second collection, including its rate-limit sleep.
    await schedulerWait { clock.pendingSleepCount >= 2 }
    #expect(await counter.count == 1)
    clock.advance(by: 900_000_000)
    let ready = try await forced.value
    #expect(ready.status == .ok)
    #expect(ready.snapshotID == "agent-a-2")
    #expect(await counter.count == 2)
    let cached = try await scheduler.freshSnapshot()
    #expect(cached.snapshotID == ready.snapshotID)
    await schedulerWait { clock.pendingSleepCount == 0 }
    clock.advance(by: 100_000_000_000)
    #expect(await counter.count == 2)
    await scheduler.shutdown()
}

@Test(.timeLimit(.minutes(1))) func leasesShortenPeriodThenExpireWithoutCatchup() async throws {
    let clock = FakeClock()
    let counter = CountingCollect(clock: clock)
    let scheduler = try SamplingScheduler(clock: clock, policy: SamplingPolicy(), collect: { try await counter.collect() })
    let request = try LeaseRequest(kind: .guiWindow, intervalMS: .fiveSeconds)
    let gui = try await scheduler.setLease(request, clientID: "gui-a")
    await waitForSnapshot(scheduler, sequence: 1)
    await waitForTimer(clock)
    clock.advance(by: 1_000_000_000)
    await waitForSnapshot(scheduler, sequence: 2)
    let renewed = try await scheduler.setLease(request, clientID: "gui-a")
    #expect(gui.leaseID == renewed.leaseID)
    let observation = SamplingLease(leaseID: "obs-a", clientID: "mcp-a", kind: .observation,
                                    intervalMS: .oneSecond, expiresAt: 4_000_000_000)
    try await scheduler.addLease(observation)
    #expect(await scheduler.effectiveInterval == .oneSecond)
    #expect(await scheduler.nextCollectionWindow == 2_000_000_000 ... 2_100_000_000)
    await waitForTimer(clock)
    clock.advance(by: 1_000_000_000)
    await waitForSnapshot(scheduler, sequence: 3)
    await waitForTimer(clock)
    clock.advance(by: 1_000_000_000)
    await waitForSnapshot(scheduler, sequence: 4)
    await waitForTimer(clock)
    clock.advance(by: 1_000_000_000)
    await schedulerWait { await scheduler.diagnostics().leases.count == 1 }
    #expect(await scheduler.effectiveInterval == .fiveSeconds)
    #expect(await scheduler.nextCollectionWindow == 8_000_000_000 ... 8_500_000_000)
    await waitForTimer(clock)
    clock.advance(by: 4_000_000_000)
    await waitForSnapshot(scheduler, sequence: 5)
    await waitForTimer(clock)
    clock.advance(by: 15_000_000_000)
    await waitForSnapshot(scheduler, sequence: 6)
    #expect(await counter.count == 6)
    #expect(await scheduler.nextCollectionWindow == 28_000_000_000 ... 28_500_000_000)
    await #expect(throws: AgentError.self) { try await scheduler.releaseLease(id: gui.leaseID, clientID: "other") }
    try await scheduler.releaseLease(id: gui.leaseID, clientID: "gui-a")
    #expect(await scheduler.effectiveInterval == nil)
    await schedulerWait { clock.pendingSleepCount == 0 }
    clock.advance(by: 100_000_000_000)
    #expect(await counter.count == 6)
    await scheduler.shutdown()
}

@Test(.timeLimit(.minutes(1))) func fiveSecondLeaseCollectsTwelveTimesPerMinuteWithoutAddedLeeway() async throws {
    let clock = FakeClock()
    let counter = CountingCollect(clock: clock)
    let scheduler = try SamplingScheduler(clock: clock, policy: SamplingPolicy(), collect: { try await counter.collect() })
    let request = try LeaseRequest(kind: .guiWindow, intervalMS: .fiveSeconds)
    _ = try await scheduler.setLease(request, clientID: "gui-a")
    await waitForSnapshot(scheduler, sequence: 1)
    await waitForTimer(clock)
    clock.advance(by: 1_000_000_000)
    await waitForSnapshot(scheduler, sequence: 2)
    let initialCount = await counter.count
    let start = clock.now
    for tick in 1 ... 12 {
        _ = try await scheduler.setLease(request, clientID: "gui-a")
        await waitForTimer(clock)
        clock.advance(by: 5_000_000_000)
        await waitForSnapshot(scheduler, sequence: initialCount + tick)
        #expect(await scheduler.nextCollectionWindow == (clock.now + 5_000_000_000) ... (clock.now + 5_500_000_000))
    }
    #expect(clock.now - start == 60_000_000_000)
    #expect(await counter.count - initialCount == 12)
    await scheduler.shutdown()
}

@Test(.timeLimit(.minutes(1))) func wakeExpiresLeasesAndRecordsGap() async throws {
    let clock = FakeClock()
    let counter = CountingCollect(clock: clock)
    let scheduler = try SamplingScheduler(clock: clock, policy: SamplingPolicy(), wallNow: {
        Date(timeIntervalSince1970: Double(clock.now) / 1_000_000_000)
    }, collect: { try await counter.collect() })
    _ = try await scheduler.setLease(LeaseRequest(kind: .menuBar, intervalMS: .tenSeconds), clientID: "gui-a")
    await waitForSnapshot(scheduler, sequence: 1)
    await waitForTimer(clock)
    clock.advance(by: 1_000_000_000)
    await waitForSnapshot(scheduler, sequence: 2)
    clock.advance(by: 60_000_000_000)
    await scheduler.didWake()
    #expect(await scheduler.effectiveInterval == nil)
    #expect(await scheduler.diagnostics().leases.isEmpty)
    let history = try await scheduler.history(series: "system")
    #expect(history.gaps.contains { $0.from <= Date(timeIntervalSince1970: 1) && $0.to >= Date(timeIntervalSince1970: 61) })
    await scheduler.shutdown()
}

@Test(.timeLimit(.minutes(1))) func latestOnlyDeliveryAndDiagnostics() async throws {
    let clock = FakeClock()
    let process = try storeProcess()
    let counter = CountingCollect(clock: clock, processes: [process])
    await counter.configure(durationNS: 20_000_000)
    let scheduler = try SamplingScheduler(clock: clock, policy: SamplingPolicy(), collect: { try await counter.collect() })
    let stream = await scheduler.subscribe(scope: AccessScope())
    _ = try await scheduler.freshSnapshot()
    await waitForTimer(clock)
    clock.advance(by: 1_000_000_000)
    await waitForSnapshot(scheduler, sequence: 2)
    var iterator = stream.makeAsyncIterator()
    let newest = await iterator.next()
    #expect(newest?.snapshotID == "agent-a-2")
    #expect(newest?.processes.first?.path == nil)
    let diagnostics = await scheduler.diagnostics()
    #expect(diagnostics.collectionsTotal == 2)
    #expect(diagnostics.lastCollectionMS == 20)
    #expect(diagnostics.collectionP95MS == 20)
    await counter.configure(failure: AgentError.internalError("fake failure"), durationNS: 40_000_000)
    clock.advance(by: 10_000_000_000)
    await #expect(throws: AgentError.internalError("fake failure")) { try await scheduler.freshSnapshot(maxAge: 0) }
    let failed = await scheduler.diagnostics()
    #expect(failed.collectionsTotal == 3)
    #expect(failed.failures == ["internal": 1])
    #expect(failed.lastCollectionMS == 40)
    #expect(failed.collectionP95MS == 40)
    await scheduler.shutdown()
    #expect(await iterator.next() == nil)
    await #expect(throws: AgentError.self) { try await scheduler.freshSnapshot() }
}
