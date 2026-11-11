import Foundation

private struct HistoryCheckpoint: Codable {
    var store: String
    var buffer: String
    var series: String
    @JSONString var first: UInt64
    @JSONString var next: UInt64
    @JSONString var gap: UInt64
    var open: Bool
    var since: Date?
    var until: Date?
    @OptionalJSONString var fromTick: UInt64?
    @OptionalJSONString var throughTick: UInt64?
}

public struct HistoryStore: Sendable {
    private struct TimedPoint: Sendable {
        var tick: UInt64
        var sequence: UInt64
        var point: HistoryPoint
    }

    private struct TimedGap: Sendable {
        var fromTick: UInt64
        var tick: UInt64
        var gap: HistoryGap
    }

    private struct Buffer: Sendable {
        var id = UUID().uuidString
        var nextSequence: UInt64 = 0
        var gapRevision: UInt64 = 0
        var systemPoints: BoundedRing<TimedPoint>?
        var processPoints = BoundedRing<CompactProcessPoint>(capacity: 600, preallocate: false)
        var gaps = BoundedRing<TimedGap>(capacity: 600, preallocate: false)
        var gapStart: Date?
        var gapStartTick: UInt64 = 0
        var latestTick: UInt64 = 0
        var seenCollection: UInt64 = 0
        var isOwn: Bool?

        var lastTick: UInt64? {
            systemPoints?.last?.tick ?? processPoints.last?.tick
        }

        var lastDate: Date? {
            systemPoints?.last?.point.t ?? processPoints.last?.t
        }

        mutating func closeGap(at date: Date, tick: UInt64) {
            if let start = gapStart {
                gaps.append(TimedGap(fromTick: gapStartTick, tick: tick, gap: HistoryGap(from: start, to: date)))
                gapStart = nil
            }
            latestTick = tick
        }

        mutating func openGap(at date: Date, tick: UInt64) {
            guard gapStart == nil else { return }
            gapRevision += 1
            gapStart = lastDate ?? date
            gapStartTick = lastTick ?? tick
        }
    }

    private struct Tracking: Sendable {
        var keys: Set<ProcessKey>
        var deadline: UInt64
    }

    private let clock: any MonotonicClock
    private let storeID = UUID().uuidString
    private let wallNow: @Sendable () -> Date
    private var windowNS: UInt64
    private var maximumSeries: Int
    private var buffers: [String: Buffer] = ["system": Buffer(systemPoints: BoundedRing(capacity: 600))]
    private var owners: [String: Tracking] = [:]
    private var collection: UInt64 = 0
    public private(set) var pinned: Set<ProcessKey> = []

    public init(clock: any MonotonicClock, policy: SamplingPolicy, wallNow: @escaping @Sendable () -> Date = { Date() }) throws {
        try policy.validate()
        self.clock = clock
        self.wallNow = wallNow
        windowNS = UInt64(policy.historyMinutes) * 60_000_000_000
        maximumSeries = policy.maxProcessSeries
    }

    public mutating func setPolicy(_ policy: SamplingPolicy) throws {
        try policy.validate()
        prune()
        guard trackedKeys.count <= policy.maxProcessSeries else {
            throw AgentError.historyLimitReached("Explicit process history ownership exceeds the new limit")
        }
        windowNS = UInt64(policy.historyMinutes) * 60_000_000_000
        maximumSeries = policy.maxProcessSeries
        prune()
    }

    public mutating func pin(key: ProcessKey, pinned: Bool) throws {
        prune()
        if pinned {
            try reserve([key])
            self.pinned.insert(key)
        } else {
            self.pinned.remove(key)
        }
    }

    public mutating func track(keys: [ProcessKey], owner: String, until deadline: UInt64) throws {
        prune()
        guard deadline > clock.now else { throw AgentError.invalidArgument("Tracking deadline must be in the future") }
        try reserve(Set(keys), replacingOwner: owner)
        owners[owner] = Tracking(keys: Set(keys), deadline: deadline)
    }

    public mutating func untrack(owner: String) {
        prune()
        owners.removeValue(forKey: owner)
    }

    public mutating func record(_ snapshot: Snapshot, capturedAt: UInt64? = nil) {
        prune()
        let tick = capturedAt ?? clock.now
        guard snapshot.status != .unavailable else {
            recordGap()
            return
        }
        collection += 1
        let point = HistoryPoint(t: snapshot.sampledAt, cpuPercent: snapshot.system.cpuPercent,
                                 memoryUsedBytes: .ok(Double(snapshot.system.memoryUsedBytes)),
                                 memoryPressurePercent: snapshot.system.memoryPressurePercent,
                                 memoryPressure: snapshot.system.memoryPressure.value,
                                 systemPowerMW: snapshot.system.battery?.systemPowerMW,
                                 batteryPercent: snapshot.system.battery?.percent,
                                 networkReceiveBps: snapshot.system.networkReceiveBps,
                                 networkSendBps: snapshot.system.networkSendBps)
        buffers["system"]?.closeGap(at: point.t, tick: tick)
        let sequence = buffers["system"]?.nextSequence ?? 0
        buffers["system"]?.systemPoints?.append(TimedPoint(tick: tick, sequence: sequence, point: point))
        buffers["system"]?.nextSequence += 1
        for process in snapshot.processes where process.status != .exited {
            let name = process.processKey.rawValue
            if buffers[name] == nil {
                buffers[name] = Buffer(latestTick: tick)
            }
            Self.append(process, to: &buffers[name]!, at: snapshot.sampledAt, tick: tick, collection: collection)
        }
        for name in Array(buffers.keys) where name != "system" && buffers[name]?.seenCollection != collection {
            buffers[name]?.openGap(at: snapshot.sampledAt, tick: tick)
        }
    }

    private static func append(_ process: ProcessSample, to buffer: inout Buffer, at date: Date, tick: UInt64, collection: UInt64) {
        buffer.closeGap(at: date, tick: tick)
        buffer.isOwn = process.isOwn
        buffer.seenCollection = collection
        buffer.processPoints.append(CompactProcessPoint(process, at: date, tick: tick))
        buffer.nextSequence += 1
    }

    /// Scope metadata has exactly the same lifetime as the retained history, including after exit.
    public mutating func isOwnProcess(_ key: ProcessKey) -> Bool? {
        prune()
        return buffers[key.rawValue]?.isOwn
    }

    /// Stops and wake both break chart continuity, even if no collection occurs during the gap.
    public mutating func recordGap() {
        let date = wallNow()
        let tick = clock.now
        for name in Array(buffers.keys) {
            buffers[name]?.openGap(at: date, tick: tick)
        }
    }

    public mutating func series(_ name: String, since: Date? = nil, until: Date? = nil,
                                fromTick: UInt64? = nil, throughTick: UInt64? = nil) throws -> HistorySeries
    {
        prune()
        guard let buffer = buffers[name] else { throw AgentError.notFound("History series is not retained") }
        let now = clock.now
        let cutoff = now > windowNS ? now - windowNS : 0
        let lowerTick = max(cutoff, fromTick ?? 0)
        let upperTick = min(now, throughTick ?? now)
        let points: [TimedPoint]
        if let system = buffer.systemPoints {
            points = system.elements()
        } else {
            let first = buffer.nextSequence - UInt64(buffer.processPoints.count)
            points = buffer.processPoints.elements().enumerated().map {
                TimedPoint(tick: $0.element.tick, sequence: first + UInt64($0.offset), point: $0.element.point)
            }
        }
        let selected = points.filter {
            $0.point.t >= (since ?? .distantPast) && $0.point.t <= (until ?? .distantFuture) &&
                $0.tick >= lowerTick && $0.tick <= upperTick
        }
        var retainedGaps = buffer.gaps.elements()
        if let start = buffer.gapStart {
            retainedGaps.append(TimedGap(fromTick: buffer.gapStartTick, tick: now, gap: HistoryGap(from: start, to: wallNow())))
        }
        let gaps = retainedGaps.compactMap { timed -> HistoryGap? in
            let lower = max(timed.fromTick, lowerTick)
            let upper = min(timed.tick, upperTick)
            guard lower < upper else { return nil }
            let from = max(timed.gap.from.addingTimeInterval(Double(lower - timed.fromTick) / 1_000_000_000), since ?? .distantPast)
            let to = min(timed.gap.to.addingTimeInterval(-Double(timed.tick - upper) / 1_000_000_000), until ?? .distantFuture)
            return from <= to ? HistoryGap(from: from, to: to) : nil
        }
        let first = selected.first?.sequence ?? buffer.nextSequence
        let next = selected.last.map { $0.sequence + 1 } ?? first
        // A wall-date filter can select noncontiguous points after a clock adjustment; fall back to full history.
        let cursor: String? = next - first == UInt64(selected.count)
            ? try ProcglintJSON.encoder().encode(HistoryCheckpoint(
                store: storeID, buffer: buffer.id, series: name, first: first, next: next,
                gap: buffer.gapRevision, open: buffer.gapStart != nil, since: since, until: until,
                fromTick: fromTick, throughTick: throughTick
            )).base64EncodedString() : nil
        return HistorySeries(series: name, points: selected.map(\.point), gaps: gaps,
                             nextCursor: cursor, retainedPointCount: cursor.map { _ in selected.count })
    }

    public mutating func bytesEstimate() -> UInt64 {
        prune()
        var total = buffers.capacity * (MemoryLayout<String>.stride + MemoryLayout<Buffer>.stride + 8)
        for (name, buffer) in buffers {
            let system = (buffer.systemPoints?.capacity ?? 0) * MemoryLayout<TimedPoint?>.stride
            let process = buffer.processPoints.capacity * MemoryLayout<CompactProcessPoint?>.stride
            let gaps = buffer.gaps.capacity * MemoryLayout<TimedGap?>.stride
            total += system + process + gaps + name.utf8.count + 128
        }
        total += pinned.count * 64 + owners.values.reduce(0) { $0 + 128 + $1.keys.count * 64 }
        return UInt64(total)
    }

    private var trackedKeys: Set<ProcessKey> {
        owners.values.reduce(pinned) { $0.union($1.keys) }
    }

    private mutating func reserve(_ keys: Set<ProcessKey>, replacingOwner: String? = nil) throws {
        // Compatibility limits explicit ownership, never automatic recording or retention of sampled points.
        var protected = pinned.union(keys)
        for (owner, tracking) in owners where owner != replacingOwner {
            protected.formUnion(tracking.keys)
        }
        guard protected.count <= maximumSeries else { throw AgentError.historyLimitReached("Process history limit reached") }
        for key in keys where buffers[key.rawValue] == nil {
            buffers[key.rawValue] = Buffer(latestTick: clock.now)
        }
    }

    private mutating func prune() {
        let now = clock.now
        owners = owners.filter { $0.value.deadline > now }
        let cutoff = now > windowNS ? now - windowNS : 0
        let active = Set(trackedKeys.map(\.rawValue))
        // Copy keys rather than retaining dictionary storage, which would force copy-on-write of every ring.
        for name in Array(buffers.keys) {
            Self.prune(&buffers[name]!, before: cutoff)
            if name != "system", !active.contains(name), (buffers[name]?.latestTick ?? 0) < cutoff {
                buffers.removeValue(forKey: name)
            }
        }
    }

    private static func prune(_ buffer: inout Buffer, before cutoff: UInt64) {
        while let first = buffer.systemPoints?.first, first.tick < cutoff {
            buffer.systemPoints?.removeFirst()
        }
        while let first = buffer.processPoints.first, first.tick < cutoff {
            buffer.processPoints.removeFirst()
        }
        while let first = buffer.gaps.first, first.tick < cutoff {
            buffer.gaps.removeFirst()
        }
    }
}

public extension HistorySeries {
    /// A nil cursor preserves the legacy wire shape; empty/foreign/expired cursors request a full page.
    func delta(after cursor: String?) -> HistorySeries {
        var result = self
        guard let cursor else {
            result.nextCursor = nil
            result.isDelta = false
            result.retainedPointCount = nil
            return result
        }
        let currentData = nextCursor.flatMap { Data(base64Encoded: $0) }
        guard cursor.utf8.count <= 8192,
              let previousData = Data(base64Encoded: cursor), let currentData,
              let previous = try? ProcglintJSON.decoder().decode(HistoryCheckpoint.self, from: previousData),
              let current = try? ProcglintJSON.decoder().decode(HistoryCheckpoint.self, from: currentData),
              previous.store == current.store, previous.buffer == current.buffer, previous.series == current.series,
              previous.since == current.since, previous.until == current.until,
              previous.fromTick == current.fromTick, previous.throughTick == current.throughTick,
              previous.gap == current.gap, !previous.open, !current.open,
              current.first <= previous.next, previous.next <= current.next,
              current.next - current.first == UInt64(points.count)
        else { return result }
        result.points = Array(points.dropFirst(Int(previous.next - current.first)))
        result.isDelta = true
        return result
    }
}
