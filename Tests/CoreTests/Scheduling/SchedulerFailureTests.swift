import Foundation
import ProcglintCore
import Testing

@Test(.timeLimit(.minutes(1))) func coldStartKeepsUnavailableMetricReasons() async throws {
    let clock = FakeClock()
    var process = try storeProcess(cpu: .permissionDenied)
    process.diskReadBps = .unsupported
    process.diskWriteBps = .exited
    let counter = CountingCollect(clock: clock, processes: [process])
    let scheduler = try SamplingScheduler(clock: clock, policy: SamplingPolicy(), collect: { try await counter.collect() })
    let snapshot = try await scheduler.freshSnapshot()
    #expect(snapshot.status == .warmingUp)
    #expect(snapshot.processes.first?.cpuPercent == .permissionDenied)
    #expect(snapshot.processes.first?.diskReadBps == .unsupported)
    #expect(snapshot.processes.first?.diskWriteBps == .exited)
    await scheduler.shutdown()
}

@Test(.timeLimit(.minutes(1))) func failedWarmupDoesNotCreateAnIdleRetryLoop() async throws {
    let clock = FakeClock()
    let counter = CountingCollect(clock: clock)
    let scheduler = try SamplingScheduler(clock: clock, policy: SamplingPolicy(), collect: { try await counter.collect() })
    _ = try await scheduler.freshSnapshot()
    await counter.configure(failure: ProcessSourceError.enumerationFailed)
    await waitForTimer(clock)
    clock.advance(by: 1_000_000_000)
    await schedulerWait { await scheduler.diagnostics().failures["enumeration_failed"] == 1 }
    await schedulerWait { clock.pendingSleepCount == 0 }
    #expect(await scheduler.nextCollectionWindow == nil)
    clock.advance(by: 100_000_000_000)
    #expect(await counter.count == 2)
    await counter.configure()
    #expect(try await scheduler.freshSnapshot().status == .ok)
    #expect(try await scheduler.history(series: "system").gaps.count == 1)
    await scheduler.shutdown()
}

@Test(.timeLimit(.minutes(1))) func unavailableEnumerationDoesNotWarmUp() async throws {
    let clock = FakeClock()
    let counter = CountingCollect(clock: clock)
    await counter.configure(status: .unavailable)
    let scheduler = try SamplingScheduler(clock: clock, policy: SamplingPolicy(), collect: { try await counter.collect() })
    #expect(try await scheduler.freshSnapshot().status == .unavailable)
    #expect(await scheduler.nextCollectionWindow == nil)
    #expect(await scheduler.diagnostics().failures == ["unavailable": 1])
    #expect(try await scheduler.history(series: "system").points.isEmpty)
    await counter.configure()
    clock.advance(by: 1_000_000_000)
    #expect(try await scheduler.freshSnapshot(maxAge: 0).status == .warmingUp)
    await scheduler.shutdown()
}

@Test(.timeLimit(.minutes(1))) func diagnosticDurationRingIsBounded() async throws {
    let clock = FakeClock()
    let counter = CountingCollect(clock: clock)
    await counter.configure(durationNS: 100_000_000)
    let scheduler = try SamplingScheduler(clock: clock, policy: SamplingPolicy(), collect: { try await counter.collect() })
    _ = try await scheduler.freshSnapshot()
    await waitForTimer(clock)
    clock.advance(by: 1_000_000_000)
    await waitForSnapshot(scheduler, sequence: 2)
    await schedulerWait { clock.pendingSleepCount == 0 }
    await counter.configure(durationNS: 1_000_000)
    for _ in 0 ..< 129 {
        clock.advance(by: 1_000_000_000)
        _ = try await scheduler.freshSnapshot(maxAge: 0)
    }
    let diagnostics = await scheduler.diagnostics()
    #expect(diagnostics.collectionsTotal == 131)
    #expect(diagnostics.collectionP95MS == 1)
    #expect(diagnostics.lastCollectionMS == 1)
    await scheduler.shutdown()
}

@Test(.timeLimit(.minutes(1))) func failureReasonsAreFiniteDiagnosticKeys() async throws {
    let errors: [(any Error, String)] = [
        (ProcessSourceError.permissionDenied, "permission_denied"),
        (ProcessSourceError.exited, "exited"),
        (ProcessSourceError.unavailable("variable message"), "unavailable"),
        (CancellationError(), "cancelled"),
        (AgentError.rateLimited("slow down"), "rate_limited"),
    ]
    for (error, reason) in errors {
        let clock = FakeClock()
        let scheduler = try SamplingScheduler(clock: clock, policy: SamplingPolicy(), collect: { throw error })
        do {
            _ = try await scheduler.freshSnapshot()
            Issue.record("Collection failure was swallowed")
        } catch {}
        #expect(await scheduler.diagnostics().failures == [reason: 1])
        await scheduler.shutdown()
    }
}
