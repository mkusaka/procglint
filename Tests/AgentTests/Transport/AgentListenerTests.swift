import Foundation
import ProcglintAgentKit
import ProcglintCore
import ProcglintIPC
import Synchronization
import Testing

private actor RecordingHandler: AgentRequestHandler {
    private(set) var requests: [(AgentRequest, ClientContext)] = []
    private(set) var clients: [ClientContext] = []
    let disconnected: AsyncStream<ClientContext>
    private let disconnections: AsyncStream<ClientContext>.Continuation
    private let responseOverride: @Sendable (AgentRequest) -> AgentResponse?

    init(responseOverride: @escaping @Sendable (AgentRequest) -> AgentResponse? = { _ in nil }) {
        self.responseOverride = responseOverride
        (disconnected, disconnections) = AsyncStream.makeStream()
    }

    func clientConnected(_ client: ClientContext) {
        clients.append(client)
    }

    func clientDisconnected(_ client: ClientContext) {
        disconnections.yield(client)
    }

    func handle(_ request: AgentRequest, from client: ClientContext) -> AgentResponse {
        requests.append((request, client))
        if let response = responseOverride(request) {
            return response
        }
        do {
            switch request {
            case .hello: return .hello(clientID: client.clientID)
            case .snapshot: return .snapshot(fixtureSnapshot())
            case .listProcesses:
                let snapshot = fixtureSnapshot()
                return .listProcesses(ProcessPage(snapshot: snapshot.header, items: [], totalMatched: 0))
            case .process: return .error(.notFound("Process exited"))
            case .history: return .history([])
            case .status:
                return try .status(MonitorStatus(agentInstanceID: "agent-a", agentPID: 42, agentCPUPercent: .warmingUp,
                                                 agentFootprintBytes: 1024, samplingActive: false, effectiveIntervalMS: nil,
                                                 collectionsTotal: 0, lastCollectionMS: 0, collectionP95MS: 0,
                                                 lastCoverage: Coverage(), failures: [:], leases: [], clients: [], historyBytes: 0,
                                                 policy: SamplingPolicy()))
            case let .setLease(request):
                return .setLease(SamplingLease(leaseID: "lease-a", clientID: client.clientID, kind: request.kind,
                                               intervalMS: request.intervalMS, expiresAt: 100))
            case .releaseLease: return .releaseLease
            case let .startObservation(request):
                return .startObservation(Observation(observationID: "obs-a", intervalMS: request.intervalMS,
                                                     startedAt: Date(timeIntervalSince1970: 0), expiresAt: Date(timeIntervalSince1970: 60),
                                                     processKeys: request.processKeys, state: .active))
            case .stopObservation: return .stopObservation
            case .pin: return .pin
            case .policy: return try .policy(SamplingPolicy())
            case let .setPolicy(policy, _): return .setPolicy(policy)
            case let .prepareTermination(key, signal):
                return .prepareTermination(TerminationTicket(token: "tok-1", processKey: key, pid: 42, name: "worker",
                                                             signal: signal, expiresAt: Date(timeIntervalSince1970: 60)))
            case .terminate: return try .terminate(TerminationResult(outcome: .signalSent, exitedConfirmed: false))
            }
        } catch { return .error(.internalError("Fixture failed")) }
    }
}

private func fixtureSnapshot() -> Snapshot {
    Snapshot(agentInstanceID: "agent-a", snapshotID: "agent-a-1", sampledAt: Date(timeIntervalSince1970: 0), intervalMS: nil,
             ageMS: 0, status: .warmingUp, coverage: Coverage(),
             system: SystemMetrics(cpuPercent: .warmingUp, physicalMemoryBytes: 8192, pageSize: 4096,
                                   memoryUsedBytes: 4096, wiredBytes: 0, compressedBytes: 0, activeBytes: 4096,
                                   inactiveBytes: 0, freeBytes: 4096), processes: [])
}

@Suite(.timeLimit(.minutes(1)))
struct AgentListenerTransportTests {
    @Test func clientRoundTripAndLifecycle() async throws {
        let handler = RecordingHandler()
        let listener = AgentListener.anonymous(handler: handler)
        listener.activate()
        defer { listener.invalidate() }
        let hello = ClientHello(clientKind: .mcp, version: "test", mcpFlags: [.observe])
        let client = AgentClient(endpoint: listener.endpoint, clientKind: hello.clientKind, version: hello.version, mcpFlags: hello.mcpFlags)
        #expect(try await client.snapshot(top: 5, sort: .cpu) == fixtureSnapshot())
        #expect(try await client.listProcesses(ProcessQuery()).totalMatched == 0)
        #expect(try await client.history(HistoryRequest(series: ["system"])) == [])
        #expect(try await client.status().agentInstanceID == "agent-a")
        let lease = try await client.setLease(LeaseRequest(kind: .guiWindow, intervalMS: .fiveSeconds))
        try await client.releaseLease(id: lease.leaseID)
        let observation = try await client.startObservation(ObservationRequest(intervalMS: .oneSecond, durationMS: 1000))
        try await client.stopObservation(id: observation.observationID)
        let key = try ProcessKey("p1.boot-a.42.100")
        try await client.pin(key: key, pinned: true)
        #expect(try await client.policy() == SamplingPolicy())
        #expect(try await client.setPolicy(SamplingPolicy(revision: 1), expectedRevision: 0).revision == 1)
        let ticket = try await client.prepareTermination(key: key, signal: .term)
        #expect(try await client.terminate(token: ticket.token).outcome == .signalSent)
        await #expect(throws: AgentError.notFound("Process exited")) { try await client.process(key: key) }
        let requests = await handler.requests
        #expect(requests.first?.0 == .hello(hello))
        #expect(requests.count == AgentRequest.Method.allCases.count)
        let context = try #require(requests.first?.1)
        #expect(context.clientID == lease.clientID)
        #expect(context.pid == getpid())
        #expect(context.uid == geteuid())
        #expect(await handler.clients == [context])
        var disconnected = handler.disconnected.makeAsyncIterator()
        await client.invalidate()
        #expect(await disconnected.next() == context)
    }

    @Test func concurrentFirstCallsShareHelloAndReconnectLazily() async throws {
        let handler = RecordingHandler()
        let listener = AgentListener.anonymous(handler: handler)
        listener.activate()
        defer { listener.invalidate() }
        let reconnects = Mutex(0)
        let client = AgentClient(endpoint: listener.endpoint, onReconnect: { reconnects.withLock { $0 += 1 } })
        async let first = client.policy()
        async let second = client.policy()
        _ = try await (first, second)
        #expect(await handler.requests.filter { $0.0.method == .hello }.count == 1)
        #expect(reconnects.withLock { $0 } == 0)
        var disconnected = handler.disconnected.makeAsyncIterator()
        await client.invalidate()
        _ = await disconnected.next()
        #expect(await handler.clients.count == 1)
        _ = try await client.policy()
        #expect(reconnects.withLock { $0 } == 1)
        let requests = await handler.requests
        let hellos = requests.filter { $0.0.method == .hello }
        #expect(hellos.count == 2)
        #expect(hellos.first?.1.clientID != hellos.last?.1.clientID)
        #expect(requests.last?.1 == hellos.last?.1)
        await client.invalidate()
    }

    @Test func handlerHelloFailureNeverAuthenticatesConnection() async throws {
        for response in [AgentResponse.error(.permissionDenied("Denied")), .releaseLease] {
            let handler = RecordingHandler { request in request.method == .hello ? response : nil }
            let listener = AgentListener.anonymous(handler: handler)
            listener.activate()
            defer { listener.invalidate() }
            let connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
            connection.remoteObjectInterface = NSXPCInterface(with: ProcglintAgentXPC.self)
            connection.activate()
            defer { connection.invalidate() }
            let hello = AgentRequest.hello(ClientHello(clientKind: .cli, version: "test"))
            let result = try await rawSend(ProcglintJSON.encoder().encode(hello), connection: connection)
            guard case let .error(error) = result else { Issue.record("Expected hello error"); continue }
            #expect(error.code == (response.method == nil ? .permissionDenied : .internalError))
            let policy = try await rawSend(ProcglintJSON.encoder().encode(AgentRequest.policy), connection: connection)
            #expect(policy == .error(.invalidArgument("hello is required before other requests")))
            #expect(await handler.requests.count == 1)
        }
    }

    @Test func responseEncodingAndSizeFailuresReturnSmallErrors() async throws {
        var invalidSnapshot = fixtureSnapshot()
        invalidSnapshot.system.cpuPercent = .ok(.nan)
        for response in [AgentResponse.snapshot(invalidSnapshot), .error(.internalError(String(repeating: "x", count: agentPayloadLimit + 1)))] {
            let handler = RecordingHandler { request in request.method == .snapshot ? response : nil }
            let listener = AgentListener.anonymous(handler: handler)
            listener.activate()
            defer { listener.invalidate() }
            let client = AgentClient(endpoint: listener.endpoint)
            do {
                _ = try await client.snapshot(top: 5, sort: .cpu)
                Issue.record("Expected response encoding/size error")
            } catch let error as AgentError {
                #expect(error.code == .internalError)
                #expect(error.message.count < 100)
            }
            _ = try await client.policy()
            await client.invalidate()
        }
    }

    @Test func malformedPayloadDoesNotCloseConnectionAndHelloIsRequired() async throws {
        let handler = RecordingHandler()
        let listener = AgentListener.anonymous(handler: handler)
        listener.activate()
        defer { listener.invalidate() }
        let connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
        connection.remoteObjectInterface = NSXPCInterface(with: ProcglintAgentXPC.self)
        connection.activate()
        defer { connection.invalidate() }
        for data in try [Data("not-json".utf8), Data(repeating: 32, count: agentPayloadLimit + 1),
                         ProcglintJSON.encoder().encode(AgentRequest.policy)]
        {
            let response = try await rawSend(data, connection: connection)
            guard case let .error(error) = response else { Issue.record("Expected an error"); continue }
            #expect(error.code == .invalidArgument)
        }
        #expect(await handler.requests.isEmpty)
        let hello = AgentRequest.hello(ClientHello(clientKind: .cli, version: "test"))
        guard case .hello = try await rawSend(ProcglintJSON.encoder().encode(hello), connection: connection) else {
            Issue.record("Expected hello response")
            return
        }
        let duplicate = try await rawSend(ProcglintJSON.encoder().encode(hello), connection: connection)
        guard case let .error(error) = duplicate else { Issue.record("Duplicate hello accepted"); return }
        #expect(error.code == .invalidArgument)
        let policy = try await rawSend(ProcglintJSON.encoder().encode(AgentRequest.policy), connection: connection)
        #expect(try policy == .policy(SamplingPolicy()))
        #expect(await handler.requests.map(\.0.method) == [.hello, .policy])
    }
}

private func rawSend(_ data: Data, connection: NSXPCConnection) async throws -> AgentResponse {
    let reply: Data = try await withCheckedThrowingContinuation { continuation in
        let remote = connection.remoteObjectProxyWithErrorHandler { continuation.resume(throwing: $0) }
        guard let remote = remote as? any ProcglintAgentXPC else {
            continuation.resume(throwing: AgentError.internalError("Missing proxy"))
            return
        }
        remote.send(data) { continuation.resume(returning: $0) }
    }
    return try ProcglintJSON.decoder().decode(AgentResponse.self, from: reply)
}
