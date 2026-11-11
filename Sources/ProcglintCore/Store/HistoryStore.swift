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
        var points = BoundedRing<TimedPoint>(capacity: 600)
        var gaps = BoundedRing<TimedGap>(capacity: 600)
        var gapStart: Date?
        var gapStartTick: UInt64 = 0
        var latestTick: UInt64 = 0
        var lastTrackedTick: UInt64 = 0
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
    private var buffers: [String: Buffer] = ["system": Buffer()]
    private var owners: [String: Tracking] = [:]
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
        guard buffers.count - 1 <= policy.maxProcessSeries else {
            throw AgentError.historyLimitReached("Retained process history exceeds the new limit")
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
            markUntrackedGaps()
        }
    }

    public mutating func track(keys: [ProcessKey], owner: String, until deadline: UInt64) throws {
        prune()
        guard deadline > clock.now else { throw AgentError.invalidArgument("Tracking deadline must be in the future") }
        try reserve(Set(keys), replacingOwner: owner)
        owners[owner] = Tracking(keys: Set(keys), deadline: deadline)
        markUntrackedGaps()
    }

    public mutating func untrack(owner: String) {
        prune()
        owners.removeValue(forKey: owner)
        markUntrackedGaps()
    }

    public mutating func record(_ snapshot: Snapshot, capturedAt: UInt64? = nil) {
        prune()
        let tick = capturedAt ?? clock.now
        guard snapshot.status != .unavailable else {
            recordGap()
            return
        }
        append(HistoryPoint(t: snapshot.sampledAt, cpuPercent: snapshot.system.cpuPercent,
                            memoryUsedBytes: .ok(Double(snapshot.system.memoryUsedBytes)),
                            memoryPressurePercent: snapshot.system.memoryPressurePercent,
                            memoryPressure: snapshot.system.memoryPressure.value,
                            systemPowerMW: snapshot.system.battery?.systemPowerMW,
                            batteryPercent: snapshot.system.battery?.percent,
                            networkReceiveBps: snapshot.system.networkReceiveBps,
                            networkSendBps: snapshot.system.networkSendBps), to: "system", tick: tick)
        let samples = Dictionary(snapshot.processes.map { ($0.processKey, $0) }, uniquingKeysWith: { _, latest in latest })
        for key in trackedKeys {
            let name = key.rawValue
            buffers[name]?.latestTick = tick
            guard let process = samples[key], process.status != .exited else {
                openGap(name, at: snapshot.sampledAt)
                continue
            }
            append(HistoryPoint(t: snapshot.sampledAt, cpuPercent: process.cpuPercent, footprintBytes: process.footprintBytes,
                                diskReadBps: process.diskReadBps, diskWriteBps: process.diskWriteBps,
                                powerMW: process.powerMW, networkReceiveBps: process.networkReceiveBps,
                                networkSendBps: process.networkSendBps), to: name, tick: tick)
        }
    }

    /// Stops and wake both break chart continuity, even if no collection occurs during the gap.
    public mutating func recordGap() {
        for name in buffers.keys {
            openGap(name, at: wallNow())
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
        let selected = buffer.points.elements().filter {
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
        var total = 0
        for buffer in buffers.values {
            let points: Int = buffer.points.capacity * MemoryLayout<TimedPoint?>.stride
            let gaps: Int = buffer.gaps.capacity * MemoryLayout<TimedGap?>.stride
            total += points + gaps + 256
        }
        return UInt64(total)
    }

    private var trackedKeys: Set<ProcessKey> {
        owners.values.reduce(pinned) { $0.union($1.keys) }
    }

    private mutating func reserve(_ keys: Set<ProcessKey>, replacingOwner: String? = nil) throws {
        let new = keys.filter { buffers[$0.rawValue] == nil }
        let needed = buffers.count - 1 + new.count - maximumSeries
        if needed > 0 {
            // Reserve against the replacement ownership without changing it if the request fails.
            var protected = pinned.union(keys)
            for (owner, tracking) in owners where owner != replacingOwner {
                protected.formUnion(tracking.keys)
            }
            let names = Set(protected.map(\.rawValue))
            let candidates = buffers.filter { $0.key != "system" && !names.contains($0.key) }.sorted {
                if $0.value.lastTrackedTick == $1.value.lastTrackedTick {
                    return $0.key < $1.key
                }
                return $0.value.lastTrackedTick < $1.value.lastTrackedTick
            }
            guard candidates.count >= needed else { throw AgentError.historyLimitReached("Process history limit reached") }
            for candidate in candidates.prefix(needed) {
                buffers.removeValue(forKey: candidate.key)
            }
        }
        for key in new {
            buffers[key.rawValue] = Buffer(latestTick: clock.now, lastTrackedTick: clock.now)
        }
    }

    private mutating func append(_ point: HistoryPoint, to name: String, tick: UInt64) {
        if let start = buffers[name]?.gapStart {
            let fromTick = buffers[name]?.gapStartTick ?? tick
            buffers[name]?.gaps.append(TimedGap(fromTick: fromTick, tick: tick, gap: HistoryGap(from: start, to: point.t)))
            buffers[name]?.gapStart = nil
        }
        buffers[name]?.latestTick = tick
        let sequence = buffers[name]?.nextSequence ?? 0
        buffers[name]?.points.append(TimedPoint(tick: tick, sequence: sequence, point: point))
        buffers[name]?.nextSequence += 1
    }

    private mutating func openGap(_ name: String, at date: Date) {
        guard buffers[name]?.gapStart == nil else { return }
        buffers[name]?.gapRevision += 1
        let last = buffers[name]?.points.last
        let startTick = last?.tick ?? clock.now
        buffers[name]?.gapStart = last?.point.t ?? date
        buffers[name]?.gapStartTick = startTick
    }

    private mutating func markUntrackedGaps() {
        let active = Set(trackedKeys.map(\.rawValue))
        let now = clock.now
        for name in buffers.keys where name != "system" {
            if active.contains(name) {
                buffers[name]?.lastTrackedTick = now
            } else {
                openGap(name, at: wallNow())
            }
        }
    }

    private mutating func prune() {
        let now = clock.now
        for tracking in owners.values where tracking.deadline <= now {
            for key in tracking.keys {
                let last = buffers[key.rawValue]?.lastTrackedTick ?? 0
                buffers[key.rawValue]?.lastTrackedTick = max(last, tracking.deadline)
            }
        }
        owners = owners.filter { $0.value.deadline > now }
        markUntrackedGaps()
        let cutoff = now > windowNS ? now - windowNS : 0
        let active = Set(trackedKeys.map(\.rawValue))
        for name in Array(buffers.keys) {
            while let first = buffers[name]?.points.first, first.tick < cutoff {
                buffers[name]?.points.removeFirst()
            }
            while let first = buffers[name]?.gaps.first, first.tick < cutoff {
                buffers[name]?.gaps.removeFirst()
            }
            if name != "system", !active.contains(name), buffers[name]?.points.count == 0, buffers[name]?.gaps.count == 0,
               (buffers[name]?.latestTick ?? 0) < cutoff
            {
                buffers.removeValue(forKey: name)
            }
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
