import Foundation
@testable import ProcglintAgentKit
@testable import ProcglintCore
import ProcglintIPC
@testable import ProcglintMCPKit
import Testing

@Suite(.timeLimit(.minutes(1)))
struct AgentIntegrationTests {
    @Test func guiPlusThreeMCPConnectionsShareCollectionsAndIsolateScopes() async throws {
        let h = try AgentHarness()
        let gui = h.client(.gui)
        let clients = [h.client(), h.client(flags: [.includeSystem]), h.client(flags: [.includeSystem, .includePaths])]
        let servers = [h.server(clients[0]), h.server(clients[1], flags: [.includeSystem]),
                       h.server(clients[2], flags: [.includeSystem, .includePaths])]
        var samples = await h.scheduler.subscribe(scope: AccessScope(includeSystem: true)).makeAsyncIterator()
        _ = try await gui.setLease(LeaseRequest(kind: .guiWindow, intervalMS: .fiveSeconds))
        let first = try await concurrentSnapshots(gui: gui, servers: servers)
        _ = try await h.next(&samples)
        #expect(Set(first.map(\.snapshotID)).count == 1)
        #expect(await h.scheduler.diagnostics().collectionsTotal == 1)
        // Prime both the privileged response cache and lazy metadata path before the restricted read.
        let privileged = try await integrationCall(servers[2], "get_process", arguments: ["process_key": .string(h.key().rawValue)])
        #expect(privileged["path"] == "/private/worker-42")
        #expect(try await gui.process(key: h.key(84)).path == "/private/worker-84")
        let restricted = try await integrationCall(servers[0], "get_process", arguments: ["process_key": .string(h.key().rawValue)])
        #expect(try restricted.decode(ProcessSample.self).path == nil)
        await integrationError(.notFound) { _ = try await clients[0].process(key: h.key(84)) }
        try checkScopes(first)
        h.advance(seconds: 1)
        _ = try await h.next(&samples)
        for expected in 3 ... 5 {
            h.advance(seconds: 5)
            let snapshots = try await concurrentSnapshots(gui: gui, servers: servers)
            let sampled = try await h.next(&samples)
            #expect(Set(snapshots.map(\.snapshotID)) == [sampled.snapshotID])
            try checkScopes(snapshots)
            #expect(await h.scheduler.diagnostics().collectionsTotal == UInt64(expected))
        }
        for client in clients {
            await client.invalidate()
        }
        await gui.invalidate()
        await h.close()
    }

    @Test func guiClosesWhileMCPObservationContinuesOnlyUntilExpiry() async throws {
        let h = try AgentHarness()
        let gui = h.client(.gui)
        let mcp = h.client(flags: [.observe])
        let server = h.server(mcp, flags: [.observe])
        try await h.warm(gui)
        let lease = try await gui.setLease(LeaseRequest(kind: .guiWindow, intervalMS: .oneSecond))
        let value = try await integrationCall(server, "start_observation", arguments: ["interval_ms": 5000, "duration_ms": 16000])
        let observation = try value.decode(Observation.self)
        var disconnected = h.disconnected.makeAsyncIterator()
        try await gui.releaseLease(id: lease.leaseID)
        await gui.invalidate()
        #expect(await disconnected.next()?.clientID == lease.clientID)
        #expect(await h.scheduler.effectiveInterval == .fiveSeconds)
        var samples = await h.scheduler.subscribe(scope: AccessScope()).makeAsyncIterator()
        _ = await samples.next()
        for _ in 0 ..< 3 {
            #expect(await h.scheduler.nextCollectionWindow?.lowerBound == h.clock.now + 5_000_000_000)
            h.advance(seconds: 5)
            #expect(try await h.next(&samples).intervalMS == 5000)
        }
        h.advance(seconds: 1)
        #expect(try await h.observations.observation(id: observation.observationID, clientID: (mcp.status()).clients[0].clientID).state == .expired)
        let status = try await mcp.status()
        #expect(status.clients.count == 1)
        #expect(status.clients.first?.kind == .mcp)
        #expect(!status.samplingActive)
        #expect(status.leases.isEmpty)
        #expect(status.collectionsTotal == 5)
        #expect(await h.scheduler.nextCollectionWindow == nil)
        h.advance(seconds: 3600)
        #expect(await h.scheduler.diagnostics().collectionsTotal == 5)
        await mcp.invalidate()
        await h.close()
    }

    @Test func idleMCPConnectionHasZeroPeriodicCollections() async throws {
        let h = try AgentHarness()
        let client = h.client()
        let server = h.server(client)
        // History authenticates the real connection without a read that intentionally cold-starts sampling.
        _ = try await integrationCall(server, "get_history", arguments: ["series": ["system"]])
        for _ in 0 ..< 24 {
            h.advance(seconds: 3600)
            await h.service.housekeeping()
            #expect(await h.scheduler.diagnostics().collectionsTotal == 0)
            #expect(await h.scheduler.nextCollectionWindow == nil)
        }
        _ = try await integrationCall(server, "get_history", arguments: ["series": ["system"]])
        #expect(await h.scheduler.diagnostics().collectionsTotal == 0)
        await client.invalidate()
        await h.close()
    }

    @Test(arguments: [false, true])
    func mcpEOFOrAbruptInvalidationRemovesObservationsAndLeases(abrupt: Bool) async throws {
        let h = try AgentHarness()
        let gui = h.client(.gui)
        try await h.warm(gui)
        let client = h.client(flags: [.observe])
        let server = h.server(client, flags: [.observe])
        let input = Pipe()
        let output = Pipe()
        defer {
            try? input.fileHandleForReading.close()
            try? input.fileHandleForWriting.close()
            try? output.fileHandleForReading.close()
            try? output.fileHandleForWriting.close()
        }
        // This is the executable's EOF lifecycle, including its explicit XPC invalidation.
        let run = Task {
            await server.run(input: input.fileHandleForReading, output: output.fileHandleForWriting)
            await client.invalidate()
        }
        let request = try integrationRequest("start_observation", arguments: ["interval_ms": 1000, "duration_ms": 60000])
        try input.fileHandleForWriting.write(contentsOf: Data((request + "\n").utf8))
        let reader = MCPLineReader(input: output.fileHandleForReading)
        let response = try JSONValue.parse(#require(await reader.next()))
        let observation = try #require(response["result"]?["structuredContent"]).decode(Observation.self)
        let status = try await gui.status()
        let owner = try #require(status.clients.first { $0.kind == .mcp })
        #expect(status.leases.count == 1)
        #expect(status.samplingActive)
        var disconnected = h.disconnected.makeAsyncIterator()
        if abrupt {
            await client.invalidate()
        }
        try input.fileHandleForWriting.close()
        await run.value
        #expect(await disconnected.next()?.clientID == owner.clientID)
        await integrationError(.notFound) { _ = try await h.observations.observation(id: observation.observationID, clientID: owner.clientID) }
        let cleaned = try await gui.status()
        #expect(cleaned.leases.isEmpty)
        #expect(!cleaned.samplingActive)
        #expect(cleaned.clients.map(\.kind) == [.gui])
        #expect(await h.scheduler.nextCollectionWindow == nil)
        h.advance(seconds: 3600)
        #expect(await h.scheduler.diagnostics().collectionsTotal == 2)
        await gui.invalidate()
        await h.close()
    }

    @Test func stdoutReadStallDoesNotStopSharedSamplerForGUI() async throws {
        let h = try AgentHarness()
        let gui = h.client(.gui)
        try await h.warm(gui)
        _ = try await gui.setLease(LeaseRequest(kind: .guiWindow, intervalMS: .oneSecond))
        let client = h.client()
        let server = h.server(client)
        let input = Pipe()
        let output = Pipe()
        defer {
            try? input.fileHandleForReading.close()
            try? input.fileHandleForWriting.close()
            try? output.fileHandleForReading.close()
            try? output.fileHandleForWriting.close()
        }
        let filledBytes = try fillPipe(output.fileHandleForWriting)
        var handled = h.handled.makeAsyncIterator()
        let run = Task {
            await server.run(input: input.fileHandleForReading, output: output.fileHandleForWriting)
            await client.invalidate()
        }
        let request = try integrationRequest("get_process", arguments: ["process_key": .string(h.key().rawValue)])
        try input.fileHandleForWriting.write(contentsOf: Data((request + "\n").utf8))
        while let request = await handled.next() {
            if case .process = request {
                break
            }
        }
        var samples = await h.scheduler.subscribe(scope: AccessScope()).makeAsyncIterator()
        _ = await samples.next()
        for expected in 3 ... 6 {
            h.source.update { $0.processes[42]?.rusage.cpuTimeNS += 500_000_000 }
            h.advance(seconds: 1)
            let sampled = try await h.next(&samples)
            let visible = try await gui.snapshot(top: 200, sort: .pid)
            #expect(visible.snapshotID == sampled.snapshotID)
            #expect(visible.ageMS == 0)
            #expect(visible.processes.first { $0.pid == 42 }?.cpuPercent == .ok(50))
            #expect(await h.scheduler.diagnostics().collectionsTotal == UInt64(expected))
            var descriptor = pollfd(fd: output.fileHandleForWriting.fileDescriptor, events: Int16(POLLOUT), revents: 0)
            #expect(poll(&descriptor, 1, 0) == 0)
        }
        // Only cleanup reads stdout; until here the pipe was full and never consumed.
        try input.fileHandleForWriting.close()
        let drain = Task.detached { () throws -> Int in
            var count = 0
            var buffer = [UInt8](repeating: 0, count: 8192)
            while true {
                let size = Darwin.read(output.fileHandleForReading.fileDescriptor, &buffer, buffer.count)
                if size == 0 {
                    return count
                }
                guard size > 0 else { throw POSIXError(.EIO) }
                count += size
            }
        }
        await run.value
        try output.fileHandleForWriting.close()
        #expect(try await drain.value > filledBytes)
        await gui.invalidate()
        await h.close()
    }

    @Test func sleepWakeExpiresObservationRecordsGapAndUsesActualCPUDelta() async throws {
        let h = try AgentHarness()
        let gui = h.client(.gui)
        let mcp = h.client(flags: [.observe])
        try await h.warm(gui)
        try await gui.pin(key: h.key(), pinned: true)
        let observation = try await mcp.startObservation(ObservationRequest(intervalMS: .fiveSeconds, durationMS: 10000, processKeys: [h.key()]))
        let owner = try #require(try await gui.status().clients.first { $0.kind == .mcp })
        var samples = await h.scheduler.subscribe(scope: AccessScope()).makeAsyncIterator()
        _ = await samples.next()
        h.source.update { $0.processes[42]?.rusage.cpuTimeNS += 1_000_000_000 }
        h.advance(seconds: 5)
        _ = try await h.next(&samples)
        await h.service.housekeeping()
        h.source.update { $0.processes[42]?.rusage.cpuTimeNS += 1_000_000_000 }
        h.advance(seconds: 120, sleeping: true)
        await h.service.housekeeping()
        #expect(await h.scheduler.diagnostics().leases.isEmpty)
        #expect(try await h.observations.observation(id: observation.observationID, clientID: owner.clientID).state == .expired)
        let postWake = try await gui.snapshot(top: 200, sort: .pid)
        let cpu = try #require(postWake.processes.first { $0.pid == 42 }).cpuPercent
        #expect(postWake.intervalMS == 120_000)
        if let value = cpu.value {
            #expect(cpu.status == .ok)
            #expect(abs(value - 100.0 / 120.0) < 0.0001)
        } else {
            #expect(cpu.status == .warmingUp)
        }
        let histories = try await gui.history(HistoryRequest(series: ["system", h.key().rawValue]))
        #expect(histories.count == 2)
        for history in histories {
            #expect(history.gaps.contains { $0.from <= Date(timeIntervalSince1970: 6) && $0.to >= Date(timeIntervalSince1970: 126) })
        }
        await mcp.invalidate()
        await gui.invalidate()
        await h.close()
    }

    @Test func agentRestartRejectsOldCursorAndTerminationToken() async throws {
        let old = try AgentHarness(instance: "agent-a")
        let first = old.client(.gui)
        var query = try ProcessQuery(filter: .all, sort: .pid, limit: 1)
        let page = try await first.listProcesses(query)
        query.cursor = try #require(page.nextCursor)
        let ticket = try await first.prepareTermination(key: old.key(), signal: .term)
        await first.invalidate()
        await old.close()
        let new = try AgentHarness(instance: "agent-b")
        let second = new.client(.gui)
        await integrationError(.invalidCursor) { _ = try await second.listProcesses(query) }
        let rejected = try await second.terminate(token: ticket.token)
        #expect(rejected.outcome == .rejected)
        #expect(rejected.rejection == .tokenUsed)
        #expect(new.signals.pids.withLock { $0.isEmpty })
        let fresh = try await second.snapshot(top: 200, sort: .pid)
        #expect(fresh.agentInstanceID != page.snapshot.agentInstanceID)
        #expect(fresh.snapshotID != page.snapshot.snapshotID)
        let replacement = try await second.prepareTermination(key: new.key(), signal: .term)
        #expect(replacement.token != ticket.token)
        await second.invalidate()
        await new.close()
    }
}

private func concurrentSnapshots(gui: AgentClient, servers: [MCPServer]) async throws -> [Snapshot] {
    async let guiSnapshot = gui.snapshot(top: 200, sort: .pid)
    let mcp = try await withThrowingTaskGroup(of: (Int, Snapshot).self) { group in
        for (index, server) in servers.enumerated() {
            group.addTask {
                let value = try await integrationCall(server, "get_snapshot", arguments: ["top": 200, "sort": "pid"])
                return try (index, value.decode(Snapshot.self))
            }
        }
        var values: [(Int, Snapshot)] = []
        for try await value in group {
            values.append(value)
        }
        return values.sorted { $0.0 < $1.0 }.map(\.1)
    }
    return try await [guiSnapshot] + mcp
}

private func checkScopes(_ snapshots: [Snapshot]) throws {
    #expect(snapshots.count == 4)
    #expect(snapshots[0].processes.contains { $0.pid == 84 })
    #expect(!snapshots[1].processes.contains { $0.pid == 84 })
    #expect(snapshots[1].processes.allSatisfy { $0.isOwn && $0.path == nil })
    #expect(snapshots[2].processes.contains { $0.pid == 84 })
    #expect(snapshots[2].processes.allSatisfy { $0.path == nil })
    #expect(snapshots[3].processes.contains { $0.pid == 84 })
}

private func fillPipe(_ output: FileHandle) throws -> Int {
    let descriptor = output.fileDescriptor
    let flags = fcntl(descriptor, F_GETFL)
    guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else { throw POSIXError(.EIO) }
    defer { _ = fcntl(descriptor, F_SETFL, flags) }
    var count = 0
    let bytes = [UInt8](repeating: 32, count: 4096)
    while true {
        let size = bytes.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
        if size < 0, errno == EAGAIN {
            return count
        }
        guard size > 0 else { throw POSIXError(.EIO) }
        count += size
    }
}
