import Foundation

public enum SnapshotStatus: String, Sendable, Codable, CaseIterable {
    case ok
    case warmingUp = "warming_up"
    case stale, unavailable
}

public enum ProcessStatus: String, Sendable, Codable, CaseIterable {
    case ok
    case permissionDenied = "permission_denied"
    case exited
}

public struct Coverage: Sendable, Codable, Equatable {
    public var enumerated: Int
    public var sampled: Int
    public var permissionDenied: Int
    public var exitedDuringSample: Int

    public init(enumerated: Int = 0, sampled: Int = 0, permissionDenied: Int = 0, exitedDuringSample: Int = 0) {
        self.enumerated = enumerated
        self.sampled = sampled
        self.permissionDenied = permissionDenied
        self.exitedDuringSample = exitedDuringSample
    }
}

public struct SystemMetrics: Sendable, Codable, Equatable {
    public var cpuPercent: Metric
    public var physicalMemoryBytes: UInt64
    public var pageSize: UInt64
    public var memoryUsedBytes: UInt64
    public var wiredBytes: UInt64
    public var compressedBytes: UInt64
    public var activeBytes: UInt64
    public var inactiveBytes: UInt64
    public var freeBytes: UInt64
    public var memoryPressure: MemoryPressureMetric
    public var memoryPressurePercent: Metric
    public var swapUsedBytes: Metric
    public var swapTotalBytes: Metric

    public init(cpuPercent: Metric, physicalMemoryBytes: UInt64, pageSize: UInt64, memoryUsedBytes: UInt64,
                wiredBytes: UInt64, compressedBytes: UInt64, activeBytes: UInt64, inactiveBytes: UInt64, freeBytes: UInt64,
                memoryPressure: MemoryPressureMetric = .unsupported, memoryPressurePercent: Metric = .unsupported,
                swapUsedBytes: Metric = .unsupported,
                swapTotalBytes: Metric = .unsupported)
    {
        self.cpuPercent = cpuPercent
        self.physicalMemoryBytes = physicalMemoryBytes
        self.pageSize = pageSize
        self.memoryUsedBytes = memoryUsedBytes
        self.wiredBytes = wiredBytes
        self.compressedBytes = compressedBytes
        self.activeBytes = activeBytes
        self.inactiveBytes = inactiveBytes
        self.freeBytes = freeBytes
        self.memoryPressure = memoryPressure
        self.memoryPressurePercent = memoryPressurePercent
        self.swapUsedBytes = swapUsedBytes
        self.swapTotalBytes = swapTotalBytes
    }

    /// A 1.0.0 agent can outlive an upgrade by its idle grace period; its snapshots lack the memory-pressure fields.
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            cpuPercent: values.decode(Metric.self, forKey: .cpuPercent),
            physicalMemoryBytes: values.decode(UInt64.self, forKey: .physicalMemoryBytes),
            pageSize: values.decode(UInt64.self, forKey: .pageSize),
            memoryUsedBytes: values.decode(UInt64.self, forKey: .memoryUsedBytes),
            wiredBytes: values.decode(UInt64.self, forKey: .wiredBytes),
            compressedBytes: values.decode(UInt64.self, forKey: .compressedBytes),
            activeBytes: values.decode(UInt64.self, forKey: .activeBytes),
            inactiveBytes: values.decode(UInt64.self, forKey: .inactiveBytes),
            freeBytes: values.decode(UInt64.self, forKey: .freeBytes),
            memoryPressure: values.decodeIfPresent(MemoryPressureMetric.self, forKey: .memoryPressure) ?? .unsupported,
            memoryPressurePercent: values.decodeIfPresent(Metric.self, forKey: .memoryPressurePercent) ?? .unsupported,
            swapUsedBytes: values.decodeIfPresent(Metric.self, forKey: .swapUsedBytes) ?? .unsupported,
            swapTotalBytes: values.decodeIfPresent(Metric.self, forKey: .swapTotalBytes) ?? .unsupported
        )
    }
}

public struct ProcessSample: Sendable, Codable, Equatable {
    public var processKey: ProcessKey
    public var pid: Int32
    public var ppid: Int32?
    public var name: String
    public var uid: UInt32
    public var user: String
    public var isOwn: Bool
    public var status: ProcessStatus
    public var cpuPercent: Metric
    @OptionalJSONString public var cpuTimeNS: UInt64?
    public var footprintBytes: Metric
    public var rssBytes: Metric
    public var diskReadBytes: Metric
    public var diskWrittenBytes: Metric
    public var diskReadBps: Metric
    public var diskWriteBps: Metric
    public var startTime: Date
    public var path: String?

    public init(processKey: ProcessKey, pid: Int32, ppid: Int32? = nil, name: String, uid: UInt32, user: String,
                isOwn: Bool, status: ProcessStatus, cpuPercent: Metric, cpuTimeNS: UInt64?, footprintBytes: Metric,
                rssBytes: Metric, diskReadBytes: Metric, diskWrittenBytes: Metric, diskReadBps: Metric,
                diskWriteBps: Metric, startTime: Date, path: String? = nil)
    {
        self.processKey = processKey
        self.pid = pid
        self.ppid = ppid
        self.name = name
        self.uid = uid
        self.user = user
        self.isOwn = isOwn
        self.status = status
        self.cpuPercent = cpuPercent
        self.cpuTimeNS = cpuTimeNS
        self.footprintBytes = footprintBytes
        self.rssBytes = rssBytes
        self.diskReadBytes = diskReadBytes
        self.diskWrittenBytes = diskWrittenBytes
        self.diskReadBps = diskReadBps
        self.diskWriteBps = diskWriteBps
        self.startTime = startTime
        self.path = path
    }

    enum CodingKeys: String, CodingKey {
        case processKey, pid, ppid, name, uid, user, isOwn, status, cpuPercent
        case cpuTimeNS = "cpuTimeNs"
        case footprintBytes, rssBytes, diskReadBytes, diskWrittenBytes, diskReadBps, diskWriteBps, startTime, path
    }
}

public struct SnapshotHeader: Sendable, Codable, Equatable {
    public var agentInstanceID: String
    public var snapshotID: String
    public var sampledAt: Date
    public var intervalMS: Int?
    public var ageMS: Int
    public var status: SnapshotStatus
    public var coverage: Coverage
    public var system: SystemMetrics

    public init(agentInstanceID: String, snapshotID: String, sampledAt: Date, intervalMS: Int?, ageMS: Int,
                status: SnapshotStatus, coverage: Coverage, system: SystemMetrics)
    {
        self.agentInstanceID = agentInstanceID
        self.snapshotID = snapshotID
        self.sampledAt = sampledAt
        self.intervalMS = intervalMS
        self.ageMS = ageMS
        self.status = status
        self.coverage = coverage
        self.system = system
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(agentInstanceID, forKey: .agentInstanceID)
        try container.encode(snapshotID, forKey: .snapshotID)
        try container.encode(sampledAt, forKey: .sampledAt)
        try container.encode(intervalMS, forKey: .intervalMS)
        try container.encode(ageMS, forKey: .ageMS)
        try container.encode(status, forKey: .status)
        try container.encode(coverage, forKey: .coverage)
        try container.encode(system, forKey: .system)
    }

    public init(_ snapshot: Snapshot) {
        self.init(agentInstanceID: snapshot.agentInstanceID, snapshotID: snapshot.snapshotID, sampledAt: snapshot.sampledAt,
                  intervalMS: snapshot.intervalMS, ageMS: snapshot.ageMS, status: snapshot.status,
                  coverage: snapshot.coverage, system: snapshot.system)
    }

    enum CodingKeys: String, CodingKey {
        case agentInstanceID = "agentInstanceId"
        case snapshotID = "snapshotId"
        case sampledAt
        case intervalMS = "intervalMs"
        case ageMS = "ageMs"
        case status, coverage, system
    }
}

public struct Snapshot: Sendable, Codable, Equatable {
    public var agentInstanceID: String
    public var snapshotID: String
    public var sampledAt: Date
    public var intervalMS: Int?
    public var ageMS: Int
    public var status: SnapshotStatus
    public var coverage: Coverage
    public var system: SystemMetrics
    public var processes: [ProcessSample]
    public var header: SnapshotHeader {
        SnapshotHeader(self)
    }

    public init(agentInstanceID: String, snapshotID: String, sampledAt: Date, intervalMS: Int?, ageMS: Int,
                status: SnapshotStatus, coverage: Coverage, system: SystemMetrics, processes: [ProcessSample])
    {
        self.agentInstanceID = agentInstanceID
        self.snapshotID = snapshotID
        self.sampledAt = sampledAt
        self.intervalMS = intervalMS
        self.ageMS = ageMS
        self.status = status
        self.coverage = coverage
        self.system = system
        self.processes = processes
    }

    public func encode(to encoder: any Encoder) throws {
        try header.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(processes, forKey: .processes)
    }

    public init(header: SnapshotHeader, processes: [ProcessSample]) {
        self.init(agentInstanceID: header.agentInstanceID, snapshotID: header.snapshotID, sampledAt: header.sampledAt,
                  intervalMS: header.intervalMS, ageMS: header.ageMS, status: header.status,
                  coverage: header.coverage, system: header.system, processes: processes)
    }

    enum CodingKeys: String, CodingKey {
        case agentInstanceID = "agentInstanceId"
        case snapshotID = "snapshotId"
        case sampledAt
        case intervalMS = "intervalMs"
        case ageMS = "ageMs"
        case status, coverage, system, processes
    }
}
