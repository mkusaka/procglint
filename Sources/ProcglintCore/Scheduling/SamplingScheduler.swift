import Foundation

public actor SamplingScheduler {
    public struct Diagnostics: Sendable {
        public var collectionsTotal: UInt64
        public var lastCollectionMS: Double
        public var collectionP95MS: Double
        public var failures: [String: UInt64]
        public var lastCoverage: Coverage
        public var leases: [MonitorStatus.LeaseSummary]
    }

    private let clock: any MonotonicClock
    private let collect: @Sendable () async throws -> Snapshot
    private var snapshots: SnapshotStore
    private var historyStore: HistoryStore
    private var leases: [String: SamplingLease] = [:]
    private var clients: Set<String> = []
    private var idleSince: UInt64?
    private var inFlight: Task<Snapshot, any Error>?
    private var timer: Task<Void, Never>?
    private var timerGeneration: UInt64 = 0
    private var lastStarted: UInt64?
    private var successfulCollections = 0
    private var warmupPending = false
    private var stopped = false
    private var durations = BoundedRing<Double>(capacity: 128)
    private var collectionsTotal: UInt64 = 0
    private var lastDuration: Double = 0
    private var failures: [String: UInt64] = [:]
    private var lastCoverage = Coverage()
    private var subscribers: [UUID: AsyncStream<Snapshot>.Continuation] = [:]
    private var subscriberScopes: [UUID: AccessScope] = [:]

    public init(clock: any MonotonicClock, policy: SamplingPolicy,
                wallNow: @escaping @Sendable () -> Date = { Date() },
                collect: @escaping @Sendable () async throws -> Snapshot) throws
    {
        self.clock = clock
        self.collect = collect
        snapshots = SnapshotStore(clock: clock)
        historyStore = try HistoryStore(clock: clock, policy: policy, wallNow: wallNow)
        idleSince = clock.now
    }

    public var effectiveInterval: SamplingInterval? {
        let now = clock.now
        return leases.values.filter { $0.expiresAt > now }.map(\.intervalMS).min { $0.rawValue < $1.rawValue }
    }

    public func clientConnected(_ clientID: String) {
        clients.insert(clientID)
        idleSince = nil
    }

    public func clientDisconnected(_ clientID: String) {
        clients.remove(clientID)
        if clients.isEmpty, idleSince == nil {
            idleSince = clock.now
        }
        for lease in leases.values where lease.clientID == clientID {
            historyStore.untrack(owner: lease.leaseID)
        }
        leases = leases.filter { $0.value.clientID != clientID }
        replan()
    }

    public func hasBeenIdle(graceMS: Int = 60000) -> Bool {
        guard graceMS >= 0, let idleSince else { return false }
        return clock.now >= idleSince && (clock.now - idleSince) / 1_000_000 >= UInt64(graceMS)
    }

    @discardableResult
    public func setLease(_ request: LeaseRequest, clientID: String) throws -> SamplingLease {
        try request.validate()
        guard !stopped else { throw AgentError.agentUnavailable("Scheduler is shut down") }
        guard !clientID.isEmpty else { throw AgentError.invalidArgument("Lease requires a client") }
        let existing = leases.values.first { $0.clientID == clientID && $0.kind == request.kind }
        let lease = SamplingLease(leaseID: existing?.leaseID ?? UUID().uuidString, clientID: clientID,
                                  kind: request.kind, intervalMS: request.intervalMS, expiresAt: clock.now + 30_000_000_000)
        if request.kind == .guiWindow {
            try historyStore.track(keys: request.processKeys, owner: lease.leaseID, until: lease.expiresAt)
        }
        leases[lease.leaseID] = lease
        replan()
        return lease
    }

    public func addLease(_ lease: SamplingLease) throws {
        guard !stopped else { throw AgentError.agentUnavailable("Scheduler is shut down") }
        guard !lease.leaseID.isEmpty, !lease.clientID.isEmpty, lease.expiresAt > clock.now else {
            throw AgentError.invalidArgument("Lease requires an id, client, and future monotonic deadline")
        }
        if let old = leases[lease.leaseID], old.clientID != lease.clientID {
            throw AgentError.permissionDenied("Lease belongs to another client")
        }
        leases[lease.leaseID] = lease
        replan()
    }

    public func releaseLease(id: String, clientID: String) throws {
        guard let lease = leases[id] else { return }
        guard lease.clientID == clientID else { throw AgentError.permissionDenied("Lease belongs to another client") }
        leases.removeValue(forKey: id)
        historyStore.untrack(owner: id)
        replan()
    }

    public func startObservationLease(_ lease: SamplingLease, keys: [ProcessKey]) throws {
        guard lease.kind == .observation, lease.expiresAt > clock.now, leases[lease.leaseID] == nil else {
            throw AgentError.invalidArgument("Observation requires a new lease and future deadline")
        }
        try historyStore.track(keys: keys, owner: lease.leaseID, until: lease.expiresAt)
        do {
            try addLease(lease)
        } catch {
            historyStore.untrack(owner: lease.leaseID)
            throw error
        }
    }

    public func didWake() {
        historyStore.recordGap()
        dropExpiredLeases()
        replan()
    }

    public func freshSnapshot(maxAge: Int? = nil, scope: AccessScope = AccessScope()) async throws -> Snapshot {
        guard !stopped else { throw AgentError.agentUnavailable("Scheduler is shut down") }
        if let maxAge, maxAge < 0 {
            throw AgentError.invalidArgument("maxAge must be nonnegative milliseconds")
        }
        dropExpiredLeases()
        if let inFlight {
            _ = try await inFlight.value
        } else {
            let allowedAge = maxAge ?? effectiveInterval?.milliseconds ?? 5000
            if let cached = snapshots.latest(scope: scope, effectiveInterval: effectiveInterval), cached.ageMS <= allowedAge {
                return cached
            }
            _ = try await beginCollection().value
        }
        guard let snapshot = snapshots.latest(scope: scope, effectiveInterval: effectiveInterval) else {
            throw AgentError.agentUnavailable("No snapshot collected")
        }
        return snapshot
    }

    public func listProcesses(_ query: ProcessQuery, scope: AccessScope) throws -> ProcessPage {
        try snapshots.listProcesses(query, scope: scope, pinned: historyStore.pinned, effectiveInterval: effectiveInterval)
    }

    public func listProcessesJSON(_ query: ProcessQuery, scope: AccessScope) throws -> Data {
        try snapshots.listProcessesJSON(query, scope: scope, pinned: historyStore.pinned, effectiveInterval: effectiveInterval)
    }

    public func pin(key: ProcessKey, pinned: Bool) throws {
        try historyStore.pin(key: key, pinned: pinned)
    }

    public func setHistoryPolicy(_ policy: SamplingPolicy) throws {
        try historyStore.setPolicy(policy)
    }

    public func history(series: String, since: Date? = nil, until: Date? = nil,
                        fromTick: UInt64? = nil, throughTick: UInt64? = nil) throws -> HistorySeries
    {
        try historyStore.series(series, since: since, until: until, fromTick: fromTick, throughTick: throughTick)
    }

    public func historyBytesEstimate() -> UInt64 {
        historyStore.bytesEstimate()
    }

    public func diagnostics() -> Diagnostics {
        dropExpiredLeases()
        let now = clock.now
        let sorted = durations.elements().sorted()
        let p95 = sorted.isEmpty ? 0 : sorted[Int(ceil(Double(sorted.count) * 0.95)) - 1]
        return Diagnostics(collectionsTotal: collectionsTotal, lastCollectionMS: lastDuration, collectionP95MS: p95,
                           failures: failures, lastCoverage: lastCoverage,
                           leases: leases.values.sorted { $0.leaseID < $1.leaseID }.map {
                               MonitorStatus.LeaseSummary(kind: $0.kind, intervalMS: $0.intervalMS,
                                                          remainingMS: Int(clamping: ($0.expiresAt > now ? $0.expiresAt - now : 0) / 1_000_000))
                           })
    }

    /// Streams are already scope-filtered, and never retain more than one undelivered value.
    public func subscribe(scope: AccessScope) -> AsyncStream<Snapshot> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<Snapshot>.makeStream(bufferingPolicy: .bufferingNewest(1))
        guard !stopped else {
            continuation.finish()
            return stream
        }
        subscribers[id] = continuation
        subscriberScopes[id] = scope
        if let latest = snapshots.latest(scope: scope, effectiveInterval: effectiveInterval) {
            continuation.yield(latest)
        }
        continuation.onTermination = { [weak self] _ in Task { await self?.removeSubscriber(id) } }
        return stream
    }

    private func removeSubscriber(_ id: UUID) {
        subscribers.removeValue(forKey: id)
        subscriberScopes.removeValue(forKey: id)
    }

    public func shutdown() {
        stopped = true
        timerGeneration += 1
        timer?.cancel()
        timer = nil
        inFlight?.cancel()
        for subscriber in subscribers.values {
            subscriber.finish()
        }
        subscribers.removeAll()
        subscriberScopes.removeAll()
        for id in leases.keys {
            historyStore.untrack(owner: id)
        }
        leases.removeAll()
        historyStore.recordGap()
    }

    private func beginCollection() -> Task<Snapshot, any Error> {
        if let inFlight {
            return inFlight
        }
        let task = Task { try await self.performCollection() }
        inFlight = task
        return task
    }

    private func performCollection() async throws -> Snapshot {
        defer {
            inFlight = nil
            replan()
        }
        // The shared task includes throttling, so callers waiting for the next allowed start also join it.
        if let lastStarted, clock.now < lastStarted + 1_000_000_000 {
            try await clock.sleep(until: lastStarted + 1_000_000_000)
        }
        try Task.checkCancellation()
        let start = clock.now
        warmupPending = false
        lastStarted = start
        collectionsTotal += 1
        do {
            var snapshot = try await collect()
            try Task.checkCancellation()
            let capturedAt = clock.now
            recordDuration(since: start)
            if snapshot.status != .unavailable {
                successfulCollections += 1
                if successfulCollections == 1 {
                    warmupPending = true
                    snapshot.status = .warmingUp
                    if snapshot.system.cpuPercent.status == .ok {
                        snapshot.system.cpuPercent = .warmingUp
                    }
                    for index in snapshot.processes.indices {
                        if snapshot.processes[index].cpuPercent.status == .ok {
                            snapshot.processes[index].cpuPercent = .warmingUp
                        }
                        if snapshot.processes[index].diskReadBps.status == .ok {
                            snapshot.processes[index].diskReadBps = .warmingUp
                        }
                        if snapshot.processes[index].diskWriteBps.status == .ok {
                            snapshot.processes[index].diskWriteBps = .warmingUp
                        }
                    }
                }
            } else {
                failures["unavailable", default: 0] += 1
            }
            lastCoverage = snapshot.coverage
            snapshots.insert(snapshot, capturedAt: capturedAt)
            historyStore.record(snapshot, capturedAt: capturedAt)
            for (id, subscriber) in subscribers {
                if let scope = subscriberScopes[id], let latest = snapshots.latest(scope: scope, effectiveInterval: effectiveInterval) {
                    subscriber.yield(latest)
                }
            }
            return snapshot
        } catch {
            recordDuration(since: start)
            historyStore.recordGap()
            failures[failureReason(error), default: 0] += 1
            throw error
        }
    }

    private func recordDuration(since start: UInt64) {
        lastDuration = Double(clock.now >= start ? clock.now - start : 0) / 1_000_000
        durations.append(lastDuration)
    }

    private func failureReason(_ error: any Error) -> String {
        if let error = error as? AgentError {
            return error.code.rawValue
        }
        if let error = error as? ProcessSourceError {
            switch error {
            case .permissionDenied: return "permission_denied"
            case .exited: return "exited"
            case .enumerationFailed: return "enumeration_failed"
            case .unavailable: return "unavailable"
            }
        }
        return error is CancellationError ? "cancelled" : "internal"
    }

    private func dropExpiredLeases() {
        for lease in leases.values where lease.expiresAt <= clock.now {
            historyStore.untrack(owner: lease.leaseID)
        }
        let hadLeases = !leases.isEmpty
        leases = leases.filter { $0.value.expiresAt > clock.now }
        if hadLeases, leases.isEmpty {
            historyStore.recordGap()
        }
    }

    /// Periodic sleeps target due, the lower edge of [due, due + 10%]; leeway is tolerance, not added delay.
    /// MonotonicClock has no tolerance parameter: agent wiring must apply the 10% tolerance in
    /// SystemMonotonicClock via Task.sleep(for:tolerance:clock:), without shifting the deadline.
    /// Late wakes collect once, then anchor the next tick to that start.
    public var nextCollectionWindow: ClosedRange<UInt64>? {
        let now = clock.now
        if warmupPending, let lastStarted {
            let due = max(now, lastStarted + 1_000_000_000)
            return due ... due
        }
        guard let interval = effectiveInterval else { return nil }
        guard let lastStarted else { return now ... now }
        let due = max(now, lastStarted + interval.nanoseconds)
        return due ... max(due, lastStarted + interval.nanoseconds + interval.nanoseconds / 10)
    }

    private func replan() {
        timer?.cancel()
        timer = nil
        timerGeneration += 1
        guard !stopped else { return }
        dropExpiredLeases()
        if effectiveInterval == nil, !warmupPending, inFlight == nil {
            historyStore.recordGap()
        }
        let expiry = leases.values.map(\.expiresAt).min()
        let collection = inFlight == nil ? nextCollectionWindow?.lowerBound : nil
        guard let deadline = [expiry, collection].compactMap(\.self).min() else { return }
        let generation = timerGeneration
        let clock = clock
        timer = Task { [weak self] in
            do {
                try await clock.sleep(until: deadline)
                try Task.checkCancellation()
                await self?.timerFired(generation)
            } catch { /* Cancellation replaces the old deadline, not the collection. */ }
        }
    }

    private func timerFired(_ generation: UInt64) {
        guard generation == timerGeneration else { return }
        timer = nil
        dropExpiredLeases()
        if inFlight == nil, let window = nextCollectionWindow, clock.now >= window.lowerBound {
            let task = beginCollection()
            Task { _ = try? await task.value }
        }
        replan()
    }
}
