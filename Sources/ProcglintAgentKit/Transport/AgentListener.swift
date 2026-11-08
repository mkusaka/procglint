import Foundation
import ProcglintCore
import ProcglintIPC
import Synchronization

public struct ClientContext: Sendable, Equatable {
    public let clientID: String
    public let pid: pid_t
    public let uid: uid_t

    public init(clientID: String, pid: pid_t, uid: uid_t) {
        self.clientID = clientID
        self.pid = pid
        self.uid = uid
    }
}

public protocol AgentRequestHandler: Sendable {
    func handle(_ request: AgentRequest, from client: ClientContext) async -> AgentResponse
    func clientConnected(_ client: ClientContext) async
    func clientDisconnected(_ client: ClientContext) async
}

/// NSXPCListener is thread-safe; the connection registry and lifecycle are protected by a mutex.
public final class AgentListener: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    /// NSXPCConnection supports cross-queue use; registry mutations always hold the enclosing mutex.
    private struct State: @unchecked Sendable {
        var connections: [String: NSXPCConnection] = [:]
        var closed = false
    }

    private let listener: NSXPCListener
    private let handler: any AgentRequestHandler
    private let anonymous: Bool
    private let identity: SigningIdentity?
    private let state = Mutex(State())

    public convenience init(handler: any AgentRequestHandler, machServiceName: String = procglintAgentMachServiceName) {
        self.init(listener: NSXPCListener(machServiceName: machServiceName), anonymous: false, handler: handler)
    }

    public static func anonymous(handler: any AgentRequestHandler) -> AgentListener {
        AgentListener(listener: .anonymous(), anonymous: true, handler: handler)
    }

    private init(listener: NSXPCListener, anonymous: Bool, handler: any AgentRequestHandler) {
        self.listener = listener
        self.anonymous = anonymous
        self.handler = handler
        identity = SigningIdentity.current()
        super.init()
        listener.delegate = self
    }

    deinit { invalidate() }

    public var endpoint: NSXPCListenerEndpoint {
        listener.endpoint
    }

    public func activate() {
        listener.activate()
    }

    public func invalidate() {
        let connections = state.withLock { state in
            state.closed = true
            let connections = Array(state.connections.values)
            state.connections.removeAll()
            return connections
        }
        listener.invalidate()
        for connection in connections {
            connection.invalidate()
        }
    }

    public func listener(_: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        let peer = SigningIdentity.peer(pid: connection.processIdentifier)
        guard PeerAuthorization.allows(agentUID: geteuid(), peerUID: connection.effectiveUserIdentifier,
                                       agent: identity, peer: peer),
            let identity else { return false }
        // Teamless agents (including ad-hoc Release builds) trust only same-UID local peers, pinned to the peer's cdhash.
        let requirement = PeerAuthorization.connectionRequirement(agent: identity, peer: peer,
                                                                  anonymousSameProcess: anonymous && connection.processIdentifier == getpid())
        // NSXPC checks the actual message sender, avoiding PID-reuse races in the metadata lookup above.
        guard let requirement else { return false }
        connection.setCodeSigningRequirement(requirement)
        let context = ClientContext(clientID: UUID().uuidString, pid: connection.processIdentifier, uid: connection.effectiveUserIdentifier)
        let session = ClientSession(context: context, handler: handler)
        connection.exportedInterface = NSXPCInterface(with: ProcglintAgentXPC.self)
        connection.exportedObject = RequestReceiver(session: session)
        connection.invalidationHandler = { [weak self] in
            _ = self?.state.withLock { $0.connections.removeValue(forKey: context.clientID) }
            Task { await session.close() }
        }
        connection.interruptionHandler = { [weak connection] in connection?.invalidate() }
        return state.withLock { state in
            guard !state.closed else { return false }
            state.connections[context.clientID] = connection
            connection.activate()
            return true
        }
    }
}

private actor ClientSession {
    private enum Phase { case awaitingHello, handshaking, ready, closed }
    private let context: ClientContext
    private let handler: any AgentRequestHandler
    private let connected: Task<Void, Never>
    private var phase = Phase.awaitingHello

    init(context: ClientContext, handler: any AgentRequestHandler) {
        self.context = context
        self.handler = handler
        connected = Task { await handler.clientConnected(context) }
    }

    func close() async {
        guard phase != .closed else { return }
        phase = .closed
        await connected.value
        await handler.clientDisconnected(context)
    }

    func receive(_ data: Data) async -> Data {
        let response: AgentResponse
        do {
            guard data.count <= agentPayloadLimit else { throw AgentError.invalidArgument("XPC request exceeds 4 MiB") }
            let request: AgentRequest
            do { request = try ProcglintJSON.decoder().decode(AgentRequest.self, from: data) } catch {
                throw AgentError.invalidArgument("Malformed XPC request")
            }
            await connected.value
            guard phase != .closed else { throw AgentError.agentUnavailable("Client disconnected; run `procglint doctor`") }
            if case .hello = request {
                guard phase == .awaitingHello else { throw AgentError.invalidArgument("hello may only be sent once") }
                phase = .handshaking
                let result = await handler.handle(request, from: context)
                guard phase != .closed else { throw AgentError.agentUnavailable("Client disconnected; run `procglint doctor`") }
                if case .error = result {
                    phase = .awaitingHello
                    response = result
                } else if case .hello = result {
                    phase = .ready
                    response = .hello(clientID: context.clientID)
                } else {
                    phase = .awaitingHello
                    response = .error(.internalError("Handler returned an invalid hello response"))
                }
            } else {
                guard phase == .ready else { throw AgentError.invalidArgument("hello is required before other requests") }
                response = await handler.handle(request, from: context)
            }
        } catch let error as AgentError {
            response = .error(error)
        } catch {
            response = .error(.internalError("XPC request failed"))
        }
        do {
            let data = try ProcglintJSON.encoder().encode(response)
            if data.count <= agentPayloadLimit {
                return data
            }
            return encodeError(.internalError("XPC response exceeds 4 MiB"))
        } catch {
            return encodeError(.internalError("Could not encode XPC response"))
        }
    }

    private func encodeError(_ error: AgentError) -> Data {
        do { return try ProcglintJSON.encoder().encode(AgentResponse.error(error)) } catch {
            preconditionFailure("AgentError contains only JSON-encodable strings/enums")
        }
    }
}

private final class RequestReceiver: NSObject, ProcglintAgentXPC, Sendable {
    let session: ClientSession

    init(session: ClientSession) {
        self.session = session
    }

    func send(_ request: Data, reply: @escaping (Data) -> Void) {
        let reply = XPCReply(callback: reply)
        Task { await reply.callback(session.receive(request)) }
    }
}

/// The XPC reply block may be invoked on any queue and is transferred to exactly one task.
private struct XPCReply: @unchecked Sendable {
    let callback: (Data) -> Void
}
