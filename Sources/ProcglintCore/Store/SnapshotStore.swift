import Foundation

/// Value storage; the scheduler serializes mutations. Capture times never come from wall time.
public struct SnapshotStore: Sendable {
    private struct Entry: Sendable {
        var snapshot: Snapshot
        var capturedAt: UInt64
    }

    private struct CacheKey: Hashable {
        var snapshotID: String
        var scope: AccessScope
        var sort: ProcessSort
        var order: SortOrder
        var filter: ProcessFilter
        var pins: Set<ProcessKey>
    }

    private struct Cursor: Codable {
        var storeID: String
        var snapshotID: String
        var offset: Int
        var scope: AccessScope
        var query: ProcessQuery
        var pins: [ProcessKey]

        // Cursor wire keys stay beside their private payload.
        // swiftlint:disable:next nesting
        enum CodingKeys: String, CodingKey {
            case storeID = "storeId"
            case snapshotID = "snapshotId"
            case offset, scope, query, pins
        }
    }

    private let clock: any MonotonicClock
    private let storeID = UUID().uuidString
    private var entries: [Entry] = []
    private var cache: [CacheKey: [ProcessSample]] = [:]
    private var cacheOrder: [CacheKey] = []
    private(set) var querySortCount = 0

    public init(clock: any MonotonicClock) {
        self.clock = clock
    }

    var retainedSnapshotCount: Int {
        entries.count
    }

    var responseCacheCount: Int {
        cache.count
    }

    public var capturedAt: UInt64? {
        entries.last?.capturedAt
    }

    public mutating func insert(_ snapshot: Snapshot, capturedAt: UInt64? = nil) {
        entries.removeAll { $0.snapshot.snapshotID == snapshot.snapshotID }
        entries.append(Entry(snapshot: snapshot, capturedAt: capturedAt ?? clock.now))
        if entries.count > 2 {
            entries.removeFirst()
        }
        cache.removeAll(keepingCapacity: true)
        cacheOrder.removeAll(keepingCapacity: true)
    }

    public func latest(scope: AccessScope = AccessScope(), effectiveInterval: SamplingInterval? = nil) -> Snapshot? {
        guard let entry = entries.last else { return nil }
        var snapshot = aged(entry, interval: effectiveInterval)
        snapshot.processes = scoped(snapshot.processes, scope: scope)
        return snapshot
    }

    /// Typed items retain their required fields; use listProcessesJSON for a field-selected wire response.
    public mutating func listProcesses(_ query: ProcessQuery, scope: AccessScope,
                                       pinned: Set<ProcessKey> = [], effectiveInterval: SamplingInterval? = nil) throws -> ProcessPage
    {
        try query.validate()
        var normalized = query
        normalized.cursor = nil
        normalized.fields = nil
        normalized.limit = 50
        let pins = query.filter == .pinned ? pinned.sorted { $0.rawValue < $1.rawValue } : []
        var offset = 0
        let entry: Entry
        if let token = query.cursor {
            guard token.utf8.count <= 8192, let data = Data(base64Encoded: token),
                  let cursor = try? ProcglintJSON.decoder().decode(Cursor.self, from: data),
                  cursor.storeID == storeID, cursor.scope == scope, cursor.query == normalized, cursor.pins == pins,
                  cursor.offset > 0,
                  let retained = entries.first(where: { $0.snapshot.snapshotID == cursor.snapshotID })
            else {
                throw AgentError.invalidCursor("Cursor expired or belongs to another snapshot, query, or scope")
            }
            entry = retained
            offset = cursor.offset
        } else {
            guard let latest = entries.last else { throw AgentError.agentUnavailable("No snapshot collected") }
            entry = latest
        }
        let key = CacheKey(snapshotID: entry.snapshot.snapshotID, scope: scope, sort: query.sort,
                           order: query.order, filter: query.filter, pins: Set(pins))
        let processes: [ProcessSample]
        if let cached = cache[key] {
            processes = cached
        } else {
            processes = scoped(entry.snapshot.processes, scope: scope).filter {
                (query.filter != .mine || $0.isOwn) && (query.filter != .pinned || pinned.contains($0.processKey))
            }.sorted { precedes($0, $1, sort: query.sort, order: query.order) }
            querySortCount += 1
            if cacheOrder.count == 8 {
                cache.removeValue(forKey: cacheOrder.removeFirst())
            }
            cache[key] = processes
            cacheOrder.append(key)
        }
        let matches = processes.filter { process in
            guard let search = query.search, !search.isEmpty else { return true }
            if search.utf8.allSatisfy({ (48 ... 57).contains($0) }) {
                return Int32(search) == process.pid
            }
            return process.name.range(of: search, options: .caseInsensitive) != nil
        }
        guard offset <= matches.count else { throw AgentError.invalidCursor("Cursor offset is out of range") }
        let end = min(offset + query.limit, matches.count)
        let next: String? = if end < matches.count {
            try ProcglintJSON.encoder().encode(Cursor(storeID: storeID, snapshotID: entry.snapshot.snapshotID,
                                                      offset: end, scope: scope, query: normalized, pins: pins)).base64EncodedString()
        } else {
            nil
        }
        return ProcessPage(snapshot: aged(entry, interval: effectiveInterval).header,
                           items: Array(matches[offset ..< end]), nextCursor: next, totalMatched: matches.count)
    }

    public mutating func listProcessesJSON(_ query: ProcessQuery, scope: AccessScope,
                                           pinned: Set<ProcessKey> = [], effectiveInterval: SamplingInterval? = nil) throws -> Data
    {
        try listProcesses(query, scope: scope, pinned: pinned, effectiveInterval: effectiveInterval).jsonData(fields: query.fields)
    }

    private func aged(_ entry: Entry, interval: SamplingInterval?) -> Snapshot {
        var snapshot = entry.snapshot
        snapshot.ageMS = Int(clamping: (clock.now >= entry.capturedAt ? clock.now - entry.capturedAt : 0) / 1_000_000)
        if snapshot.status != .unavailable, snapshot.ageMS > 3 * (interval?.milliseconds ?? 5000) {
            snapshot.status = .stale
        }
        return snapshot
    }

    private func scoped(_ processes: [ProcessSample], scope: AccessScope) -> [ProcessSample] {
        processes.filter { scope.includeSystem || $0.isOwn }.map {
            var sample = $0
            sample.hideCommandLines()
            sample.ancestors = nil
            sample.ancestorsIncomplete = nil
            sample.childrenCount = nil
            if !scope.includePaths {
                sample.path = nil
            }
            return sample
        }
    }

    private func precedes(_ lhs: ProcessSample, _ rhs: ProcessSample, sort: ProcessSort, order: SortOrder) -> Bool {
        let comparison: ComparisonResult
        switch sort {
        case .name: comparison = lhs.name.caseInsensitiveCompare(rhs.name)
        case .pid: comparison = compare(lhs.pid, rhs.pid)
        case .cpuTime:
            if lhs.cpuTimeNS == nil || rhs.cpuTimeNS == nil {
                return missingLast(lhs.cpuTimeNS, rhs.cpuTimeNS, lhs: lhs, rhs: rhs)
            }
            comparison = compare(lhs.cpuTimeNS, rhs.cpuTimeNS)
        default:
            let left = metric(lhs, sort: sort).value
            let right = metric(rhs, sort: sort).value
            if left == nil || right == nil {
                return missingLast(left, right, lhs: lhs, rhs: rhs)
            }
            comparison = compare(left, right)
        }
        if comparison == .orderedSame {
            return lhs.processKey.rawValue < rhs.processKey.rawValue
        }
        return order == .asc ? comparison == .orderedAscending : comparison == .orderedDescending
    }

    private func compare<T: Comparable>(_ lhs: T?, _ rhs: T?) -> ComparisonResult {
        guard let lhs, let rhs else { return .orderedSame }
        return lhs == rhs ? .orderedSame : (lhs < rhs ? .orderedAscending : .orderedDescending)
    }

    private func missingLast(_ left: (some Sendable)?, _ right: (some Sendable)?, lhs: ProcessSample, rhs: ProcessSample) -> Bool {
        if left == nil, right == nil {
            return lhs.processKey.rawValue < rhs.processKey.rawValue
        }
        return left != nil
    }

    private func metric(_ process: ProcessSample, sort: ProcessSort) -> Metric {
        switch sort {
        case .cpu: process.cpuPercent
        case .power: process.powerMW
        case .footprint: process.footprintBytes
        case .rss: process.rssBytes
        case .diskReadBps: process.diskReadBps
        case .diskWriteBps: process.diskWriteBps
        default: .unsupported
        }
    }
}

public extension ProcessPage {
    /// ProcessSample has required fields; projection belongs at the JSON boundary, not in fabricated samples.
    func jsonData(fields: [ProcessField]? = nil) throws -> Data {
        let data = try ProcglintJSON.encoder().encode(self)
        guard let fields else { return data }
        guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = object["items"] as? [[String: Any]]
        else {
            throw AgentError.internalError("Invalid encoded process page")
        }
        let selected = Set(fields.map(\.rawValue)).union([ProcessField.processKey.rawValue])
        object["items"] = items.map { item in
            item.filter { selected.contains($0.key) }
        }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}
