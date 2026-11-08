import Darwin
import Foundation
import ProcglintCore
import ProcglintIPC

public actor AgentService: AgentRequestHandler {
    private struct Session {
        var context: ClientContext
        var hello: ClientHello?
    }

    private struct TicketPermission {
        var clientID: String
        var signal: TerminationSignal
        var deadline: UInt64
    }

    private struct Bucket {
        var tokens: Double
        var updatedAt: UInt64
        let capacity: Double
        let perSecond: Double

        mutating func take(at now: UInt64) throws {
            let elapsed = now >= updatedAt ? Double(now - updatedAt) / 1_000_000_000 : 0
            tokens = min(capacity, tokens + elapsed * perSecond)
            updatedAt = now
            guard tokens >= 1 else { throw AgentError.rateLimited("Aggregate agent request limit reached") }
            tokens -= 1
        }
    }

    private let sampler: Sampler
    private let scheduler: SamplingScheduler
    private let observations: ObservationManager
    private let termination: TerminationController
    private let source: any ProcessSource
    private let clock: any MonotonicClock
    private let settings: any SettingsStore
    private let uptimeNow: @Sendable () -> UInt64
    private let exitAction: @Sendable () -> Void
    private let agentPID: Int32
    private let agentUID: UInt32
    private var clients: [String: Session] = [:]
    private var tickets: [String: TicketPermission] = [:]
    private var pendingPrepares = 0
    // History outlives processes; retain ownership only for series that Core actually retained.
    private var historyOwnership: [ProcessKey: Bool] = [:]
    private var policy: SamplingPolicy
    private var changingPolicy = false
    private var reads: Bucket
    private var mutations: Bucket
    private var idleSince: UInt64?
    private var previousRaw: UInt64
    private var previousUptime: UInt64
    private var housekeepingTask: Task<Void, Never>?
    private var housekeepingGeneration: UInt64 = 0
    private var stopped = false

    public init(sampler: Sampler, scheduler: SamplingScheduler, observations: ObservationManager,
                termination: TerminationController, source: any ProcessSource, clock: any MonotonicClock,
                settings: any SettingsStore, agentPID: Int32 = getpid(), agentUID: UInt32 = geteuid(),
                uptimeNow: @escaping @Sendable () -> UInt64 = { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) },
                exitAction: @escaping @Sendable () -> Void = { Darwin.exit(0) }) throws
    {
        self.sampler = sampler
        self.scheduler = scheduler
        self.observations = observations
        self.termination = termination
        self.source = source
        self.clock = clock
        self.settings = settings
        self.agentPID = agentPID
        self.agentUID = agentUID
        self.uptimeNow = uptimeNow
        self.exitAction = exitAction
        policy = try settings.samplingPolicy()
        try policy.validate()
        let now = clock.now
        reads = Bucket(tokens: 120, updatedAt: now, capacity: 120, perSecond: 60)
        mutations = Bucket(tokens: 20, updatedAt: now, capacity: 20, perSecond: 5)
        idleSince = now
        previousRaw = now
        previousUptime = uptimeNow()
    }

    deinit { housekeepingTask?.cancel() }

    public func start() {
        replanHousekeeping()
    }

    public func shutdown() async {
        stopped = true
        housekeepingTask?.cancel()
        housekeepingTask = nil
        clients.removeAll()
        tickets.removeAll()
        await termination.invalidateAll()
        await scheduler.shutdown()
    }

    public func clientConnected(_ client: ClientContext) async {
        guard !stopped, client.uid == agentUID, client.pid > 0, clients[client.clientID] == nil else { return }
        clients[client.clientID] = Session(context: client)
        idleSince = nil
        replanHousekeeping()
        await scheduler.clientConnected(client.clientID)
    }

    public func clientDisconnected(_ client: ClientContext) async {
        guard clients[client.clientID]?.context == client else { return }
        clients.removeValue(forKey: client.clientID)
        tickets = tickets.filter { $0.value.clientID != client.clientID }
        if clients.isEmpty {
            idleSince = clock.now
        }
        await observations.clientDisconnected(client.clientID)
        replanHousekeeping()
    }

    public func handle(_ request: AgentRequest, from client: ClientContext) async -> AgentResponse {
        do {
            try requireClient(client)
            if case let .hello(hello) = request {
                guard clients[client.clientID]?.hello == nil, !hello.version.isEmpty, hello.version.utf8.count <= 64 else {
                    throw AgentError.invalidArgument("Invalid or duplicate hello")
                }
                clients[client.clientID]?.hello = hello
                return .hello(clientID: client.clientID)
            }
            let hello = try clientHello(client)
            let permissions = try permissions(for: hello)
            switch request {
            case .snapshot, .listProcesses, .process, .history, .status, .policy:
                try reads.take(at: clock.now)
            case .prepareTermination, .terminate: break // Admission denials also need a termination audit.
            default:
                try mutations.take(at: clock.now)
            }
            let response = try await respond(to: request, client: client, hello: hello, permissions: permissions)
            guard clients[client.clientID]?.context == client else {
                // An operation suspended on another actor may have installed a lease after disconnect cleanup.
                await observations.clientDisconnected(client.clientID)
                throw AgentError.agentUnavailable("Client disconnected")
            }
            switch response {
            case .snapshot, .listProcesses, .process, .history:
                guard try self.permissions(for: hello) == permissions else {
                    throw AgentError.permissionDenied("Settings changed during the request; retry")
                }
            default: break
            }
            return response
        } catch let error as AgentError {
            return .error(error)
        } catch is CancellationError {
            return .error(.agentUnavailable("Request cancelled"))
        } catch {
            return .error(.internalError("Agent request failed: \(error)"))
        }
    }

    private func requireClient(_ client: ClientContext) throws {
        guard !stopped, clients[client.clientID]?.context == client else {
            throw AgentError.agentUnavailable("Client disconnected")
        }
    }

    private func clientHello(_ client: ClientContext) throws -> ClientHello {
        try requireClient(client)
        guard let hello = clients[client.clientID]?.hello else { throw AgentError.invalidArgument("hello is required") }
        return hello
    }

    private func permissions(for hello: ClientHello) throws -> PermissionSet {
        let allowed = try settings.allowedPermissions()
        switch hello.clientKind {
        case .gui: return allowed
        case .mcp: return allowed.intersection(hello.mcpFlags ?? [])
        case .cli: return allowed.intersection([.includeSystem, .includePaths])
        }
    }

    private func require(_ permission: Permission, in permissions: PermissionSet) throws {
        guard permissions.contains(permission) else { throw AgentError.permissionDenied("Requires \(permission.rawValue)") }
    }

    private func requireGUI(_ hello: ClientHello) throws {
        guard hello.clientKind == .gui else { throw AgentError.permissionDenied("Requires a GUI client") }
    }

    private func requireConfigure(_ hello: ClientHello, permissions: PermissionSet) throws {
        guard hello.clientKind == .gui || (hello.clientKind == .mcp && permissions.contains(.configure)) else {
            throw AgentError.permissionDenied("Requires GUI or configure permission")
        }
    }

    private func respond(to request: AgentRequest, client: ClientContext, hello: ClientHello,
                         permissions: PermissionSet) async throws -> AgentResponse
    {
        let scope = AccessScope(permissions: permissions)
        switch request {
        case .hello: throw AgentError.invalidArgument("Duplicate hello")
        case let .snapshot(top, sort):
            let query = try ProcessQuery(filter: .all, sort: sort, limit: top)
            _ = try await scheduler.freshSnapshot(scope: scope)
            let page = try await scheduler.listProcesses(query, scope: scope)
            return .snapshot(Snapshot(header: page.snapshot, processes: page.items))
        case let .listProcesses(query):
            try query.validate()
            // A cursor must be resolved against retained snapshots before a refresh can evict it.
            if query.cursor == nil {
                _ = try await scheduler.freshSnapshot(scope: scope)
            }
            return try await .listProcesses(scheduler.listProcesses(query, scope: scope))
        case let .process(key):
            return try await .process(process(key: key, scope: scope))
        case let .history(request):
            return try await .history(history(request, client: client, scope: scope))
        case .status:
            return try await .status(monitorStatus())
        case let .setLease(request):
            try requireGUI(hello)
            try request.validate()
            let samples = try await visibleSamples(request.processKeys, scope: scope)
            try requireClient(client)
            let current = try self.permissions(for: hello)
            guard current.contains(.includeSystem) || samples.allSatisfy(\.isOwn) else {
                throw AgentError.notFound("Process is not visible")
            }
            let lease = try await scheduler.setLease(request, clientID: client.clientID)
            await rememberHistoryOwnership(samples)
            return .setLease(lease)
        case let .releaseLease(id):
            try requireGUI(hello)
            try await scheduler.releaseLease(id: id, clientID: client.clientID)
            return .releaseLease
        case let .startObservation(request):
            try require(.observe, in: permissions)
            try request.validate()
            let samples = try await visibleSamples(request.processKeys, scope: scope)
            try requireClient(client)
            try require(.observe, in: self.permissions(for: hello))
            let observation = try await observations.start(request, clientID: client.clientID)
            await rememberHistoryOwnership(samples)
            return .startObservation(observation)
        case let .stopObservation(id):
            try require(.observe, in: permissions)
            try await observations.stop(id: id, clientID: client.clientID)
            return .stopObservation
        case let .pin(key, pinned):
            try requireGUI(hello)
            let samples = try await visibleSamples([key], scope: scope, retainedHistory: !pinned)
            try requireClient(client)
            try await scheduler.pin(key: key, pinned: pinned)
            await rememberHistoryOwnership(samples)
            return .pin
        case .policy:
            try requireConfigure(hello, permissions: permissions)
            return .policy(policy)
        case let .setPolicy(proposed, expectedRevision):
            try requireConfigure(hello, permissions: permissions)
            return try await .setPolicy(updatePolicy(proposed, expectedRevision: expectedRevision))
        case let .prepareTermination(key, signal):
            let controllerClient: TerminationController.Client
            do {
                try mutations.take(at: clock.now)
                try require(.terminate, in: permissions)
                if signal == .kill {
                    try require(.forceKill, in: permissions)
                }
                tickets = tickets.filter { $0.value.deadline > clock.now }
                guard tickets.count + pendingPrepares < 64 else { throw AgentError.rateLimited("Too many outstanding termination tickets") }
                controllerClient = try terminationClient(client, kind: hello.clientKind)
            } catch {
                try await termination.auditRejection(key: key, signal: signal,
                                                     client: .init(clientID: client.clientID, kind: hello.clientKind, pid: client.pid, protectedPIDs: []),
                                                     rejection: terminationRejection(error))
                throw error
            }
            pendingPrepares += 1
            defer { pendingPrepares -= 1 }
            let ticket = try await termination.prepare(key: key, signal: signal, client: controllerClient, permissions: permissions)
            if clients[client.clientID] != nil {
                tickets[ticket.token] = TicketPermission(clientID: client.clientID, signal: signal, deadline: clock.now + 30_000_000_000)
            }
            return .prepareTermination(ticket)
        case let .terminate(token):
            let controllerClient: TerminationController.Client
            do {
                try mutations.take(at: clock.now)
                try require(.terminate, in: permissions)
                if let ticket = tickets[token], ticket.clientID == client.clientID, ticket.signal == .kill {
                    try require(.forceKill, in: permissions)
                }
                controllerClient = try terminationClient(client, kind: hello.clientKind)
            } catch {
                try await termination.auditRejection(token: token,
                                                     client: .init(clientID: client.clientID, kind: hello.clientKind, pid: client.pid, protectedPIDs: []),
                                                     rejection: terminationRejection(error))
                throw error
            }
            return try await .terminate(termination.terminate(token: token, client: controllerClient))
        }
    }

    private func process(key: ProcessKey, scope: AccessScope) async throws -> ProcessSample {
        let snapshot = try await scheduler.freshSnapshot(scope: scope)
        guard var sample = snapshot.processes.first(where: { $0.processKey == key && $0.status != .exited }) else {
            throw AgentError.notFound("Process is not visible or has exited")
        }
        do {
            if scope.includePaths {
                sample.path = try await sampler.path(for: key)
            }
            guard let info = try source.bsdInfo(pid: sample.pid), info.startTimeUS == key.identity.startTimeUS,
                  try source.bootSessionID() == key.identity.bootSessionID,
                  scope.includeSystem || info.uid == agentUID else { throw ProcessSourceError.exited }
        } catch ProcessSourceError.exited {
            throw AgentError.notFound("Process exited or changed")
        } catch ProcessSourceError.permissionDenied {
            if sample.status != .permissionDenied {
                throw AgentError.permissionDenied("Process is no longer readable")
            }
        }
        return sample
    }

    private func visibleSamples(_ keys: [ProcessKey], scope: AccessScope, retainedHistory: Bool = false) async throws -> [ProcessSample] {
        guard !keys.isEmpty else { return [] }
        let snapshot = try await scheduler.freshSnapshot(scope: AccessScope(includeSystem: true))
        var samples: [ProcessSample] = []
        for key in keys {
            if let sample = snapshot.processes.first(where: { $0.processKey == key && $0.status != .exited }) {
                guard scope.includeSystem || sample.isOwn else { throw AgentError.notFound("Process is not visible") }
                samples.append(sample)
            } else {
                guard retainedHistory, let wasOwn = historyOwnership[key], scope.includeSystem || wasOwn else {
                    throw AgentError.notFound("Process is not visible or has exited")
                }
            }
        }
        return samples
    }

    private func rememberHistoryOwnership(_ samples: [ProcessSample]) async {
        for key in Array(historyOwnership.keys) where await (try? scheduler.history(series: key.rawValue)) == nil {
            historyOwnership.removeValue(forKey: key)
        }
        for sample in samples where await (try? scheduler.history(series: sample.processKey.rawValue)) != nil {
            historyOwnership[sample.processKey] = sample.isOwn
        }
    }

    private func history(_ request: HistoryRequest, client: ClientContext, scope: AccessScope) async throws -> [HistorySeries] {
        guard !request.series.isEmpty, request.series.count <= 17 else { throw AgentError.invalidArgument("Request 1...17 history series") }
        var result: [HistorySeries] = []
        for selector in request.series {
            if selector == "system" {
                try await result.append(scheduler.history(series: selector, since: request.since))
            } else if selector.hasPrefix("p1.") {
                let key = try ProcessKey(selector)
                _ = try await visibleSamples([key], scope: scope, retainedHistory: true)
                try await result.append(scheduler.history(series: selector, since: request.since))
            } else {
                let observation = try await observations.observation(id: selector, clientID: client.clientID)
                _ = try await visibleSamples(observation.processKeys, scope: scope, retainedHistory: true)
                try await result.append(contentsOf: observations.history(id: selector, clientID: client.clientID, since: request.since))
            }
        }
        return result
    }

    private func monitorStatus() async throws -> MonitorStatus {
        let snapshot = try await scheduler.freshSnapshot(scope: AccessScope(includeSystem: true))
        let diagnostics = await scheduler.diagnostics()
        let interval = await scheduler.effectiveInterval
        let agent = snapshot.processes.first { $0.pid == agentPID }
        var summaries: [MonitorStatus.ClientSummary] = []
        for session in clients.values {
            guard let hello = session.hello else { continue }
            let sample = snapshot.processes.first { $0.pid == session.context.pid }
            let bytes = try footprint(sample, pid: session.context.pid)
            summaries.append(MonitorStatus.ClientSummary(clientID: session.context.clientID, kind: hello.clientKind, pid: session.context.pid,
                                                         footprintBytes: bytes, cpuPercent: sample?.cpuPercent ?? .unsupported))
        }
        summaries.sort { $0.clientID < $1.clientID }
        let agentFootprint = try footprint(agent, pid: agentPID)
        return await MonitorStatus(agentInstanceID: snapshot.agentInstanceID, agentPID: agentPID,
                                   agentCPUPercent: agent?.cpuPercent ?? .unsupported, agentFootprintBytes: agentFootprint,
                                   samplingActive: interval != nil, effectiveIntervalMS: interval,
                                   collectionsTotal: diagnostics.collectionsTotal, lastCollectionMS: diagnostics.lastCollectionMS,
                                   collectionP95MS: diagnostics.collectionP95MS, lastCoverage: diagnostics.lastCoverage,
                                   failures: diagnostics.failures, leases: diagnostics.leases, clients: summaries,
                                   historyBytes: scheduler.historyBytesEstimate(), policy: policy)
    }

    private func footprint(_ sample: ProcessSample?, pid: Int32) throws -> UInt64 {
        if let value = sample?.footprintBytes.value, value.isFinite, value >= 0, value < Double(UInt64.max) {
            return UInt64(value)
        }
        // MonitorStatus has a nonoptional byte count; fail rather than invent a zero measurement.
        guard let usage = try? source.rusage(pid: pid) else {
            throw AgentError.agentUnavailable("Resource counters unavailable for PID \(pid)")
        }
        return usage.footprintBytes
    }

    private func updatePolicy(_ proposed: SamplingPolicy, expectedRevision: Int) async throws -> SamplingPolicy {
        try proposed.validate()
        guard !changingPolicy, expectedRevision == policy.revision, policy.revision < Int.max else {
            throw AgentError.revisionConflict("Sampling policy revision changed")
        }
        changingPolicy = true
        defer { changingPolicy = false }
        let old = policy
        var updated = proposed
        updated.revision = old.revision + 1
        try await scheduler.setHistoryPolicy(updated)
        do { try settings.setSamplingPolicy(updated) } catch {
            try await scheduler.setHistoryPolicy(old)
            throw error
        }
        policy = updated
        return updated
    }

    var retainedTicketCount: Int {
        tickets.count
    }

    var retainedHistoryOwnershipCount: Int {
        historyOwnership.count
    }

    private func terminationRejection(_ error: any Error) -> TerminationRejection? {
        guard let error = error as? AgentError else { return nil }
        return error.rejection ?? (error.code == .permissionDenied ? .permissionDenied : nil)
    }

    private func terminationClient(_ client: ClientContext, kind: ClientKind) throws -> TerminationController.Client {
        var protected = Set(clients.values.map(\.context.pid))
        protected.insert(agentPID)
        var pid = client.pid
        var visited: Set<Int32> = []
        while pid > 1 {
            guard visited.insert(pid).inserted else {
                throw AgentError.terminationRejected(.permissionDenied, message: "Client parent chain changed during validation")
            }
            protected.insert(pid)
            do {
                guard let info = try source.bsdInfo(pid: pid) else { throw ProcessSourceError.exited }
                pid = info.ppid
            } catch {
                // Without a verified parent chain, fail closed rather than risk signalling the client's launcher.
                throw AgentError.terminationRejected(.permissionDenied, message: "Cannot verify the client's parent chain")
            }
        }
        return TerminationController.Client(clientID: client.clientID, kind: kind, pid: client.pid, protectedPIDs: protected)
    }

    /// Internal entry point also lets tests advance both clocks without depending on task scheduling.
    func housekeeping() async {
        guard !stopped else { return }
        let raw = clock.now
        let uptime = uptimeNow()
        let rawDelta = raw >= previousRaw ? raw - previousRaw : 0
        let uptimeDelta = uptime >= previousUptime ? uptime - previousUptime : 0
        previousRaw = raw
        previousUptime = uptime
        tickets = tickets.filter { $0.value.deadline > raw }
        if rawDelta > uptimeDelta, rawDelta - uptimeDelta > 2_000_000_000 {
            await scheduler.didWake()
        }
        if clients.isEmpty, let idleSince, raw >= idleSince, raw - idleSince >= 60_000_000_000 {
            stopped = true
            housekeepingTask?.cancel()
            housekeepingTask = nil
            exitAction()
        }
    }

    private func replanHousekeeping() {
        housekeepingTask?.cancel()
        housekeepingTask = nil
        housekeepingGeneration += 1
        guard !stopped else { return }
        let generation = housekeepingGeneration
        let deadline = clients.isEmpty ? (idleSince ?? clock.now) + 60_000_000_000 : clock.now + 5_000_000_000
        let clock = clock
        housekeepingTask = Task(priority: .background) { [weak self] in
            do {
                try await clock.sleep(until: deadline)
                try Task.checkCancellation()
                await self?.housekeepingFired(generation)
            } catch { /* A lifecycle change replaces the old deadline. */ }
        }
    }

    private func housekeepingFired(_ generation: UInt64) async {
        guard generation == housekeepingGeneration else { return }
        await housekeeping()
        if generation == housekeepingGeneration {
            replanHousekeeping()
        }
    }
}
