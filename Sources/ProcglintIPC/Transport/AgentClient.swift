import Foundation
import ProcglintCore

public let agentPayloadLimit = 4 * 1024 * 1024

/// onReconnect runs after a replacement connection's hello; callers must re-acquire leases, not replay failed mutations.
public actor AgentClient: MonitorService {
    private struct Pending {
        let continuation: CheckedContinuation<Data, any Error>
        let timeout: Task<Void, Never>
    }

    private let endpoint: NSXPCListenerEndpoint?
    private let hello: ClientHello
    private let timeoutNS: UInt64
    private let clock: any MonotonicClock
    private let onReconnect: (@Sendable () -> Void)?
    private var connection: ClientConnection?
    private var generation = 0
    private var handshake: Task<Void, any Error>?
    private var hasConnected = false
    private var pending: [UUID: Pending] = [:]

    public init(clientKind: ClientKind, version: String = "1.0", mcpFlags: PermissionSet? = nil,
                timeoutMS: Int = 10000, clock: (any MonotonicClock)? = nil, onReconnect: (@Sendable () -> Void)? = nil)
    {
        precondition((1 ... 60000).contains(timeoutMS))
        endpoint = nil
        hello = ClientHello(clientKind: clientKind, version: version, mcpFlags: mcpFlags)
        timeoutNS = UInt64(timeoutMS) * 1_000_000
        self.clock = clock ?? TransportClock()
        self.onReconnect = onReconnect
    }

    public init(endpoint: NSXPCListenerEndpoint, clientKind: ClientKind = .cli, version: String = "1.0",
                mcpFlags: PermissionSet? = nil, timeoutMS: Int = 10000, clock: (any MonotonicClock)? = nil,
                onReconnect: (@Sendable () -> Void)? = nil)
    {
        precondition((1 ... 60000).contains(timeoutMS))
        self.endpoint = endpoint
        hello = ClientHello(clientKind: clientKind, version: version, mcpFlags: mcpFlags)
        timeoutNS = UInt64(timeoutMS) * 1_000_000
        self.clock = clock ?? TransportClock()
        self.onReconnect = onReconnect
    }

    public func invalidate() {
        connectionLost(generation: generation)
    }

    private static func unavailable(_ reason: String) -> AgentError {
        .agentUnavailable("\(reason). Run `procglint doctor` to check agent registration and recovery steps.")
    }

    private func connectionLost(generation expected: Int, reason: String = "Agent connection interrupted or invalidated") {
        guard expected == generation else { return }
        let old = connection
        connection = nil
        handshake = nil
        generation += 1
        let requests = pending.values
        pending.removeAll()
        for request in requests {
            request.timeout.cancel()
            request.continuation.resume(throwing: Self.unavailable(reason))
        }
        old?.value.invalidate()
    }

    private func connect() async throws {
        if let handshake {
            return try await handshake.value
        }
        let current = generation
        let connection = endpoint.map(NSXPCConnection.init(listenerEndpoint:))
            ?? NSXPCConnection(machServiceName: procglintAgentMachServiceName)
        connection.remoteObjectInterface = NSXPCInterface(with: ProcglintAgentXPC.self)
        connection.interruptionHandler = { [weak self] in
            Task { await self?.connectionLost(generation: current) }
        }
        connection.invalidationHandler = { [weak self] in
            Task { await self?.connectionLost(generation: current) }
        }
        self.connection = ClientConnection(connection)
        connection.activate()
        let task = Task {
            do {
                let response = try await self.exchange(.hello(self.hello), generation: current)
                guard case .hello = response, self.generation == current else {
                    throw Self.unavailable("Agent hello failed")
                }
                let reconnect = self.hasConnected
                self.hasConnected = true
                if reconnect {
                    self.onReconnect?()
                }
            } catch {
                self.connectionLost(generation: current)
                throw error
            }
        }
        handshake = task
        try await task.value
    }

    private func finish(_ id: UUID, result: Result<Data, any Error>) {
        guard let request = pending.removeValue(forKey: id) else { return }
        request.timeout.cancel()
        request.continuation.resume(with: result)
    }

    private func timedOut(_ id: UUID, generation: Int) {
        guard pending[id] != nil else { return }
        connectionLost(generation: generation, reason: "Agent request timed out")
    }

    private func exchange(_ request: AgentRequest, generation expected: Int) async throws -> AgentResponse {
        guard let connection = connection?.value, generation == expected else { throw Self.unavailable("Agent is disconnected") }
        let data = try ProcglintJSON.encoder().encode(request)
        guard data.count <= agentPayloadLimit else { throw AgentError.invalidArgument("XPC request exceeds 4 MiB") }
        let id = UUID()
        let reply: Data = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let (sum, overflow) = clock.now.addingReportingOverflow(timeoutNS)
                let deadline = overflow ? UInt64.max : sum
                let timer = Task {
                    do { try await clock.sleep(until: deadline) } catch { return }
                    self.timedOut(id, generation: expected)
                }
                pending[id] = Pending(continuation: continuation, timeout: timer)
                let proxy = connection.remoteObjectProxyWithErrorHandler { [weak self] _ in
                    Task { await self?.connectionLost(generation: expected) }
                }
                guard let remote = proxy as? any ProcglintAgentXPC else {
                    connectionLost(generation: expected)
                    return
                }
                remote.send(data) { [weak self] reply in
                    Task { await self?.finish(id, result: .success(reply)) }
                }
            }
        } onCancel: {
            Task { await self.finish(id, result: .failure(CancellationError())) }
        }
        guard reply.count <= agentPayloadLimit else { throw AgentError.internalError("XPC response exceeds 4 MiB") }
        let response: AgentResponse
        do { response = try ProcglintJSON.decoder().decode(AgentResponse.self, from: reply) } catch {
            throw AgentError.internalError("Malformed XPC response")
        }
        if case let .error(error) = response {
            throw error
        }
        guard response.method == request.method else { throw AgentError.internalError("Unexpected XPC response method") }
        return response
    }

    func request(_ request: AgentRequest) async throws -> AgentResponse {
        try await connect()
        try Task.checkCancellation()
        return try await exchange(request, generation: generation)
    }

    public func snapshot(top: Int, sort: ProcessSort) async throws -> Snapshot {
        guard case let .snapshot(value) = try await request(.snapshot(top: top, sort: sort)) else { throw unexpectedResponse }
        return value
    }

    public func listProcesses(_ query: ProcessQuery) async throws -> ProcessPage {
        guard case let .listProcesses(value) = try await request(.listProcesses(query)) else { throw unexpectedResponse }
        return value
    }

    public func process(key: ProcessKey) async throws -> ProcessSample {
        guard case let .process(value) = try await request(.process(key: key)) else { throw unexpectedResponse }
        return value
    }

    public func history(_ request: HistoryRequest) async throws -> [HistorySeries] {
        guard case let .history(value) = try await self.request(.history(request)) else { throw unexpectedResponse }
        return value
    }

    public func status() async throws -> MonitorStatus {
        guard case let .status(value) = try await request(.status) else { throw unexpectedResponse }
        return value
    }

    public func setLease(_ request: LeaseRequest) async throws -> SamplingLease {
        guard case let .setLease(value) = try await self.request(.setLease(request)) else { throw unexpectedResponse }
        return value
    }

    public func releaseLease(id: String) async throws {
        _ = try await request(.releaseLease(id: id))
    }

    public func startObservation(_ request: ObservationRequest) async throws -> Observation {
        guard case let .startObservation(value) = try await self.request(.startObservation(request)) else { throw unexpectedResponse }
        return value
    }

    public func stopObservation(id: String) async throws {
        _ = try await request(.stopObservation(id: id))
    }

    public func pin(key: ProcessKey, pinned: Bool) async throws {
        _ = try await request(.pin(key: key, pinned: pinned))
    }

    public func policy() async throws -> SamplingPolicy {
        guard case let .policy(value) = try await request(.policy) else { throw unexpectedResponse }
        return value
    }

    public func setPolicy(_ policy: SamplingPolicy, expectedRevision: Int) async throws -> SamplingPolicy {
        guard case let .setPolicy(value) = try await request(.setPolicy(policy, expectedRevision: expectedRevision)) else { throw unexpectedResponse }
        return value
    }

    public func prepareTermination(key: ProcessKey, signal: TerminationSignal) async throws -> TerminationTicket {
        guard case let .prepareTermination(value) = try await request(.prepareTermination(key: key, signal: signal)) else { throw unexpectedResponse }
        return value
    }

    public func terminate(token: String) async throws -> TerminationResult {
        guard case let .terminate(value) = try await request(.terminate(token: token)) else { throw unexpectedResponse }
        return value
    }

    private var unexpectedResponse: AgentError {
        .internalError("Unexpected XPC response")
    }
}

/// A separate owner makes cleanup synchronous on macOS 15.0, without an isolated actor deinit (15.4+).
private final class ClientConnection {
    let value: NSXPCConnection
    init(_ value: NSXPCConnection) {
        self.value = value
    }

    deinit { value.invalidate() }
}

private struct TransportClock: MonotonicClock {
    var now: UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }

    func sleep(until deadline: UInt64) async throws {
        let current = now
        if deadline > current {
            try await Task.sleep(nanoseconds: deadline - current)
        }
    }
}
