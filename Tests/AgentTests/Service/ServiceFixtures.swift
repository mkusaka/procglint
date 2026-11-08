import Foundation
@testable import ProcglintAgentKit
import ProcglintCore
import ProcglintIPC
import Synchronization
import Testing

struct ServiceFixture: Sendable {
    let source: FakeProcessSource
    let clock: FakeClock
    let uptime: FakeClock
    let settings: InMemorySettingsStore
    let sampler: Sampler
    let scheduler: SamplingScheduler
    let observations: ObservationManager
    let service: AgentService
    let listener: AgentListener
    let disconnected: AsyncStream<ClientContext>
    let confirmationSleeps: AsyncStream<UInt64>
    private let effects: ServiceEffects
    var signals: [Int32] {
        effects.signals.withLock { $0 }
    }

    var exits: Int {
        effects.exits.withLock { $0 }
    }

    let directory: URL

    init(permissions: PermissionSet = .all, policy: SamplingPolicy? = nil,
         settingsOverride: (any SettingsStore)? = nil, omitAgentRow: Bool = false) throws
    {
        let source = FakeProcessSource()
        source.update { $0.bootSessionID = "boot-a" }
        for (pid, uid, parent) in [(Int32(42), geteuid(), Int32(1)), (84, geteuid() + 1, 1),
                                   (getpid(), geteuid(), 700), (700, geteuid(), 701), (701, geteuid(), 1),
                                   (800, geteuid(), 700), (801, geteuid(), 1)]
        {
            source.addProcess(pid: pid, process: FakeProcessSource.Process(
                rusage: RawRusage(cpuTimeNS: 100, footprintBytes: UInt64(pid) * 100, startTimeUS: 100),
                bsdInfo: RawBSDInfo(name: "worker-\(pid)", uid: uid, ppid: parent, startTimeUS: 100),
                path: "/private/worker-\(pid)"
            ))
        }
        self.source = source
        let clock = FakeClock()
        self.clock = clock
        let uptime = FakeClock()
        self.uptime = uptime
        let policy = try policy ?? SamplingPolicy()
        let settings = try InMemorySettingsStore(policy: policy, allowedPermissions: permissions)
        self.settings = settings
        let sampler = try Sampler(source: source, clock: clock, agentInstanceID: "agent-a")
        self.sampler = sampler
        let wallNow: @Sendable () -> Date = { Date(timeIntervalSince1970: Double(clock.now) / 1_000_000_000) }
        let scheduler = try SamplingScheduler(clock: clock, policy: policy, wallNow: wallNow, collect: {
            var snapshot = try await sampler.sample()
            snapshot.sampledAt = wallNow()
            if omitAgentRow {
                snapshot.processes.removeAll { $0.pid == getpid() }
            }
            return snapshot
        })
        self.scheduler = scheduler
        let observations = ObservationManager(scheduler: scheduler, clock: clock, wallNow: wallNow)
        self.observations = observations
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("procglint-service-test-\(UUID().uuidString)")
        self.directory = directory
        let effects = ServiceEffects()
        self.effects = effects
        let (sleeps, sleepContinuation) = AsyncStream<UInt64>.makeStream()
        confirmationSleeps = sleeps
        let confirmationClock = RecordingSleepClock(base: clock, sleeps: sleepContinuation)
        let termination = TerminationController(source: source, clock: confirmationClock,
                                                auditLog: AuditLog(url: directory.appendingPathComponent("audit.jsonl")), ownUID: geteuid(),
                                                sendSignal: { pid, _ in effects.signals.withLock { $0.append(pid) }; return 0 })
        let service = try AgentService(sampler: sampler, scheduler: scheduler, observations: observations, termination: termination,
                                       source: source, clock: clock, settings: settingsOverride ?? settings,
                                       uptimeNow: { uptime.now }, exitAction: { effects.exits.withLock { $0 += 1 } })
        self.service = service
        let (stream, continuation) = AsyncStream<ClientContext>.makeStream()
        disconnected = stream
        let listener = AgentListener.anonymous(handler: LifecycleHandler(service: service, disconnected: continuation))
        self.listener = listener
        listener.activate()
    }

    func client(_ kind: ClientKind = .mcp, flags: PermissionSet? = .all) -> AgentClient {
        AgentClient(endpoint: listener.endpoint, clientKind: kind, mcpFlags: flags)
    }

    func close() async {
        listener.invalidate()
        await service.shutdown()
        try? FileManager.default.removeItem(at: directory)
    }

    func key(_ pid: Int32 = 42) throws -> ProcessKey {
        try ProcessKey("p1.boot-a.\(pid).100")
    }

    func connect(id: String, pid: Int32, kind: ClientKind = .mcp, flags: PermissionSet = .all) async -> ClientContext {
        let context = ClientContext(clientID: id, pid: pid, uid: geteuid())
        await service.clientConnected(context)
        let response = await service.handle(.hello(ClientHello(clientKind: kind, version: "test", mcpFlags: flags)), from: context)
        #expect(response == .hello(clientID: id))
        return context
    }
}

private struct RecordingSleepClock: MonotonicClock {
    let base: FakeClock
    let sleeps: AsyncStream<UInt64>.Continuation
    var now: UInt64 {
        base.now
    }

    func sleep(until deadline: UInt64) async throws {
        sleeps.yield(deadline)
        try await base.sleep(until: deadline)
    }
}

private final class ServiceEffects: Sendable {
    let signals = Mutex<[Int32]>([])
    let exits = Mutex(0)
}

private struct LifecycleHandler: AgentRequestHandler {
    let service: AgentService
    let disconnected: AsyncStream<ClientContext>.Continuation

    func handle(_ request: AgentRequest, from client: ClientContext) async -> AgentResponse {
        await service.handle(request, from: client)
    }

    func clientConnected(_ client: ClientContext) async {
        await service.clientConnected(client)
    }

    func clientDisconnected(_ client: ClientContext) async {
        await service.clientDisconnected(client)
        disconnected.yield(client)
    }
}

func expectAgentError(_ code: AgentError.Code, operation: () async throws -> Void,
                      sourceLocation: SourceLocation = #_sourceLocation) async
{
    do {
        try await operation()
        Issue.record("Expected \(code.rawValue)", sourceLocation: sourceLocation)
    } catch let error as AgentError {
        #expect(error.code == code, sourceLocation: sourceLocation)
    } catch {
        Issue.record("Unexpected error: \(error)", sourceLocation: sourceLocation)
    }
}
