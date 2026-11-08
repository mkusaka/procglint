import Foundation

public struct HistoryPoint: Sendable, Codable, Equatable {
    public var t: Date
    public var cpuPercent: Metric
    public var footprintBytes: Metric?
    public var diskReadBps: Metric?
    public var diskWriteBps: Metric?
    public var memoryUsedBytes: Metric?

    public init(t: Date, cpuPercent: Metric, footprintBytes: Metric? = nil, diskReadBps: Metric? = nil,
                diskWriteBps: Metric? = nil, memoryUsedBytes: Metric? = nil)
    {
        self.t = t
        self.cpuPercent = cpuPercent
        self.footprintBytes = footprintBytes
        self.diskReadBps = diskReadBps
        self.diskWriteBps = diskWriteBps
        self.memoryUsedBytes = memoryUsedBytes
    }
}

public struct HistoryGap: Sendable, Codable, Equatable {
    public var from: Date
    public var to: Date

    public init(from: Date, to: Date) {
        self.from = from
        self.to = to
    }
}

public struct HistorySeries: Sendable, Codable, Equatable {
    public var series: String
    public var points: [HistoryPoint]
    public var gaps: [HistoryGap]

    public init(series: String, points: [HistoryPoint], gaps: [HistoryGap] = []) {
        self.series = series
        self.points = points
        self.gaps = gaps
    }
}

public struct HistoryRequest: Sendable, Codable, Equatable {
    // Each selector is "system", a process_key, or an observation_id.
    public var series: [String]
    public var since: Date?

    public init(series: [String], since: Date? = nil) {
        self.series = series
        self.since = since
    }
}
