import Foundation
import ProcglintCore

public enum AgentResponse: Sendable, Codable, Equatable {
    case hello(clientID: String)
    case snapshot(Snapshot)
    case listProcesses(ProcessPage)
    case process(ProcessSample)
    case history([HistorySeries])
    case status(MonitorStatus)
    case setLease(SamplingLease)
    case releaseLease
    case startObservation(Observation)
    case stopObservation
    case pin
    case policy(SamplingPolicy)
    case setPolicy(SamplingPolicy)
    case prepareTermination(TerminationTicket)
    case terminate(TerminationResult)
    case error(AgentError)

    public var method: AgentRequest.Method? {
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
        case .error: nil
        }
    }

    enum CodingKeys: String, CodingKey { case method, result, error }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.error) {
            guard !container.contains(.method), !container.contains(.result) else {
                throw DecodingError.dataCorruptedError(forKey: .error, in: container, debugDescription: "Response cannot contain both success and error")
            }
            self = try .error(container.decode(AgentError.self, forKey: .error))
            return
        }
        switch try container.decode(AgentRequest.Method.self, forKey: .method) {
        case .hello: self = try .hello(clientID: container.decode(String.self, forKey: .result))
        case .snapshot: self = try .snapshot(container.decode(Snapshot.self, forKey: .result))
        case .listProcesses: self = try .listProcesses(container.decode(ProcessPage.self, forKey: .result))
        case .process: self = try .process(container.decode(ProcessSample.self, forKey: .result))
        case .history: self = try .history(container.decode([HistorySeries].self, forKey: .result))
        case .status: self = try .status(container.decode(MonitorStatus.self, forKey: .result))
        case .setLease: self = try .setLease(container.decode(SamplingLease.self, forKey: .result))
        case .releaseLease: self = .releaseLease
        case .startObservation: self = try .startObservation(container.decode(Observation.self, forKey: .result))
        case .stopObservation: self = .stopObservation
        case .pin: self = .pin
        case .policy: self = try .policy(container.decode(SamplingPolicy.self, forKey: .result))
        case .setPolicy: self = try .setPolicy(container.decode(SamplingPolicy.self, forKey: .result))
        case .prepareTermination: self = try .prepareTermination(container.decode(TerminationTicket.self, forKey: .result))
        case .terminate: self = try .terminate(container.decode(TerminationResult.self, forKey: .result))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if case let .error(error) = self {
            try container.encode(error, forKey: .error)
            return
        }
        try container.encode(method, forKey: .method)
        switch self {
        case let .hello(clientID): try container.encode(clientID, forKey: .result)
        case let .snapshot(snapshot): try container.encode(snapshot, forKey: .result)
        case let .listProcesses(page): try container.encode(page, forKey: .result)
        case let .process(process): try container.encode(process, forKey: .result)
        case let .history(series): try container.encode(series, forKey: .result)
        case let .status(status): try container.encode(status, forKey: .result)
        case let .setLease(lease): try container.encode(lease, forKey: .result)
        case let .startObservation(observation): try container.encode(observation, forKey: .result)
        case let .policy(policy), let .setPolicy(policy): try container.encode(policy, forKey: .result)
        case let .prepareTermination(ticket): try container.encode(ticket, forKey: .result)
        case let .terminate(result): try container.encode(result, forKey: .result)
        case .releaseLease, .stopObservation, .pin: try container.encodeNil(forKey: .result)
        case .error: break
        }
    }
}
