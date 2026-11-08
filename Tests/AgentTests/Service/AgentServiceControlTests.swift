import Foundation
@testable import ProcglintAgentKit
import ProcglintCore
import ProcglintIPC
import Testing

@Suite(.timeLimit(.minutes(1)))
struct AgentServiceControlTests {
    @Test func terminationProtectsAgentClientsAndParentChainAndRechecksAtExecution() async throws {
        let fixture = try ServiceFixture()
        let client = fixture.client()
        let other = await fixture.connect(id: "client-other", pid: 801)
        for pid in [getpid(), 700, 701, 801] {
            do {
                _ = try await client.prepareTermination(key: fixture.key(pid), signal: .term)
                Issue.record("Protected PID accepted: \(pid)")
            } catch let error as AgentError {
                #expect(error.rejection == .self)
            }
        }
        do {
            _ = try await client.prepareTermination(key: fixture.key(1), signal: .term)
            Issue.record("launchd accepted")
        } catch let error as AgentError { #expect(error.rejection == .protectedPID) }
        do {
            _ = try await client.prepareTermination(key: fixture.key(84), signal: .term)
            Issue.record("Foreign UID accepted")
        } catch let error as AgentError { #expect(error.rejection == .notOwnProcess) }
        let ticket = try await client.prepareTermination(key: fixture.key(800), signal: .term)
        let newlyConnected = await fixture.connect(id: "new-client", pid: 800)
        #expect(try await client.terminate(token: ticket.token).rejection == .self)
        #expect(fixture.signals.isEmpty)
        let target = try await client.prepareTermination(key: fixture.key(), signal: .term)
        fixture.source.update { $0.processes[42]?.bsdInfo.startTimeUS = 101 }
        #expect(try await client.terminate(token: target.token).rejection == .processChanged)
        #expect(fixture.signals.isEmpty)
        await fixture.service.clientDisconnected(other)
        await fixture.service.clientDisconnected(newlyConnected)
        await client.invalidate()
        await fixture.close()
    }

    @Test func terminationFailsClosedWhenParentChainCannotBeVerified() async throws {
        let fixture = try ServiceFixture()
        let client = fixture.client()
        fixture.source.removeProcess(pid: 700)
        do {
            _ = try await client.prepareTermination(key: fixture.key(), signal: .term)
            Issue.record("Unverified parent chain accepted")
        } catch let error as AgentError { #expect(error.rejection == .permissionDenied) }
        fixture.source.update { $0.processes[getpid()]?.bsdInfo.ppid = getpid() }
        do {
            _ = try await client.prepareTermination(key: fixture.key(), signal: .term)
            Issue.record("Cyclic parent chain accepted")
        } catch let error as AgentError { #expect(error.rejection == .permissionDenied) }
        #expect(fixture.signals.isEmpty)
        await client.invalidate()
        await fixture.close()
    }

    @Test func successfulTerminationUsesCoreConfirmationAndSingleUseTicket() async throws {
        let fixture = try ServiceFixture()
        let client = fixture.client()
        let ticket = try await client.prepareTermination(key: fixture.key(), signal: .term)
        let termination = Task { try await client.terminate(token: ticket.token) }
        var sleeps = fixture.confirmationSleeps.makeAsyncIterator()
        #expect(await sleeps.next() == 500_000_000)
        #expect(fixture.signals == [42])
        fixture.source.removeProcess(pid: 42)
        fixture.clock.advance(by: 500_000_000)
        let result = try await termination.value
        #expect(result.outcome == .signalSent)
        #expect(result.exitedConfirmed)
        #expect(try await client.terminate(token: ticket.token).rejection == .tokenUsed)
        let audit = try String(contentsOf: fixture.directory.appendingPathComponent("audit.jsonl"), encoding: .utf8)
        #expect(audit.split(separator: "\n").count == 3)
        await client.invalidate()
        await fixture.close()
    }

    @Test func policyPersistenceFailureRollsBackHistoryPolicy() async throws {
        let settings = try FailingPolicySettings(policy: SamplingPolicy())
        let fixture = try ServiceFixture(settingsOverride: settings)
        let client = fixture.client(.gui)
        let proposed = try SamplingPolicy(maxProcessSeries: 1)
        await expectAgentError(.internalError) { _ = try await client.setPolicy(proposed, expectedRevision: 0) }
        #expect(try await client.policy() == settings.policy)
        try await client.pin(key: fixture.key(), pinned: true)
        try await client.pin(key: fixture.key(800), pinned: true)
        await client.invalidate()
        await fixture.close()
    }

    @Test func policyRevisionCheckIsAtomicAndHistoryLimitsAreApplied() async throws {
        let fixture = try ServiceFixture()
        let first = fixture.client(.gui)
        let second = fixture.client(flags: [.configure])
        let proposal = try SamplingPolicy(revision: 99, historyMinutes: 1, maxProcessSeries: 1)
        let results = await withTaskGroup(of: AgentError.Code?.self) { group in
            for client in [first, second] {
                group.addTask {
                    do { _ = try await client.setPolicy(proposal, expectedRevision: 0); return nil }
                    catch let error as AgentError { return error.code }
                    catch { return .internalError }
                }
            }
            var codes: [AgentError.Code?] = []
            for await code in group {
                codes.append(code)
            }
            return codes
        }
        #expect(results.filter { $0 == nil }.count == 1)
        #expect(results.filter { $0 == .revisionConflict }.count == 1)
        let policy = try await first.policy()
        #expect(policy.revision == 1)
        #expect(fixture.settings.samplingPolicy() == policy)
        #expect(policy.historyMinutes == 1)
        try await first.pin(key: fixture.key(), pinned: true)
        await expectAgentError(.historyLimitReached) { try await first.pin(key: fixture.key(800), pinned: true) }
        await expectAgentError(.revisionConflict) { _ = try await first.setPolicy(proposal, expectedRevision: 0) }
        await first.invalidate()
        await second.invalidate()
        await fixture.close()
    }

    @Test func readAndMutationRateLimitsAreAggregateIndependentAndRefill() async throws {
        let fixture = try ServiceFixture()
        let first = fixture.client(.gui)
        let second = fixture.client(.gui)
        for index in 0 ..< 120 {
            let client = index.isMultiple(of: 2) ? first : second
            #expect(try await client.policy().revision == 0)
        }
        await expectAgentError(.rateLimited) { _ = try await second.policy() }
        for index in 0 ..< 20 {
            let client = index.isMultiple(of: 2) ? first : second
            try await client.releaseLease(id: "absent")
        }
        await expectAgentError(.rateLimited) { try await first.releaseLease(id: "absent") }
        fixture.clock.advance(by: 1_000_000_000)
        #expect(try await first.policy().revision == 0)
        try await second.releaseLease(id: "absent")
        await first.invalidate()
        await second.invalidate()
        await fixture.close()
    }

    @Test func wakeDetectionRecordsGapAndDropsExpiredLeases() async throws {
        let fixture = try ServiceFixture()
        let client = fixture.client(.gui)
        _ = try await client.setLease(LeaseRequest(kind: .guiWindow, intervalMS: .tenSeconds))
        _ = try await client.snapshot(top: 1, sort: .pid)
        await fixture.service.housekeeping()
        fixture.clock.advance(by: 5_000_000_000)
        fixture.uptime.advance(by: 1_000_000_000)
        await fixture.service.housekeeping()
        #expect(await fixture.scheduler.effectiveInterval == .tenSeconds)
        fixture.clock.advance(by: 1_000_000_000)
        fixture.uptime.advance(by: 1_000_000_000)
        let series = try await fixture.scheduler.history(series: "system")
        #expect(!series.gaps.isEmpty)
        fixture.clock.advance(by: 40_000_000_000)
        await fixture.service.housekeeping()
        #expect(await fixture.scheduler.effectiveInterval == nil)
        #expect(fixture.exits == 0)
        await client.invalidate()
        await fixture.close()
    }

    @Test func idleConnectionsUseOneHousekeepingDeadlinePerMinute() async throws {
        let fixture = try ServiceFixture()
        await fixture.service.start()
        #expect(await fixture.service.housekeepingDeadline == 60_000_000_000)
        let context = await fixture.connect(id: "idle-client", pid: 800, kind: .gui)
        #expect(await fixture.service.housekeepingDeadline == 60_000_000_000)
        let response = try await fixture.service.handle(.setLease(LeaseRequest(kind: .guiWindow, intervalMS: .fiveSeconds)), from: context)
        guard case let .setLease(lease) = response else { Issue.record("Expected lease"); return }
        #expect(await fixture.service.housekeepingDeadline == 5_000_000_000)
        _ = await fixture.service.handle(.releaseLease(id: lease.leaseID), from: context)
        #expect(await fixture.service.housekeepingDeadline == 60_000_000_000)
        fixture.clock.advance(by: 9_000_000_000)
        await fixture.service.clientDisconnected(context)
        #expect(await fixture.service.housekeepingDeadline == 69_000_000_000)
        await fixture.close()
    }

    @Test func idleExitUsesMonotonicGraceAndConnectedClientsPreventExit() async throws {
        let fixture = try ServiceFixture()
        await fixture.service.start()
        fixture.clock.advance(by: 59_000_000_000)
        await fixture.service.housekeeping()
        #expect(fixture.exits == 0)
        let context = await fixture.connect(id: "idle-client", pid: 800)
        fixture.clock.advance(by: 120_000_000_000)
        await fixture.service.housekeeping()
        #expect(fixture.exits == 0)
        await fixture.service.clientDisconnected(context)
        fixture.clock.advance(by: 59_000_000_000)
        await fixture.service.housekeeping()
        #expect(fixture.exits == 0)
        fixture.clock.advance(by: 1_000_000_000)
        await fixture.service.housekeeping()
        await fixture.service.housekeeping()
        #expect(fixture.exits == 1)
        await fixture.close()
    }
}

private struct FailingPolicySettings: SettingsStore {
    let policy: SamplingPolicy
    func samplingPolicy() -> SamplingPolicy {
        policy
    }

    func allowedPermissions() -> PermissionSet {
        .all
    }

    func setAllowedPermissions(_: PermissionSet) throws {
        throw AgentError.internalError("Settings unavailable")
    }

    func setSamplingPolicy(_: SamplingPolicy) throws {
        throw AgentError.internalError("Settings unavailable")
    }
}
