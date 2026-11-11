import Foundation

public enum ProcessFilter: String, Sendable, Codable, CaseIterable { case all, mine, pinned }
public enum SortOrder: String, Sendable, Codable, CaseIterable { case asc, desc }

public enum ProcessSort: String, Sendable, Codable, CaseIterable {
    case cpu, footprint, rss, power, network
    case diskReadBps = "disk_read_bps"
    case diskWriteBps = "disk_write_bps"
    case cpuTime = "cpu_time"
    case pid, name
}

public enum ProcessField: String, Sendable, Codable, CaseIterable {
    case processKey = "process_key"
    case pid, ppid, name, uid, user
    case isOwn = "is_own"
    case status
    case cpuPercent = "cpu_percent"
    case powerMW = "power_mw"
    case cpuTimeNS = "cpu_time_ns"
    case footprintBytes = "footprint_bytes"
    case rssBytes = "rss_bytes"
    case diskReadBytes = "disk_read_bytes"
    case diskWrittenBytes = "disk_written_bytes"
    case diskReadBps = "disk_read_bps"
    case diskWriteBps = "disk_write_bps"
    case networkReceiveBps = "network_receive_bps"
    case networkSendBps = "network_send_bps"
    case networkReceivedBytes = "network_received_bytes"
    case networkSentBytes = "network_sent_bytes"
    case startTime = "start_time"
    case path
}

public struct ProcessQuery: Sendable, Codable, Equatable {
    public var search: String?
    public var filter: ProcessFilter
    public var sort: ProcessSort
    public var order: SortOrder
    public var limit: Int
    public var cursor: String?
    public var fields: [ProcessField]?

    public init(search: String? = nil, filter: ProcessFilter = .mine, sort: ProcessSort = .cpu,
                order: SortOrder = .desc, limit: Int = 50, cursor: String? = nil, fields: [ProcessField]? = nil) throws
    {
        self.search = search
        self.filter = filter
        self.sort = sort
        self.order = order
        self.limit = limit
        self.cursor = cursor
        self.fields = fields
        try validate()
    }

    public func validate() throws {
        guard (1 ... 200).contains(limit) else { throw AgentError.invalidArgument("limit must be in 1...200") }
    }

    enum CodingKeys: String, CodingKey { case search, filter, sort, order, limit, cursor, fields }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(search: container.decodeIfPresent(String.self, forKey: .search),
                      filter: container.decodeIfPresent(ProcessFilter.self, forKey: .filter) ?? .mine,
                      sort: container.decodeIfPresent(ProcessSort.self, forKey: .sort) ?? .cpu,
                      order: container.decodeIfPresent(SortOrder.self, forKey: .order) ?? .desc,
                      limit: container.decodeIfPresent(Int.self, forKey: .limit) ?? 50,
                      cursor: container.decodeIfPresent(String.self, forKey: .cursor),
                      fields: container.decodeIfPresent([ProcessField].self, forKey: .fields))
    }
}

public struct ProcessPage: Sendable, Codable, Equatable {
    public var snapshot: SnapshotHeader
    public var items: [ProcessSample]
    public var nextCursor: String?
    public var totalMatched: Int

    public init(snapshot: SnapshotHeader, items: [ProcessSample], nextCursor: String? = nil, totalMatched: Int) {
        self.snapshot = snapshot
        self.items = items
        self.nextCursor = nextCursor
        self.totalMatched = totalMatched
    }
}
