import Foundation
@testable import ProcglintAgentKit
import ProcglintCore
import ProcglintIPC
import Testing

@Suite(.timeLimit(.minutes(1)))
struct GUILeaseHistoryServiceTests {
    @Test func leaseKeysRequireGUIWindowAndVisibleProcesses() async throws {
        let fixture = try ServiceFixture(permissions: [])
        let gui = fixture.client(.gui)
        let mcp = fixture.client()
        let request = try LeaseRequest(kind: .guiWindow, intervalMS: .fiveSeconds, processKeys: [fixture.key()])
        await expectAgentError(.permissionDenied) { _ = try await mcp.setLease(request) }
        let foreign = try LeaseRequest(kind: .guiWindow, intervalMS: .fiveSeconds, processKeys: [fixture.key(84)])
        await expectAgentError(.notFound) { _ = try await gui.setLease(foreign) }
        let missing = try LeaseRequest(kind: .guiWindow, intervalMS: .fiveSeconds, processKeys: [fixture.key(999)])
        await expectAgentError(.notFound) { _ = try await gui.setLease(missing) }
        #expect(await fixture.scheduler.diagnostics().leases.isEmpty)
        let context = await fixture.connect(id: "gui-direct", pid: 800, kind: .gui)
        var invalid = request
        invalid.kind = .menuBar
        let response = await fixture.service.handle(.setLease(invalid), from: context)
        guard case let .error(error) = response else {
            Issue.record("Menu bar process_keys were accepted")
            await fixture.close()
            return
        }
        #expect(error.code == .invalidArgument)
        let lease = try await gui.setLease(request)
        #expect(lease.kind == .guiWindow)
        #expect(try await gui.history(HistoryRequest(series: [fixture.key().rawValue])).first?.points.count == 1)
        await gui.invalidate()
        await mcp.invalidate()
        await fixture.close()
    }

    @Test func selectedHistoryUsesSharedLimitsAndRetainsScopeAfterExit() async throws {
        let fixture = try ServiceFixture(policy: SamplingPolicy(maxProcessSeries: 1))
        let gui = fixture.client(.gui)
        let reader = fixture.client(flags: nil)
        let key = try fixture.key()
        try await gui.pin(key: key, pinned: true)
        let request = try LeaseRequest(kind: .guiWindow, intervalMS: .fiveSeconds, processKeys: [key])
        let lease = try await gui.setLease(request)
        fixture.clock.advance(by: 5_000_000_000)
        _ = try await fixture.scheduler.freshSnapshot(maxAge: 0)
        let selected = try await gui.history(HistoryRequest(series: [key.rawValue]))
        #expect(selected.first?.points.isEmpty == false)
        await expectAgentError(.historyLimitReached) {
            _ = try await gui.setLease(LeaseRequest(kind: .guiWindow, intervalMS: .fiveSeconds, processKeys: [fixture.key(800)]))
        }
        try await gui.releaseLease(id: lease.leaseID)
        let retained = try #require(selected.first?.points)
        fixture.source.removeProcess(pid: 42)
        fixture.clock.advance(by: 5_000_000_000)
        _ = try await fixture.scheduler.freshSnapshot(maxAge: 0)
        #expect(try await reader.history(HistoryRequest(series: [key.rawValue])).first?.points == retained)
        await gui.invalidate()
        await reader.invalidate()
        await fixture.close()
    }

    @Test func unselectedLiveAndExitedHistoryEnforcesEveryClientScope() async throws {
        let fixture = try ServiceFixture()
        let gui = fixture.client(.gui)
        let cli = fixture.client(.cli)
        let narrow = fixture.client(flags: [])
        let broad = fixture.client(flags: [.includeSystem])
        let own = try fixture.key()
        let foreign = try fixture.key(84)
        // No key is ever pinned, selected, or observed.
        _ = try await gui.setLease(LeaseRequest(kind: .guiWindow, intervalMS: .tenSeconds))
        _ = try await fixture.scheduler.freshSnapshot()
        for reader in [gui, cli, broad] {
            #expect(try await reader.history(HistoryRequest(series: [foreign.rawValue])).first?.points.isEmpty == false)
        }
        await expectAgentError(.notFound) { _ = try await narrow.history(HistoryRequest(series: [foreign.rawValue])) }
        fixture.source.removeProcess(pid: 42)
        fixture.source.removeProcess(pid: 84)
        fixture.clock.advance(by: 5_000_000_000)
        _ = try await fixture.scheduler.freshSnapshot(maxAge: 0)
        for reader in [gui, cli, narrow, broad] {
            #expect(try await reader.history(HistoryRequest(series: [own.rawValue])).first?.points.count == 1)
        }
        for reader in [gui, cli, broad] {
            #expect(try await reader.history(HistoryRequest(series: [foreign.rawValue])).first?.points.count == 1)
        }
        await expectAgentError(.notFound) { _ = try await narrow.history(HistoryRequest(series: [foreign.rawValue])) }
        fixture.settings.setAllowedPermissions([])
        for reader in [gui, cli, broad] {
            await expectAgentError(.notFound) { _ = try await reader.history(HistoryRequest(series: [foreign.rawValue])) }
        }
        fixture.clock.advance(by: 601_000_000_000)
        await expectAgentError(.notFound) { _ = try await narrow.history(HistoryRequest(series: [own.rawValue])) }
        for reader in [gui, cli, narrow, broad] {
            await reader.invalidate()
        }
        await fixture.close()
    }

    @Test func selectionDoesNotExposeForeignRetainedHistoryToNarrowScope() async throws {
        let fixture = try ServiceFixture()
        let gui = fixture.client(.gui)
        let key = try fixture.key(84)
        _ = try await gui.setLease(LeaseRequest(kind: .guiWindow, intervalMS: .fiveSeconds, processKeys: [key]))
        fixture.clock.advance(by: 5_000_000_000)
        _ = try await fixture.scheduler.freshSnapshot(maxAge: 0)
        fixture.source.removeProcess(pid: 84)
        fixture.clock.advance(by: 5_000_000_000)
        _ = try await fixture.scheduler.freshSnapshot(maxAge: 0)
        #expect(try await gui.history(HistoryRequest(series: [key.rawValue])).count == 1)
        fixture.settings.setAllowedPermissions([])
        await expectAgentError(.notFound) { _ = try await gui.history(HistoryRequest(series: [key.rawValue])) }
        await gui.invalidate()
        await fixture.close()
    }
}
