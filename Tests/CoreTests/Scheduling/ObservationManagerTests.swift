import Foundation
import ProcglintCore
import Testing

@Test(.timeLimit(.minutes(1))) func observationsExpireAndHistoryIsWindowed() async throws {
    let clock = FakeClock()
    let process = try storeProcess()
    let counter = CountingCollect(clock: clock, processes: [process])
    let wall: @Sendable () -> Date = { Date(timeIntervalSince1970: Double(clock.now) / 1_000_000_000) }
    let scheduler = try SamplingScheduler(clock: clock, policy: SamplingPolicy(), wallNow: wall, collect: { try await counter.collect() })
    try await scheduler.pin(key: process.processKey, pinned: true)
    _ = try await scheduler.freshSnapshot()
    await waitForTimer(clock)
    clock.advance(by: 1_000_000_000)
    await waitForSnapshot(scheduler, sequence: 2)
    let manager = ObservationManager(scheduler: scheduler, clock: clock, wallNow: wall)
    let request = try ObservationRequest(intervalMS: .oneSecond, durationMS: 3000, processKeys: [process.processKey])
    let observation = try await manager.start(request, clientID: "mcp-a")
    #expect(observation.state == .active)
    #expect(await scheduler.effectiveInterval == .oneSecond)
    await waitForTimer(clock)
    clock.advance(by: 1_100_000_000)
    await waitForSnapshot(scheduler, sequence: 3)
    await waitForTimer(clock)
    clock.advance(by: 1_100_000_000)
    await waitForSnapshot(scheduler, sequence: 4)
    await waitForTimer(clock)
    clock.advance(by: 800_000_000)
    #expect(try await manager.observation(id: observation.observationID, clientID: "mcp-a").state == .expired)
    #expect(await scheduler.effectiveInterval == nil)
    clock.advance(by: 6_000_000_000)
    _ = try await scheduler.freshSnapshot()
    let series = try await manager.history(id: observation.observationID, clientID: "mcp-a")
    #expect(series.count == 1)
    #expect(series.first?.series == process.processKey.rawValue)
    #expect(series.first?.points.count == 3)
    #expect(series.first?.points.allSatisfy { $0.t >= observation.startedAt && $0.t <= observation.expiresAt } == true)
    await #expect(throws: AgentError.self) { try await manager.history(id: observation.observationID, clientID: "other") }
    await scheduler.shutdown()
}

@Test(.timeLimit(.minutes(1))) func disconnectRemovesAllClientLeasesAndObservations() async throws {
    let clock = FakeClock()
    let counter = CountingCollect(clock: clock)
    let scheduler = try SamplingScheduler(clock: clock, policy: SamplingPolicy(), collect: { try await counter.collect() })
    let manager = ObservationManager(scheduler: scheduler, clock: clock)
    await scheduler.clientConnected("mcp-a")
    _ = try await scheduler.setLease(LeaseRequest(kind: .menuBar, intervalMS: .tenSeconds), clientID: "mcp-a")
    let observation = try await manager.start(ObservationRequest(intervalMS: .oneSecond, durationMS: 10000), clientID: "mcp-a")
    await manager.clientDisconnected("mcp-a")
    #expect(await scheduler.diagnostics().leases.isEmpty)
    #expect(await scheduler.effectiveInterval == nil)
    await #expect(throws: AgentError.self) { try await manager.observation(id: observation.observationID, clientID: "mcp-a") }
    clock.advance(by: 60_000_000_000)
    #expect(await scheduler.hasBeenIdle())
    await scheduler.shutdown()
}

@Test(.timeLimit(.minutes(1))) func observationStopOwnershipValidationAndHistoryLimit() async throws {
    let clock = FakeClock()
    let counter = CountingCollect(clock: clock)
    let scheduler = try SamplingScheduler(clock: clock, policy: SamplingPolicy(maxProcessSeries: 1), collect: { try await counter.collect() })
    let manager = ObservationManager(scheduler: scheduler, clock: clock)
    let first = try storeProcess(pid: 1)
    let second = try storeProcess(pid: 2)
    let observation = try await manager.start(ObservationRequest(intervalMS: .fiveSeconds, durationMS: 10000,
                                                                 processKeys: [first.processKey]), clientID: "mcp-a")
    await #expect(throws: AgentError.self) { try await manager.stop(id: observation.observationID, clientID: "foreign") }
    await #expect(throws: AgentError.self) {
        try await manager.start(ObservationRequest(intervalMS: .oneSecond, durationMS: 1000, processKeys: [second.processKey]), clientID: "mcp-b")
    }
    #expect(await scheduler.diagnostics().leases.count == 1)
    try await manager.stop(id: observation.observationID, clientID: "mcp-a")
    #expect(try await manager.observation(id: observation.observationID, clientID: "mcp-a").state == .stopped)
    #expect(await scheduler.effectiveInterval == nil)
    var invalid = try ObservationRequest(intervalMS: .oneSecond, durationMS: 1000)
    invalid.durationMS = 0
    let invalidRequest = invalid
    await #expect(throws: AgentError.self) { try await manager.start(invalidRequest, clientID: "mcp-a") }
    await scheduler.shutdown()
}
