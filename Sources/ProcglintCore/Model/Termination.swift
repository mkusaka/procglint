import Foundation

public enum TerminationSignal: String, Sendable, Codable, CaseIterable { case term, kill }

public enum TerminationRejection: String, Sendable, Codable, CaseIterable {
    case notOwnProcess = "not_own_process"
    case protectedPID = "protected_pid"
    case `self`
    case processChanged = "process_changed"
    case exited
    case tokenExpired = "token_expired"
    case tokenUsed = "token_used"
    case tokenForeign = "token_foreign"
    case permissionDenied = "permission_denied"
}

public enum TerminationOutcome: String, Sendable, Codable, CaseIterable {
    case signalSent = "signal_sent"
    case rejected
}

public struct TerminationTicket: Sendable, Codable, Equatable {
    public var token: String
    public var processKey: ProcessKey
    public var pid: Int32
    public var name: String
    public var signal: TerminationSignal
    public var expiresAt: Date

    public init(token: String, processKey: ProcessKey, pid: Int32, name: String, signal: TerminationSignal, expiresAt: Date) {
        self.token = token
        self.processKey = processKey
        self.pid = pid
        self.name = name
        self.signal = signal
        self.expiresAt = expiresAt
    }
}

public struct TerminationResult: Sendable, Codable, Equatable {
    public let outcome: TerminationOutcome
    public let rejection: TerminationRejection?
    public let exitedConfirmed: Bool

    public init(outcome: TerminationOutcome, rejection: TerminationRejection? = nil, exitedConfirmed: Bool) throws {
        guard (outcome == .rejected) == (rejection != nil) else {
            throw AgentError.invalidArgument("Rejected termination requires a rejection; signal_sent must not have one")
        }
        self.outcome = outcome
        self.rejection = rejection
        self.exitedConfirmed = exitedConfirmed
    }

    enum CodingKeys: String, CodingKey { case outcome, rejection, exitedConfirmed }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(outcome: container.decode(TerminationOutcome.self, forKey: .outcome),
                      rejection: container.decodeIfPresent(TerminationRejection.self, forKey: .rejection),
                      exitedConfirmed: container.decode(Bool.self, forKey: .exitedConfirmed))
    }
}

public struct AuditEntry: Sendable, Codable, Equatable {
    public var timestamp: Date
    public var clientKind: ClientKind
    public var clientPID: Int32
    public var processKey: ProcessKey
    public var pid: Int32
    public var name: String
    public var signal: TerminationSignal
    // The spec also audits prepare, whose successful outcome is not a TerminationOutcome.
    public var outcome: String
    public var rejection: TerminationRejection?

    public init(timestamp: Date, clientKind: ClientKind, clientPID: Int32, processKey: ProcessKey, pid: Int32,
                name: String, signal: TerminationSignal, outcome: String, rejection: TerminationRejection? = nil)
    {
        self.timestamp = timestamp
        self.clientKind = clientKind
        self.clientPID = clientPID
        self.processKey = processKey
        self.pid = pid
        self.name = name
        self.signal = signal
        self.outcome = outcome
        self.rejection = rejection
    }

    enum CodingKeys: String, CodingKey {
        case timestamp, clientKind
        case clientPID = "clientPid"
        case processKey, pid, name, signal, outcome, rejection
    }
}
