import Foundation
import ProcglintCore
import ProcglintIPC
import Synchronization
import Testing

private enum ReplyMode: Sendable, CaseIterable {
    case normal, malformed, wrongMethod, oversized, denied, hang, hangHello, rejectHello
}

/// NSXPC objects are thread-safe; mutable test state is mutex-protected.
private final class TestServer: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    /// Connections and reply blocks support cross-queue use and are held only under the mutex.
    private struct State: @unchecked Sendable {
        var connections: [NSXPCConnection] = []
        var replies: [(Data) -> Void] = []
        var mode: ReplyMode
    }

    let listener = NSXPCListener.anonymous()
    let requests: AsyncStream<AgentRequest>
    private let received: AsyncStream<AgentRequest>.Continuation
    private let state: Mutex<State>

    init(mode: ReplyMode) {
        state = Mutex(State(mode: mode))
        (requests, received) = AsyncStream.makeStream()
        super.init()
        listener.delegate = self
        listener.activate()
    }

    func setMode(_ mode: ReplyMode) {
        state.withLock { $0.mode = mode }
    }

    func stop() {
        listener.invalidate()
        disconnect()
    }

    func disconnect() {
        let connections = state.withLock { state in
            let connections = state.connections
            state.connections = []
            state.replies = []
            return connections
        }
        for connection in connections {
            connection.invalidate()
        }
    }

    func listener(_: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: ProcglintAgentXPC.self)
        connection.exportedObject = Responder(server: self)
        state.withLock { $0.connections.append(connection) }
        connection.activate()
        return true
    }

    func respond(_ data: Data, reply: @escaping (Data) -> Void) {
        do {
            let request = try ProcglintJSON.decoder().decode(AgentRequest.self, from: data)
            let mode = state.withLock { $0.mode }
            if case .hello = request {
                if mode == .hangHello {
                    state.withLock { $0.replies.append(reply) }
                } else {
                    let response: AgentResponse = mode == .rejectHello ? .error(.permissionDenied("Hello rejected")) : .hello(clientID: "client-a")
                    try reply(ProcglintJSON.encoder().encode(response))
                }
            } else {
                switch mode {
                case .normal, .rejectHello: try reply(ProcglintJSON.encoder().encode(AgentResponse.policy(SamplingPolicy())))
                case .malformed: reply(Data("not-json".utf8))
                case .wrongMethod: try reply(ProcglintJSON.encoder().encode(AgentResponse.releaseLease))
                case .oversized: reply(Data(repeating: 32, count: agentPayloadLimit + 1))
                case .denied: try reply(ProcglintJSON.encoder().encode(AgentResponse.error(.permissionDenied("Denied"))))
                case .hang, .hangHello: state.withLock { $0.replies.append(reply) }
                }
            }
            received.yield(request)
        } catch { Issue.record(error) }
    }

    private final class Responder: NSObject, ProcglintAgentXPC {
        weak var server: TestServer?
        init(server: TestServer) {
            self.server = server
        }

        func send(_ request: Data, reply: @escaping (Data) -> Void) {
            server?.respond(request, reply: reply)
        }
    }
}

@Suite(.timeLimit(.minutes(1)))
struct AgentClientTransportTests {
    @Test(arguments: [ReplyMode.malformed, .wrongMethod, .oversized, .denied, .rejectHello])
    private func invalidServerResponses(mode: ReplyMode) async throws {
        let server = TestServer(mode: mode)
        defer { server.stop() }
        let client = AgentClient(endpoint: server.listener.endpoint)
        do {
            _ = try await client.policy()
            Issue.record("Expected failure")
        } catch let error as AgentError {
            #expect(error.code == (mode == .denied || mode == .rejectHello ? .permissionDenied : .internalError))
        }
        await client.invalidate()
    }

    @Test(arguments: [ReplyMode.hang, .hangHello])
    private func timeoutUsesInjectedClockAndRecoversWithDoctorText(mode: ReplyMode) async throws {
        let server = TestServer(mode: mode)
        defer { server.stop() }
        let clock = FakeClock()
        let client = AgentClient(endpoint: server.listener.endpoint, timeoutMS: 10, clock: clock)
        let request = Task { try await client.policy() }
        var received = server.requests.makeAsyncIterator()
        #expect(await received.next()?.method == .hello)
        if mode == .hang {
            #expect(await received.next()?.method == .policy)
        }
        clock.advance(by: 10_000_000)
        do {
            _ = try await request.value
            Issue.record("Expected timeout")
        } catch let error as AgentError {
            #expect(error.code == .agentUnavailable)
            #expect(error.message.contains("procglint doctor"))
        }
        await client.invalidate()
        #expect(clock.pendingSleepCount == 0)
    }

    @Test func cancellationDoesNotWaitForRemoteReply() async throws {
        let server = TestServer(mode: .hang)
        defer { server.stop() }
        let client = AgentClient(endpoint: server.listener.endpoint)
        let request = Task { try await client.policy() }
        var received = server.requests.makeAsyncIterator()
        _ = await received.next()
        #expect(await received.next()?.method == .policy)
        request.cancel()
        await #expect(throws: CancellationError.self) { try await request.value }
        await client.invalidate()
    }

    @Test func remoteInvalidationFailsPendingRequestAndNextCallReconnects() async throws {
        let server = TestServer(mode: .hang)
        defer { server.stop() }
        let reconnects = Mutex(0)
        let client = AgentClient(endpoint: server.listener.endpoint, onReconnect: { reconnects.withLock { $0 += 1 } })
        let request = Task { try await client.policy() }
        var received = server.requests.makeAsyncIterator()
        _ = await received.next()
        #expect(await received.next()?.method == .policy)
        server.disconnect()
        do {
            _ = try await request.value
            Issue.record("Expected disconnection")
        } catch let error as AgentError {
            #expect(error.code == .agentUnavailable)
            #expect(error.message.contains("procglint doctor"))
        }
        #expect(reconnects.withLock { $0 } == 0)
        server.setMode(.normal)
        _ = try await client.policy()
        #expect(await received.next()?.method == .hello)
        #expect(await received.next()?.method == .policy)
        #expect(reconnects.withLock { $0 } == 1)
        await client.invalidate()
    }

    @Test func oversizedRequestIsRejectedBeforeSendingAndConnectionSurvives() async throws {
        let server = TestServer(mode: .normal)
        defer { server.stop() }
        let client = AgentClient(endpoint: server.listener.endpoint)
        do {
            try await client.stopObservation(id: String(repeating: "x", count: agentPayloadLimit + 1))
            Issue.record("Expected payload size error")
        } catch let error as AgentError {
            #expect(error.code == .invalidArgument)
        }
        _ = try await client.policy()
        var received = server.requests.makeAsyncIterator()
        #expect(await received.next()?.method == .hello)
        #expect(await received.next()?.method == .policy)
        await client.invalidate()
    }
}
