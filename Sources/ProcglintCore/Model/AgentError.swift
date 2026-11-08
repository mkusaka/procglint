import Foundation

public enum AgentError: Error, Sendable, Codable, Equatable {
    case invalidArgument(String)
    case invalidProcessKey(String)
    case invalidCursor(String)
    case notFound(String)
    case permissionDenied(String)
    case rateLimited(String)
    case revisionConflict(String)
    case historyLimitReached(String)
    case terminationRejected(TerminationRejection, message: String = "Termination rejected")
    case agentUnavailable(String)
    case internalError(String)

    public enum Code: String, Sendable, Codable, CaseIterable {
        case invalidArgument = "invalid_argument"
        case invalidProcessKey = "invalid_process_key"
        case invalidCursor = "invalid_cursor"
        case notFound = "not_found"
        case permissionDenied = "permission_denied"
        case rateLimited = "rate_limited"
        case revisionConflict = "revision_conflict"
        case historyLimitReached = "history_limit_reached"
        case terminationRejected = "termination_rejected"
        case agentUnavailable = "agent_unavailable"
        case internalError = "internal"
    }

    public var code: Code {
        switch self {
        case .invalidArgument: .invalidArgument
        case .invalidProcessKey: .invalidProcessKey
        case .invalidCursor: .invalidCursor
        case .notFound: .notFound
        case .permissionDenied: .permissionDenied
        case .rateLimited: .rateLimited
        case .revisionConflict: .revisionConflict
        case .historyLimitReached: .historyLimitReached
        case .terminationRejected: .terminationRejected
        case .agentUnavailable: .agentUnavailable
        case .internalError: .internalError
        }
    }

    public var message: String {
        switch self {
        case let .invalidArgument(message), let .invalidProcessKey(message), let .invalidCursor(message),
             let .notFound(message), let .permissionDenied(message), let .rateLimited(message),
             let .revisionConflict(message), let .historyLimitReached(message), let .terminationRejected(_, message),
             let .agentUnavailable(message), let .internalError(message): message
        }
    }

    public var rejection: TerminationRejection? {
        if case let .terminationRejected(rejection, _) = self {
            return rejection
        }
        return nil
    }

    enum CodingKeys: String, CodingKey { case code, message, rejection }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let code = try container.decode(Code.self, forKey: .code)
        let message = try container.decode(String.self, forKey: .message)
        let rejection = try container.decodeIfPresent(TerminationRejection.self, forKey: .rejection)
        guard code == .terminationRejected || rejection == nil else {
            throw DecodingError.dataCorruptedError(forKey: .rejection, in: container, debugDescription: "Only termination_rejected carries a rejection")
        }
        switch code {
        case .invalidArgument: self = .invalidArgument(message)
        case .invalidProcessKey: self = .invalidProcessKey(message)
        case .invalidCursor: self = .invalidCursor(message)
        case .notFound: self = .notFound(message)
        case .permissionDenied: self = .permissionDenied(message)
        case .rateLimited: self = .rateLimited(message)
        case .revisionConflict: self = .revisionConflict(message)
        case .historyLimitReached: self = .historyLimitReached(message)
        case .terminationRejected:
            self = try .terminationRejected(container.decode(TerminationRejection.self, forKey: .rejection), message: message)
        case .agentUnavailable: self = .agentUnavailable(message)
        case .internalError: self = .internalError(message)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(code, forKey: .code)
        try container.encode(message, forKey: .message)
        try container.encodeIfPresent(rejection, forKey: .rejection)
    }
}
