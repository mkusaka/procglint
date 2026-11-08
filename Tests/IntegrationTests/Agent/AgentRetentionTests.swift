import Foundation
@testable import ProcglintAgentKit
@testable import ProcglintCore
import ProcglintIPC
import Testing

@Suite(.timeLimit(.minutes(1)))
struct AgentRetentionTests {
    @Test func spawnExitChurnAndPIDReuseDoNotTransferHistorySelectionOrTerminationTargets() async throws {
        let h = try AgentHarness()
        let gui = h.client(.gui)
        try await h.warm(gui)
        let selected = try h.key()
        try await gui.pin(key: selected, pinned: true)
        let ticket = try await gui.prepareTermination(key: selected, signal: .term)
        var priorKeys: Set<ProcessKey> = []
        for generation in 0 ..< 200 {
            h.source.update { state in
                for pid: Int32 in 1000 ..< 1020 {
                    state.processes[pid] = AgentHarness.worker(pid: pid, start: UInt64(generation + 200))
                }
            }
            h.advance(seconds: 5)
            let snapshot = try await h.scheduler.freshSnapshot(maxAge: 0, scope: AccessScope(includeSystem: true))
            let keys = Set(snapshot.processes.filter { $0.pid >= 1000 && $0.pid < 1020 }.map(\.processKey))
            #expect(keys.count == 20)
            #expect(priorKeys.isDisjoint(with: keys))
            priorKeys = keys
            #expect(await h.sampler.cachedProcessCount == snapshot.processes.count)
            #expect(await h.sampler.cachedReadingCount == snapshot.processes.count)
        }
        let before = try await gui.history(HistoryRequest(series: [selected.rawValue]))
        let lastOldPoint = try #require(before.first?.points.last)
        // A fresh ticket keeps the PID-reuse rejection distinct from token expiry after the churn run.
        let freshTicket = try await gui.prepareTermination(key: selected, signal: .term)
        var replacement = AgentHarness.worker(pid: 42, start: 101)
        replacement.bsdInfo.name = "replacement"
        replacement.path = "/private/replacement"
        replacement.rusage.footprintBytes = 98765
        h.source.addProcess(pid: 42, process: replacement)
        h.advance(seconds: 6)
        let page = try await gui.listProcesses(ProcessQuery(filter: .all, sort: .pid, limit: 200))
        let reused = try #require(page.items.first { $0.pid == 42 })
        #expect(try reused.processKey == h.key(start: 101))
        #expect(reused.processKey != selected)
        #expect(!page.items.contains { $0.processKey == selected })
        #expect(reused.cpuPercent.status == .warmingUp)
        #expect(try await gui.process(key: reused.processKey).path == "/private/replacement")
        await integrationError(.notFound) { _ = try await gui.process(key: selected) }
        let pinned = try await gui.listProcesses(ProcessQuery(filter: .pinned, limit: 200))
        #expect(!pinned.items.contains { $0.processKey == reused.processKey })
        let oldHistory = try #require(try await gui.history(HistoryRequest(series: [selected.rawValue])).first)
        #expect(oldHistory.points.last == lastOldPoint)
        #expect(!oldHistory.points.contains { $0.footprintBytes?.value == 98765 })
        #expect(!oldHistory.gaps.isEmpty)
        await integrationError(.notFound) { _ = try await gui.history(HistoryRequest(series: [reused.processKey.rawValue])) }
        #expect(try await gui.terminate(token: freshTicket.token).rejection == .processChanged)
        #expect(try await gui.terminate(token: ticket.token).outcome == .rejected)
        #expect(h.signals.pids.withLock { $0.isEmpty })
        await gui.invalidate()
        await h.close()
    }

    @Test func accelerated24HourSoakKeepsInternalStorageBounded() async throws {
        let h = try AgentHarness()
        let gui = h.client(.gui)
        let mcp = h.client(flags: [.observe])
        for pid: Int32 in 200 ..< 216 {
            h.source.addProcess(pid: pid, process: AgentHarness.worker(pid: pid))
        }
        try await h.warm(gui)
        for pid: Int32 in 200 ..< 216 {
            try await gui.pin(key: h.key(pid), pinned: true)
        }
        let request = try LeaseRequest(kind: .guiWindow, intervalMS: .fiveSeconds)
        let lease = try await gui.setLease(request)
        #expect(await h.scheduler.historyBytesEstimate() <= 8 * 1024 * 1024)
        // Exercise the full history allocation, then retain four live series to keep the debug soak fast.
        for pid: Int32 in 204 ..< 216 {
            try await h.scheduler.pin(key: h.key(pid), pinned: false)
            h.source.removeProcess(pid: pid)
        }
        let auditClient = TerminationController.Client(clientID: lease.clientID, kind: .gui, pid: getpid(), protectedPIDs: [])
        for _ in 0 ..< 80 {
            _ = try await h.termination.prepare(key: h.key(), signal: .term, client: auditClient, permissions: .all)
        }
        #expect(await h.termination.retainedTokenCount == 64)
        var samples = await h.scheduler.subscribe(scope: AccessScope(includeSystem: true)).makeAsyncIterator()
        _ = await samples.next()
        for step in 1 ... 17280 {
            h.source.update { state in
                for pid: Int32 in 1000 ..< 1004 {
                    state.processes[pid] = AgentHarness.worker(pid: pid, start: UInt64(step + 100))
                }
                for pid: Int32 in 200 ..< 204 {
                    state.processes[pid]?.rusage.cpuTimeNS += 1_000_000_000
                }
                state.cpuTicks.user += 1
                state.cpuTicks.idle += 9
            }
            h.advance(seconds: 5)
            _ = try await h.next(&samples)
            if step.isMultiple(of: 5) {
                // Renew the real scheduler lease without paying for 3,456 redundant JSON/XPC round trips.
                _ = try await h.scheduler.setLease(request, clientID: lease.clientID)
            }
            // Crossing the ten-minute window also exercises pruning of churned observation identities.
            if step.isMultiple(of: 121) {
                _ = try await gui.prepareTermination(key: h.key(), signal: .term)
                let observed = try h.key(1000, start: UInt64(step + 100))
                _ = try await mcp.startObservation(ObservationRequest(intervalMS: .tenSeconds, durationMS: 1000, processKeys: [observed]))
                await h.service.housekeeping()
            }
            if step.isMultiple(of: 600) {
                let status = try await gui.status()
                #expect(status.historyBytes <= 8 * 1024 * 1024)
                #expect(status.collectionsTotal == UInt64(step + 2))
                #expect(await h.sampler.cachedProcessCount == 12)
                #expect(await h.sampler.cachedReadingCount == 12)
                #expect(await h.sampler.cachedUserCount <= 3)
                #expect(await h.scheduler.retainedSnapshotCount == 2)
                #expect(await h.scheduler.responseCacheCount <= 8)
                #expect(await h.termination.retainedTokenCount <= 64)
                #expect(await h.service.retainedTicketCount <= 64)
                #expect(await h.service.retainedHistoryOwnershipCount <= 16)
                #expect(await h.observations.retainedObservationCount <= 2)
            }
        }
        #expect(h.clock.now == 86401 * 1_000_000_000)
        #expect(await h.scheduler.diagnostics().collectionsTotal == 17282)
        #expect(await h.scheduler.historyBytesEstimate() <= 8 * 1024 * 1024)
        let histories = try await gui.history(HistoryRequest(series: ["system"] + (200 ..< 204).map { try h.key(Int32($0)).rawValue }))
        #expect(histories.count == 5)
        #expect(histories.allSatisfy { !$0.points.isEmpty && $0.points.count <= 600 && $0.gaps.count <= 600 })
        #expect(histories.allSatisfy { ($0.points.last?.t.timeIntervalSince1970 ?? 0) - ($0.points.first?.t.timeIntervalSince1970 ?? 0) <= 600 })
        await gui.invalidate()
        await mcp.invalidate()
        await h.close()
    }
}
