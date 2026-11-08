import Darwin
import Foundation

public actor TerminationController {
    /// Populated by the agent from its authenticated connection, never from wire-supplied names or PIDs.
    public struct Client: Sendable {
        public let clientID: String
        public let kind: ClientKind
        public let pid: Int32
        /// The agent supplies its/app/bridge PIDs and the requesting client's parent chain on each request.
        public let protectedPIDs: Set<Int32>

        public init(clientID: String, kind: ClientKind, pid: Int32, protectedPIDs: Set<Int32>) {
            self.clientID = clientID
            self.kind = kind
            self.pid = pid
            self.protectedPIDs = protectedPIDs
        }
    }

    private struct Target: Equatable {
        let uid: UInt32
        let name: String
        let path: String?
        let executableUUID: UUID?
    }

    private struct TokenRecord {
        let ticket: TerminationTicket
        let clientID: String
        let clientKind: ClientKind
        let clientPID: Int32
        let target: Target
        let deadline: UInt64
        var used = false
    }

    private let source: any ProcessSource
    private let clock: any MonotonicClock
    private let sendSignal: @Sendable (Int32, Int32) -> Int32
    private let auditLog: AuditLog
    private let ownUID: UInt32
    private var tokens: [String: TokenRecord] = [:]

    public init(source: any ProcessSource, clock: any MonotonicClock, auditLog: AuditLog, ownUID: UInt32,
                sendSignal: @escaping @Sendable (Int32, Int32) -> Int32 = TerminationController.defaultSendSignal)
    {
        self.source = source
        self.clock = clock
        self.auditLog = auditLog
        self.ownUID = ownUID
        self.sendSignal = sendSignal
    }

    public nonisolated static func defaultSendSignal(pid: Int32, signal: Int32) -> Int32 {
        Darwin.kill(pid, signal) == 0 ? 0 : errno
    }

    public func prepare(key: ProcessKey, signal: TerminationSignal, client: Client,
                        permissions: PermissionSet) throws -> TerminationTicket
    {
        var name = ""
        let target: Target
        do {
            try requireUnprotected(pid: key.identity.pid, client: client)
            guard permissions.contains(.terminate), signal != .kill || permissions.contains(.forceKill) else {
                throw AgentError.terminationRejected(.permissionDenied)
            }
            target = try readTarget(key: key)
            name = target.name
            guard target.uid == ownUID else { throw AgentError.terminationRejected(.notOwnProcess) }
        } catch {
            try audit(key: key, name: name, signal: signal, client: client,
                      outcome: "rejected", rejection: (error as? AgentError)?.rejection)
            throw error
        }

        let now = clock.now
        var random = SystemRandomNumberGenerator()
        var token: String
        repeat {
            token = (0 ..< 16).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max, using: &random)) }.joined()
        } while tokens[token] != nil
        let ticket = TerminationTicket(token: token, processKey: key, pid: key.identity.pid, name: name,
                                       signal: signal, expiresAt: Date().addingTimeInterval(30))
        // A failed prepare audit must not leave behind a usable capability.
        try audit(key: key, name: name, signal: signal, client: client, outcome: "issued")
        tokens = tokens.filter { $0.value.deadline > now }
        if tokens.count >= 64, let oldest = tokens.min(by: { $0.value.deadline < $1.value.deadline })?.key {
            tokens.removeValue(forKey: oldest)
        }
        tokens[token] = TokenRecord(ticket: ticket, clientID: client.clientID, clientKind: client.kind,
                                    clientPID: client.pid, target: target, deadline: now + 30_000_000_000)
        return ticket
    }

    public func terminate(token: String, client: Client) async throws -> TerminationResult {
        guard let record = tokens[token] else {
            // Used, evicted and invalidated tokens are deliberately indistinguishable once forgotten.
            try auditLog.appendUnresolvedTermination(timestamp: Date(), clientKind: client.kind,
                                                     clientPID: client.pid, rejection: .tokenUsed)
            return try TerminationResult(outcome: .rejected, rejection: .tokenUsed, exitedConfirmed: false)
        }

        let confirmationDeadline: UInt64
        do {
            guard record.clientID == client.clientID, record.clientKind == client.kind, record.clientPID == client.pid else {
                throw AgentError.terminationRejected(.tokenForeign)
            }
            guard !record.used else { throw AgentError.terminationRejected(.tokenUsed) }
            guard clock.now < record.deadline else { throw AgentError.terminationRejected(.tokenExpired) }
            // Consume before any suspension or OS operation, including failed attempts to signal.
            tokens[token]?.used = true
            try Task.checkCancellation()
            try requireUnprotected(pid: record.ticket.pid, client: client)
            let current = try readTarget(key: record.ticket.processKey)
            guard current == record.target else { throw AgentError.terminationRejected(.processChanged) }
            guard clock.now < record.deadline else { throw AgentError.terminationRejected(.tokenExpired) }
            let error = sendSignal(record.ticket.pid, record.ticket.signal == .term ? SIGTERM : SIGKILL)
            switch error {
            case 0: confirmationDeadline = clock.now + 500_000_000
            case ESRCH: throw AgentError.terminationRejected(.exited)
            case EPERM, EACCES: throw AgentError.terminationRejected(.permissionDenied)
            default: throw AgentError.internalError("kill failed with errno \(error)")
            }
        } catch {
            let rejection = (error as? AgentError)?.rejection
            try audit(record: record, client: client, outcome: "rejected", rejection: rejection)
            if let rejection {
                return try TerminationResult(outcome: .rejected, rejection: rejection, exitedConfirmed: false)
            }
            throw error
        }

        do {
            try audit(record: record, client: client, outcome: "signal_sent")
        } catch {
            throw AgentError.internalError("Signal sent, but audit write failed: \(error)")
        }
        do {
            try await clock.sleep(until: confirmationDeadline)
        } catch is CancellationError {
            return try TerminationResult(outcome: .signalSent, exitedConfirmed: false)
        }
        return try TerminationResult(outcome: .signalSent, exitedConfirmed: hasExited(key: record.ticket.processKey))
    }

    public func invalidateAll() {
        tokens.removeAll()
    }

    private func requireUnprotected(pid: Int32, client: Client) throws {
        guard pid > 1 else { throw AgentError.terminationRejected(.protectedPID) }
        guard pid != getpid(), pid != client.pid, !client.protectedPIDs.contains(pid) else {
            throw AgentError.terminationRejected(.self)
        }
    }

    private func readTarget(key: ProcessKey) throws -> Target {
        do {
            let pid = key.identity.pid
            guard let info = try source.bsdInfo(pid: pid) else { throw AgentError.terminationRejected(.exited) }
            guard try source.bootSessionID() == key.identity.bootSessionID, info.startTimeUS == key.identity.startTimeUS else {
                throw AgentError.terminationRejected(.processChanged)
            }
            guard let usage = try source.rusage(pid: pid) else { throw AgentError.terminationRejected(.exited) }
            let path = try source.path(pid: pid)
            guard let final = try source.bsdInfo(pid: pid) else { throw AgentError.terminationRejected(.exited) }
            guard usage.startTimeUS == info.startTimeUS, final.startTimeUS == info.startTimeUS,
                  final.uid == info.uid, final.name == info.name
            else {
                throw AgentError.terminationRejected(.processChanged)
            }
            return Target(uid: info.uid, name: info.name, path: path, executableUUID: usage.executableUUID)
        } catch ProcessSourceError.exited {
            throw AgentError.terminationRejected(.exited)
        } catch ProcessSourceError.permissionDenied {
            throw AgentError.terminationRejected(.permissionDenied)
        } catch let error as AgentError {
            throw error
        } catch {
            throw AgentError.internalError("Could not revalidate process: \(error)")
        }
    }

    private func hasExited(key: ProcessKey) -> Bool {
        do {
            guard let info = try source.bsdInfo(pid: key.identity.pid) else { return true }
            return try info.startTimeUS != key.identity.startTimeUS || source.bootSessionID() != key.identity.bootSessionID
        } catch ProcessSourceError.exited {
            return true
        } catch {
            // An unreadable process is not evidence of an exit.
            return false
        }
    }

    private func audit(record: TokenRecord, client: Client, outcome: String, rejection: TerminationRejection? = nil) throws {
        try audit(key: record.ticket.processKey, name: record.ticket.name, signal: record.ticket.signal,
                  client: client, outcome: outcome, rejection: rejection)
    }

    private func audit(key: ProcessKey, name: String, signal: TerminationSignal, client: Client,
                       outcome: String, rejection: TerminationRejection? = nil) throws
    {
        try auditLog.append(AuditEntry(timestamp: Date(), clientKind: client.kind, clientPID: client.pid,
                                       processKey: key, pid: key.identity.pid, name: name, signal: signal,
                                       outcome: outcome, rejection: rejection))
    }
}
