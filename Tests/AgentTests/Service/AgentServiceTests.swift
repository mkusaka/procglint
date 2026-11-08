import Foundation
@testable import ProcglintAgentKit
@testable import ProcglintCore
import ProcglintIPC
import Testing

@Suite(.timeLimit(.minutes(1)))
struct AgentServiceTests {
    @Test(arguments: ClientKind.allCases, [PermissionSet(), .all, [.observe, .includePaths]])
    func permissionMatrix(kind: ClientKind, allowed: PermissionSet) async throws {
        let fixture = try ServiceFixture(permissions: allowed)
        let flags: PermissionSet = [.observe, .configure, .includeSystem]
        let client = fixture.client(kind, flags: flags)
        let effective: PermissionSet = switch kind {
        case .gui: allowed
        case .mcp: allowed.intersection(flags)
        case .cli: allowed.intersection([.includeSystem, .includePaths])
        }
        let page = try await client.listProcesses(ProcessQuery(filter: .all, sort: .pid, limit: 200))
        #expect(page.items.contains { $0.pid == 84 } == effective.contains(.includeSystem))
        #expect(page.items.allSatisfy { $0.path == nil })
        let process = try await client.process(key: fixture.key())
        #expect((process.path != nil) == effective.contains(.includePaths))
        let observationRequest = try ObservationRequest(intervalMS: .fiveSeconds, durationMS: 10000)
        if effective.contains(.observe) {
            let observation = try await client.startObservation(observationRequest)
            try await client.stopObservation(id: observation.observationID)
        } else {
            await expectAgentError(.permissionDenied) { _ = try await client.startObservation(observationRequest) }
            await expectAgentError(.permissionDenied) { try await client.stopObservation(id: "missing") }
        }
        if kind == .gui || (kind == .mcp && effective.contains(.configure)) {
            let policy = try await client.policy()
            #expect(try await client.setPolicy(policy, expectedRevision: policy.revision).revision == policy.revision + 1)
        } else {
            await expectAgentError(.permissionDenied) { _ = try await client.policy() }
            await expectAgentError(.permissionDenied) { _ = try await client.setPolicy(SamplingPolicy(), expectedRevision: 0) }
        }
        let leaseRequest = try LeaseRequest(kind: .guiWindow, intervalMS: .fiveSeconds)
        if kind == .gui {
            let lease = try await client.setLease(leaseRequest)
            try await client.releaseLease(id: lease.leaseID)
            try await client.pin(key: fixture.key(), pinned: true)
        } else {
            await expectAgentError(.permissionDenied) { _ = try await client.setLease(leaseRequest) }
            await expectAgentError(.permissionDenied) { try await client.releaseLease(id: "missing") }
            await expectAgentError(.permissionDenied) { try await client.pin(key: fixture.key(), pinned: true) }
        }
        // configure/observe never imply termination, even if a caller claims a different kind in MCP flags.
        if effective.contains(.terminate) {
            _ = try await client.prepareTermination(key: fixture.key(), signal: .term)
        } else {
            await expectAgentError(.permissionDenied) { _ = try await client.prepareTermination(key: fixture.key(), signal: .term) }
        }
        await client.invalidate()
        await fixture.close()
    }

    @Test func terminationRequiresBothLaunchFlagsAndCurrentSettings() async throws {
        let fixture = try ServiceFixture()
        let client = fixture.client(flags: [.terminate])
        _ = try await client.prepareTermination(key: fixture.key(), signal: .term)
        await expectAgentError(.permissionDenied) { _ = try await client.prepareTermination(key: fixture.key(), signal: .kill) }
        fixture.settings.setAllowedPermissions([.forceKill])
        await expectAgentError(.permissionDenied) { _ = try await client.prepareTermination(key: fixture.key(), signal: .term) }
        fixture.settings.setAllowedPermissions(.all)
        let readOnly = fixture.client(flags: nil)
        await expectAgentError(.permissionDenied) { _ = try await readOnly.prepareTermination(key: fixture.key(), signal: .term) }
        await expectAgentError(.permissionDenied) { _ = try await readOnly.terminate(token: "tok-1") }
        #expect(fixture.signals.isEmpty)
        await client.invalidate()
        await readOnly.invalidate()
        await fixture.close()
    }

    @Test func threeMCPClientsShareCollectionAndKeepScopesSeparate() async throws {
        let fixture = try ServiceFixture()
        let first = fixture.client(flags: [.includeSystem, .includePaths])
        let second = fixture.client(flags: [.includeSystem])
        let third = fixture.client(flags: nil)
        async let a = first.snapshot(top: 2, sort: .pid)
        async let b = second.snapshot(top: 200, sort: .footprint)
        async let c = third.snapshot(top: 200, sort: .name)
        let (wide, system, own) = try await (a, b, c)
        #expect(Set([wide.snapshotID, system.snapshotID, own.snapshotID]).count == 1)
        #expect(wide.processes.count == 2)
        #expect(wide.processes.map(\.pid) == wide.processes.map(\.pid).sorted(by: >))
        #expect(system.processes.contains { !$0.isOwn })
        #expect(own.processes.allSatisfy { $0.isOwn && $0.path == nil })
        #expect(await fixture.scheduler.diagnostics().collectionsTotal == 1)
        #expect(try await first.process(key: fixture.key()).path == "/private/worker-42")
        #expect(try await third.process(key: fixture.key()).path == nil)
        await expectAgentError(.notFound) { _ = try await third.process(key: fixture.key(84)) }
        let page = try await first.listProcesses(ProcessQuery(filter: .all, sort: .pid, limit: 1))
        let cursor = try #require(page.nextCursor)
        await expectAgentError(.invalidCursor) {
            _ = try await third.listProcesses(ProcessQuery(filter: .all, sort: .pid, limit: 1, cursor: cursor))
        }
        let status = try await first.status()
        #expect(status.clients.count == 3)
        #expect(status.clients.allSatisfy { $0.kind == .mcp && $0.pid == getpid() })
        #expect(status.clients.allSatisfy { $0.footprintBytes == UInt64(getpid()) * 100 })
        #expect(status.agentFootprintBytes == UInt64(getpid()) * 100)
        #expect(status.agentCPUPercent.status == .warmingUp)
        #expect(status.collectionsTotal == 1)
        #expect(status.lastCoverage.enumerated == system.coverage.enumerated)
        #expect(status.historyBytes > 0)
        #expect(!status.samplingActive)
        await first.invalidate()
        await second.invalidate()
        await third.invalidate()
        await fixture.close()
    }

    @Test func historyCursorBatchesSeriesAndKeepsLegacyResponsesUnchanged() async throws {
        let fixture = try ServiceFixture()
        let gui = fixture.client(.gui)
        let key = try fixture.key()
        _ = try await gui.setLease(LeaseRequest(kind: .guiWindow, intervalMS: .fiveSeconds, processKeys: [key]))
        fixture.clock.advance(by: 1_000_000_000)
        _ = try await fixture.scheduler.freshSnapshot(maxAge: 0)
        let selectors = ["system", key.rawValue]
        let full = try await gui.history(HistoryRequest(series: selectors, cursor: ""))
        #expect(full.count == 2)
        let cursor = try #require(full.first?.nextCursor)
        #expect(full.last?.nextCursor == cursor)
        fixture.clock.advance(by: 1_000_000_000)
        _ = try await fixture.scheduler.freshSnapshot(maxAge: 0)
        let delta = try await gui.history(HistoryRequest(series: selectors, cursor: cursor))
        #expect(delta.allSatisfy { $0.isDelta && $0.points.count == 1 })
        let legacy = try await gui.history(HistoryRequest(series: selectors))
        #expect(legacy.allSatisfy { $0.nextCursor == nil && !$0.isDelta && $0.retainedPointCount == nil })
        await expectAgentError(.invalidArgument) {
            _ = try await gui.history(HistoryRequest(series: selectors, cursor: String(repeating: "x", count: 65537)))
        }
        let reset = try await gui.history(HistoryRequest(series: selectors, cursor: "unknown"))
        #expect(reset.allSatisfy { !$0.isDelta })
        let overlapping = try await gui.history(HistoryRequest(series: ["system", "system"], cursor: cursor))
        #expect(overlapping.allSatisfy { $0.nextCursor == nil })
        await gui.invalidate()
        await fixture.close()
    }

    @Test func threeSnapshotPollersHitOneScopedResponseCache() async throws {
        let fixture = try ServiceFixture()
        let clients = (0 ..< 3).map { _ in fixture.client(flags: nil) }
        for client in clients {
            let snapshot = try await client.snapshot(top: 50, sort: .cpu)
            #expect(!snapshot.processes.contains { !$0.isOwn })
            #expect(await fixture.scheduler.responseCacheCount == 1)
        }
        #expect(await fixture.scheduler.diagnostics().collectionsTotal == 1)
        for client in clients {
            await client.invalidate()
        }
        await fixture.close()
    }

    @Test func enumerationFailureReturnsUnavailableAndRecoversWithoutLosingBaselines() async throws {
        let fixture = try ServiceFixture()
        let client = fixture.client()
        let first = try await client.snapshot(top: 200, sort: .pid)
        #expect(first.status == .warmingUp)
        #expect(!first.processes.isEmpty)
        fixture.source.update { $0.enumerationError = .enumerationFailed }
        fixture.clock.advance(by: 6_000_000_000)
        let failed = try await client.snapshot(top: 200, sort: .pid)
        #expect(failed.status == .unavailable)
        #expect(failed.snapshotID != first.snapshotID)
        #expect(failed.processes.isEmpty)
        #expect(failed.coverage == Coverage())
        let page = try await client.listProcesses(ProcessQuery(filter: .all))
        #expect(page.snapshot.status == .unavailable)
        #expect(page.snapshot.snapshotID == failed.snapshotID)
        #expect(page.items.isEmpty)
        let status = try await client.status()
        #expect(status.failures == ["unavailable": 1])
        #expect(status.collectionsTotal == 2)
        let failedHistory = try await client.history(HistoryRequest(series: ["system"]))
        #expect(failedHistory.first?.points.count == 1)
        #expect(failedHistory.first?.gaps.count == 1)
        fixture.source.update {
            $0.enumerationError = nil
            $0.processes[42]?.rusage.cpuTimeNS += 2_400_000_000
        }
        fixture.clock.advance(by: 6_000_000_000)
        let recovered = try await client.snapshot(top: 200, sort: .pid)
        #expect(recovered.status == .ok)
        #expect(recovered.intervalMS == 12000)
        #expect(recovered.processes.first { $0.pid == 42 }?.cpuPercent == .ok(20))
        let recoveredHistory = try await client.history(HistoryRequest(series: ["system"]))
        #expect(recoveredHistory.first?.points.count == 2)
        #expect(recoveredHistory.first?.gaps.count == 1)
        #expect(try await client.status().failures == ["unavailable": 1])
        await client.invalidate()
        await fixture.close()
    }

    @Test func statusFallsBackToDirectFootprintWithoutInventingMeasurements() async throws {
        let fixture = try ServiceFixture(omitAgentRow: true)
        let client = fixture.client()
        let status = try await client.status()
        #expect(status.agentFootprintBytes == UInt64(getpid()) * 100)
        #expect(status.clients.first?.footprintBytes == UInt64(getpid()) * 100)
        #expect(status.agentCPUPercent.value == nil)
        fixture.source.update { $0.processErrors[getpid()] = .permissionDenied }
        await expectAgentError(.agentUnavailable) { _ = try await client.status() }
        await client.invalidate()
        await fixture.close()
    }

    @Test func settingsRevocationAppliesWithoutReconnectAndExpiredProcessIsNotFound() async throws {
        let fixture = try ServiceFixture()
        let client = fixture.client()
        #expect(try await client.process(key: fixture.key()).path != nil)
        let ticket = try await client.prepareTermination(key: fixture.key(), signal: .kill)
        fixture.settings.setAllowedPermissions([.terminate])
        await expectAgentError(.permissionDenied) { _ = try await client.terminate(token: ticket.token) }
        #expect(fixture.signals.isEmpty)
        #expect(try await client.process(key: fixture.key()).path == nil)
        await expectAgentError(.notFound) { _ = try await client.process(key: fixture.key(84)) }
        await expectAgentError(.permissionDenied) { _ = try await client.startObservation(ObservationRequest(intervalMS: .oneSecond, durationMS: 1000)) }
        fixture.source.removeProcess(pid: 42)
        await expectAgentError(.notFound) { _ = try await client.process(key: fixture.key()) }
        await client.invalidate()
        await fixture.close()
    }

    @Test func historyChecksProcessAndObservationScopeAndPinsUseStoreQueries() async throws {
        let fixture = try ServiceFixture()
        let gui = fixture.client(.gui)
        let owner = fixture.client(flags: [.observe, .includeSystem])
        let other = fixture.client(flags: [.observe])
        try await gui.pin(key: fixture.key(), pinned: true)
        let pinned = try await gui.listProcesses(ProcessQuery(filter: .pinned))
        #expect(try pinned.items.map(\.processKey) == [fixture.key()])
        let observation = try await owner.startObservation(ObservationRequest(intervalMS: .fiveSeconds, durationMS: 10000,
                                                                              processKeys: [fixture.key(84)]))
        let ownObservation = try await other.startObservation(ObservationRequest(intervalMS: .fiveSeconds, durationMS: 10000,
                                                                                 processKeys: [fixture.key()]))
        #expect(try await other.history(HistoryRequest(series: [ownObservation.observationID])).map(\.series) == [fixture.key().rawValue])
        #expect(try await gui.history(HistoryRequest(series: ["system", fixture.key().rawValue])).count == 2)
        await expectAgentError(.notFound) { _ = try await other.history(HistoryRequest(series: [fixture.key(84).rawValue])) }
        await expectAgentError(.permissionDenied) { _ = try await other.history(HistoryRequest(series: [observation.observationID])) }
        await expectAgentError(.notFound) {
            _ = try await other.startObservation(ObservationRequest(intervalMS: .fiveSeconds, durationMS: 10000, processKeys: [fixture.key(84)]))
        }
        fixture.settings.setAllowedPermissions([.observe])
        await expectAgentError(.notFound) { _ = try await owner.history(HistoryRequest(series: [observation.observationID])) }
        await expectAgentError(.invalidProcessKey) { _ = try await other.history(HistoryRequest(series: ["p1.bad"])) }
        await expectAgentError(.invalidArgument) { _ = try await other.history(HistoryRequest(series: [])) }
        fixture.source.removeProcess(pid: 42)
        fixture.clock.advance(by: 6_000_000_000)
        _ = try await fixture.scheduler.freshSnapshot(maxAge: 0)
        #expect(try await other.history(HistoryRequest(series: [fixture.key().rawValue])).map(\.series) == [fixture.key().rawValue])
        #expect(try await other.history(HistoryRequest(series: [ownObservation.observationID])).count == 1)
        // Unpinning must still work after the process has gone away.
        try await gui.pin(key: fixture.key(), pinned: false)
        await gui.invalidate()
        await owner.invalidate()
        await other.invalidate()
        await fixture.close()
    }

    @Test func disconnectRemovesObservationsLeasesAndTokens() async throws {
        let fixture = try ServiceFixture()
        let gui = fixture.client(.gui)
        let observer = fixture.client()
        let observation = try await observer.startObservation(ObservationRequest(intervalMS: .twoSeconds, durationMS: 30000,
                                                                                 processKeys: [fixture.key()]))
        let ticket = try await observer.prepareTermination(key: fixture.key(), signal: .term)
        let lease = try await gui.setLease(LeaseRequest(kind: .menuBar, intervalMS: .tenSeconds))
        var disconnected = fixture.disconnected.makeAsyncIterator()
        await observer.invalidate()
        let context = try #require(await disconnected.next())
        await #expect(throws: (any Error).self) { try await fixture.observations.observation(id: observation.observationID, clientID: context.clientID) }
        #expect(await fixture.scheduler.diagnostics().leases.map(\.kind) == [.menuBar])
        #expect(await fixture.service.handle(.terminate(token: ticket.token), from: context) == .error(.agentUnavailable("Client disconnected")))
        let reconnected = fixture.client()
        #expect(try await reconnected.terminate(token: ticket.token).rejection == .tokenForeign)
        await gui.invalidate()
        let guiContext = try #require(await disconnected.next())
        #expect(guiContext.clientID == lease.clientID)
        #expect(await fixture.scheduler.effectiveInterval == nil)
        #expect(fixture.signals.isEmpty)
        await reconnected.invalidate()
        await fixture.close()
    }
}
