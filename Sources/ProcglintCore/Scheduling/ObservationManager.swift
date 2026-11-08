import Foundation

public actor ObservationManager {
    private struct Entry: Sendable {
        var observation: Observation
        var clientID: String
        var started: UInt64
        var deadline: UInt64
        var ended: UInt64?
        var endedAt: Date?
    }

    private let scheduler: SamplingScheduler
    private let clock: any MonotonicClock
    private let wallNow: @Sendable () -> Date
    private var entries: [String: Entry] = [:]

    public init(scheduler: SamplingScheduler, clock: any MonotonicClock,
                wallNow: @escaping @Sendable () -> Date = { Date() })
    {
        self.scheduler = scheduler
        self.clock = clock
        self.wallNow = wallNow
    }

    public func start(_ request: ObservationRequest, clientID: String) async throws -> Observation {
        try request.validate()
        refresh()
        let id = UUID().uuidString
        let started = clock.now
        let date = wallNow()
        let deadline = started + UInt64(request.durationMS) * 1_000_000
        let observation = Observation(observationID: id, intervalMS: request.intervalMS, startedAt: date,
                                      expiresAt: date.addingTimeInterval(Double(request.durationMS) / 1000),
                                      processKeys: request.processKeys, state: .active)
        entries[id] = Entry(observation: observation, clientID: clientID, started: started, deadline: deadline)
        let lease = SamplingLease(leaseID: id, clientID: clientID, kind: .observation, intervalMS: request.intervalMS, expiresAt: deadline)
        do {
            try await scheduler.startObservationLease(lease, keys: request.processKeys)
        } catch {
            entries.removeValue(forKey: id)
            throw error
        }
        // A disconnect or stop may have reentered while the scheduler accepted the lease.
        guard entries[id]?.observation.state == .active else {
            try await scheduler.releaseLease(id: id, clientID: clientID)
            throw AgentError.agentUnavailable("Observation was stopped while starting")
        }
        return try self.observation(id: id, clientID: clientID)
    }

    public func observation(id: String, clientID: String) throws -> Observation {
        refresh()
        return try owned(id, clientID: clientID).observation
    }

    public func stop(id: String, clientID: String) async throws {
        refresh()
        var entry = try owned(id, clientID: clientID)
        if entry.observation.state == .active {
            entry.observation.state = .stopped
            entry.ended = clock.now
            entry.endedAt = wallNow()
            entries[id] = entry
        }
        try await scheduler.releaseLease(id: id, clientID: clientID)
    }

    /// The agent uses this disconnect entry point to remove both observations and all other leases.
    public func clientDisconnected(_ clientID: String) async {
        entries = entries.filter { $0.value.clientID != clientID }
        await scheduler.clientDisconnected(clientID)
    }

    public func history(id: String, clientID: String, since: Date? = nil) async throws -> [HistorySeries] {
        refresh()
        let entry = try owned(id, clientID: clientID)
        let start = max(since ?? entry.observation.startedAt, entry.observation.startedAt)
        let end = entry.endedAt ?? min(wallNow(), entry.observation.expiresAt)
        let keys = entry.observation.processKeys.map(\.rawValue)
        let selectors = keys.isEmpty ? ["system"] : keys
        var result: [HistorySeries] = []
        for series in selectors {
            try await result.append(scheduler.history(series: series, since: start, until: end,
                                                      fromTick: entry.started, throughTick: entry.ended ?? min(clock.now, entry.deadline)))
        }
        return result
    }

    var retainedObservationCount: Int {
        refresh()
        return entries.count
    }

    private func owned(_ id: String, clientID: String) throws -> Entry {
        guard let entry = entries[id] else { throw AgentError.notFound("Observation not found") }
        guard entry.clientID == clientID else { throw AgentError.permissionDenied("Observation belongs to another client") }
        return entry
    }

    private func refresh() {
        let now = clock.now
        for id in Array(entries.keys) {
            guard var entry = entries[id] else { continue }
            if entry.observation.state == .active, now >= entry.deadline {
                entry.observation.state = .expired
                entry.ended = entry.deadline
                entry.endedAt = entry.observation.expiresAt
                entries[id] = entry
            }
            let end = entry.ended ?? entry.deadline
            if now > end, now - end > 600_000_000_000 {
                entries.removeValue(forKey: id)
            }
        }
    }
}
