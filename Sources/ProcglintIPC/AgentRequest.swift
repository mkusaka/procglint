import Foundation
import ProcglintCore

public struct ClientHello: Sendable, Codable, Equatable {
    public var clientKind: ClientKind
    public var version: String
    public var mcpFlags: PermissionSet?

    public init(clientKind: ClientKind, version: String, mcpFlags: PermissionSet? = nil) {
        self.clientKind = clientKind
        self.version = version
        self.mcpFlags = mcpFlags
    }
}

public enum AgentRequest: Sendable, Codable, Equatable {
    case hello(ClientHello)
    case snapshot(top: Int, sort: ProcessSort)
    case listProcesses(ProcessQuery)
    case process(key: ProcessKey)
    case history(HistoryRequest)
    case status
    case setLease(LeaseRequest)
    case releaseLease(id: String)
    case startObservation(ObservationRequest)
    case stopObservation(id: String)
    case pin(key: ProcessKey, pinned: Bool)
    case policy
    case setPolicy(SamplingPolicy, expectedRevision: Int)
    case prepareTermination(key: ProcessKey, signal: TerminationSignal)
    case terminate(token: String)

    public enum Method: String, Sendable, Codable, CaseIterable {
        case hello, snapshot
        case listProcesses = "list_processes"
        case process, history, status
        case setLease = "set_lease"
        case releaseLease = "release_lease"
        case startObservation = "start_observation"
        case stopObservation = "stop_observation"
        case pin, policy
        case setPolicy = "set_policy"
        case prepareTermination = "prepare_termination"
        case terminate
    }

    public var method: Method {
        switch self {
        case .hello: .hello
        case .snapshot: .snapshot
        case .listProcesses: .listProcesses
        case .process: .process
        case .history: .history
        case .status: .status
        case .setLease: .setLease
        case .releaseLease: .releaseLease
        case .startObservation: .startObservation
        case .stopObservation: .stopObservation
        case .pin: .pin
        case .policy: .policy
        case .setPolicy: .setPolicy
        case .prepareTermination: .prepareTermination
        case .terminate: .terminate
        }
    }

    enum CodingKeys: String, CodingKey {
        case method, hello, top, sort, query, key, request, id, pinned, policy, expectedRevision, signal, token
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Method.self, forKey: .method) {
        case .hello: self = try .hello(container.decode(ClientHello.self, forKey: .hello))
        case .snapshot:
            self = try .snapshot(top: container.decode(Int.self, forKey: .top), sort: container.decode(ProcessSort.self, forKey: .sort))
        case .listProcesses: self = try .listProcesses(container.decode(ProcessQuery.self, forKey: .query))
        case .process: self = try .process(key: container.decode(ProcessKey.self, forKey: .key))
        case .history: self = try .history(container.decode(HistoryRequest.self, forKey: .request))
        case .status: self = .status
        case .setLease: self = try .setLease(container.decode(LeaseRequest.self, forKey: .request))
        case .releaseLease: self = try .releaseLease(id: container.decode(String.self, forKey: .id))
        case .startObservation: self = try .startObservation(container.decode(ObservationRequest.self, forKey: .request))
        case .stopObservation: self = try .stopObservation(id: container.decode(String.self, forKey: .id))
        case .pin:
            self = try .pin(key: container.decode(ProcessKey.self, forKey: .key), pinned: container.decode(Bool.self, forKey: .pinned))
        case .policy: self = .policy
        case .setPolicy:
            self = try .setPolicy(container.decode(SamplingPolicy.self, forKey: .policy), expectedRevision: container.decode(Int.self, forKey: .expectedRevision))
        case .prepareTermination:
            self = try .prepareTermination(key: container.decode(ProcessKey.self, forKey: .key), signal: container.decode(TerminationSignal.self, forKey: .signal))
        case .terminate: self = try .terminate(token: container.decode(String.self, forKey: .token))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(method, forKey: .method)
        switch self {
        case let .hello(hello): try container.encode(hello, forKey: .hello)
        case let .snapshot(top, sort):
            try container.encode(top, forKey: .top)
            try container.encode(sort, forKey: .sort)
        case let .listProcesses(query): try container.encode(query, forKey: .query)
        case let .process(key): try container.encode(key, forKey: .key)
        case let .history(request): try container.encode(request, forKey: .request)
        case .status, .policy: break
        case let .setLease(request): try container.encode(request, forKey: .request)
        case let .releaseLease(id), let .stopObservation(id): try container.encode(id, forKey: .id)
        case let .startObservation(request): try container.encode(request, forKey: .request)
        case let .pin(key, pinned):
            try container.encode(key, forKey: .key)
            try container.encode(pinned, forKey: .pinned)
        case let .setPolicy(policy, expectedRevision):
            try container.encode(policy, forKey: .policy)
            try container.encode(expectedRevision, forKey: .expectedRevision)
        case let .prepareTermination(key, signal):
            try container.encode(key, forKey: .key)
            try container.encode(signal, forKey: .signal)
        case let .terminate(token): try container.encode(token, forKey: .token)
        }
    }
}
