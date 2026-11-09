import Foundation

public struct HistoryPoint: Sendable, Codable, Equatable {
    public var t: Date
    public var cpuPercent: Metric
    public var footprintBytes: Metric?
    public var diskReadBps: Metric?
    public var diskWriteBps: Metric?
    public var memoryUsedBytes: Metric?
    public var memoryPressurePercent: Metric?
    public var memoryPressure: MemoryPressure?

    public init(t: Date, cpuPercent: Metric, footprintBytes: Metric? = nil, diskReadBps: Metric? = nil,
                diskWriteBps: Metric? = nil, memoryUsedBytes: Metric? = nil,
                memoryPressurePercent: Metric? = nil, memoryPressure: MemoryPressure? = nil)
    {
        self.t = t
        self.cpuPercent = cpuPercent
        self.footprintBytes = footprintBytes
        self.diskReadBps = diskReadBps
        self.diskWriteBps = diskWriteBps
        self.memoryUsedBytes = memoryUsedBytes
        self.memoryPressurePercent = memoryPressurePercent
        self.memoryPressure = memoryPressure
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
    public var nextCursor: String?
    public var isDelta: Bool
    public var retainedPointCount: Int?

    public init(series: String, points: [HistoryPoint], gaps: [HistoryGap] = [],
                nextCursor: String? = nil, isDelta: Bool = false, retainedPointCount: Int? = nil)
    {
        self.series = series
        self.points = points
        self.gaps = gaps
        self.nextCursor = nextCursor
        self.isDelta = isDelta
        self.retainedPointCount = retainedPointCount
    }

    enum CodingKeys: String, CodingKey { case series, points, gaps, nextCursor, isDelta, retainedPointCount }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(series: values.decode(String.self, forKey: .series),
                      points: values.decode([HistoryPoint].self, forKey: .points),
                      gaps: values.decode([HistoryGap].self, forKey: .gaps),
                      nextCursor: values.decodeIfPresent(String.self, forKey: .nextCursor),
                      isDelta: values.decodeIfPresent(Bool.self, forKey: .isDelta) ?? false,
                      retainedPointCount: values.decodeIfPresent(Int.self, forKey: .retainedPointCount))
        if isDelta, nextCursor == nil || retainedPointCount == nil {
            throw DecodingError.dataCorruptedError(forKey: .isDelta, in: values, debugDescription: "A history delta requires a cursor and retention count")
        }
        if let retainedPointCount, !(0 ... 600).contains(retainedPointCount) {
            throw DecodingError.dataCorruptedError(forKey: .retainedPointCount, in: values, debugDescription: "History retention count must be 0...600")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        guard !isDelta || (nextCursor != nil && retainedPointCount != nil),
              retainedPointCount.map({ (0 ... 600).contains($0) }) ?? true
        else {
            throw EncodingError.invalidValue(self, .init(codingPath: encoder.codingPath, debugDescription: "Invalid history delta metadata"))
        }
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(series, forKey: .series)
        try values.encode(points, forKey: .points)
        try values.encode(gaps, forKey: .gaps)
        if let nextCursor {
            try values.encode(nextCursor, forKey: .nextCursor)
            try values.encode(isDelta, forKey: .isDelta)
            try values.encodeIfPresent(retainedPointCount, forKey: .retainedPointCount)
        }
    }
}

public struct HistoryRequest: Sendable, Codable, Equatable {
    // Each selector is "system", a process_key, or an observation_id.
    public var series: [String]
    public var since: Date?
    public var cursor: String?

    public init(series: [String], since: Date? = nil, cursor: String? = nil) {
        self.series = series
        self.since = since
        self.cursor = cursor
    }
}
