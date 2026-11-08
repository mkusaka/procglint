import Foundation
@testable import ProcglintAgentKit
@testable import ProcglintCore
import ProcglintIPC
@testable import ProcglintMCPKit
import Synchronization
import Testing

struct AgentHarness: Sendable {
    let source: FakeProcessSource
    let clock: FakeClock
    let uptime: FakeClock
    let settings: InMemorySettingsStore
    let sampler: Sampler
    let scheduler: SamplingScheduler
    let observations: ObservationManager
    let termination: TerminationController
    let service: AgentService
    let listener: AgentListener
    let disconnected: AsyncStream<ClientContext>
    let handled: AsyncStream<AgentRequest>
    let directory: URL
    let signals = IntegrationSignals()

    init(instance: String = "agent-a") throws {
        let source = FakeProcessSource()
        source.update { $0.bootSessionID = "boot-a" }
        for (pid, uid) in [(Int32(42), geteuid()), (43, geteuid()), (84, geteuid() + 1), (getpid(), geteuid())] {
            source.addProcess(pid: pid, process: Self.worker(pid: pid, uid: uid))
        }
        self.source = source
        let clock = FakeClock()
        self.clock = clock
        let uptime = FakeClock()
        self.uptime = uptime
        let policy = try SamplingPolicy()
        let settings = try InMemorySettingsStore(policy: policy, allowedPermissions: .all)
        self.settings = settings
        let sampler = try Sampler(source: source, clock: clock, agentInstanceID: instance)
        self.sampler = sampler
        let wallNow: @Sendable () -> Date = { Date(timeIntervalSince1970: Double(clock.now) / 1_000_000_000) }
        let scheduler = try SamplingScheduler(clock: clock, policy: policy, wallNow: wallNow, collect: {
            var snapshot = try await sampler.sample()
            snapshot.sampledAt = wallNow()
            return snapshot
        })
        self.scheduler = scheduler
        let observations = ObservationManager(scheduler: scheduler, clock: clock, wallNow: wallNow)
        self.observations = observations
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("procglint-integration-\(UUID().uuidString)")
        self.directory = directory
        let signals = signals
        let termination = TerminationController(source: source, clock: clock,
                                                auditLog: AuditLog(url: directory.appendingPathComponent("audit.jsonl")), ownUID: geteuid(),
                                                sendSignal: { pid, _ in signals.pids.withLock { $0.append(pid) }; return 0 })
        self.termination = termination
        let service = try AgentService(sampler: sampler, scheduler: scheduler, observations: observations, termination: termination,
                                       source: source, clock: clock, settings: settings, uptimeNow: { uptime.now }, exitAction: {})
        self.service = service
        let (disconnected, disconnects) = AsyncStream<ClientContext>.makeStream()
        self.disconnected = disconnected
        let (handled, responses) = AsyncStream<AgentRequest>.makeStream(bufferingPolicy: .bufferingNewest(32))
        self.handled = handled
        let listener = AgentListener.anonymous(handler: IntegrationHandler(service: service, disconnects: disconnects, responses: responses))
        self.listener = listener
        listener.activate()
    }

    static func worker(pid: Int32, uid: UInt32 = geteuid(), start: UInt64 = 100) -> FakeProcessSource.Process {
        FakeProcessSource.Process(rusage: RawRusage(cpuTimeNS: 100, footprintBytes: 4096, rssBytes: 2048, startTimeUS: start),
                                  bsdInfo: RawBSDInfo(name: "worker-\(pid)", uid: uid, ppid: 1, startTimeUS: start),
                                  path: "/private/worker-\(pid)")
    }

    func key(_ pid: Int32 = 42, start: UInt64 = 100) throws -> ProcessKey {
        try ProcessKey("p1.boot-a.\(pid).\(start)")
    }

    func client(_ kind: ClientKind = .mcp, flags: PermissionSet = []) -> AgentClient {
        AgentClient(endpoint: listener.endpoint, clientKind: kind, mcpFlags: flags)
    }

    func server(_ client: AgentClient, flags: PermissionSet = []) -> MCPServer {
        MCPServer(service: client, flags: MCPFlags(permissions: flags), now: { clock.now })
    }

    func advance(seconds: UInt64, sleeping: Bool = false) {
        if !sleeping {
            uptime.advance(by: seconds * 1_000_000_000)
        }
        clock.advance(by: seconds * 1_000_000_000)
    }

    /// A stream event proves a collection committed; joining its task also waits for timer replanning.
    func next(_ iterator: inout AsyncStream<Snapshot>.Iterator) async throws -> Snapshot {
        let snapshot = try #require(await iterator.next())
        let settled = try await scheduler.freshSnapshot(scope: AccessScope(includeSystem: true))
        #expect(settled.snapshotID == snapshot.snapshotID)
        return snapshot
    }

    func warm(_ client: AgentClient) async throws {
        var samples = await scheduler.subscribe(scope: AccessScope(includeSystem: true)).makeAsyncIterator()
        _ = try await client.snapshot(top: 200, sort: .pid)
        _ = try await next(&samples)
        advance(seconds: 1)
        _ = try await next(&samples)
    }

    func close() async {
        listener.invalidate()
        await service.shutdown()
        try? FileManager.default.removeItem(at: directory)
    }
}

final class IntegrationSignals: Sendable {
    let pids = Mutex<[Int32]>([])
}

private struct IntegrationHandler: AgentRequestHandler {
    let service: AgentService
    let disconnects: AsyncStream<ClientContext>.Continuation
    let responses: AsyncStream<AgentRequest>.Continuation

    func clientConnected(_ client: ClientContext) async {
        await service.clientConnected(client)
    }

    func clientDisconnected(_ client: ClientContext) async {
        await service.clientDisconnected(client)
        disconnects.yield(client)
    }

    func handle(_ request: AgentRequest, from client: ClientContext) async -> AgentResponse {
        let response = await service.handle(request, from: client)
        responses.yield(request)
        return response
    }
}

func integrationRequest(_ name: String, arguments: JSONValue = [:], id: Int = 1) throws -> String {
    try JSONValue.object([
        "jsonrpc": "2.0", "id": .number(Decimal(id)), "method": "tools/call",
        "params": ["name": .string(name), "arguments": arguments, "_meta": [
            "io.modelcontextprotocol/protocolVersion": "2026-07-28",
            "io.modelcontextprotocol/clientInfo": ["name": "integration", "version": "1"],
            "io.modelcontextprotocol/clientCapabilities": [:],
        ]],
    ]).text()
}

func integrationCall(_ server: MCPServer, _ name: String, arguments: JSONValue = [:], id: Int = 1) async throws -> JSONValue {
    let line = try #require(await server.handle(line: integrationRequest(name, arguments: arguments, id: id)))
    let response = try JSONValue.parse(Data(line.utf8))
    #expect(response["error"] == nil)
    #expect(response["result"]?["isError"] == false)
    return try #require(response["result"]?["structuredContent"])
}

func integrationError(_ code: AgentError.Code, _ operation: () async throws -> Void,
                      sourceLocation: SourceLocation = #_sourceLocation) async
{
    do {
        try await operation()
        Issue.record("Expected \(code)", sourceLocation: sourceLocation)
    } catch let error as AgentError {
        #expect(error.code == code, sourceLocation: sourceLocation)
    } catch {
        Issue.record("Unexpected error: \(error)", sourceLocation: sourceLocation)
    }
}

func integrationSend(_ data: Data, connection: NSXPCConnection) async throws -> AgentResponse {
    let reply: Data = try await withCheckedThrowingContinuation { continuation in
        let proxy = connection.remoteObjectProxyWithErrorHandler { continuation.resume(throwing: $0) }
        guard let remote = proxy as? any ProcglintAgentXPC else {
            continuation.resume(throwing: AgentError.internalError("Missing proxy")); return
        }
        remote.send(data) { continuation.resume(returning: $0) }
    }
    return try ProcglintJSON.decoder().decode(AgentResponse.self, from: reply)
}
