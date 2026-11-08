import Foundation

public struct MonitorStatus: Sendable, Codable, Equatable {
    public struct LeaseSummary: Sendable, Codable, Equatable {
        public var kind: LeaseKind
        public var intervalMS: SamplingInterval
        public var remainingMS: Int

        public init(kind: LeaseKind, intervalMS: SamplingInterval, remainingMS: Int) {
            self.kind = kind
            self.intervalMS = intervalMS
            self.remainingMS = remainingMS
        }

        // Wire keys belong beside the nested summary.
        // swiftlint:disable:next nesting
        enum CodingKeys: String, CodingKey {
            case kind
            case intervalMS = "intervalMs"
            case remainingMS = "remainingMs"
        }
    }

    public struct ClientSummary: Sendable, Codable, Equatable {
        public var clientID: String
        public var kind: ClientKind
        public var pid: Int32
        public var footprintBytes: UInt64
        public var cpuPercent: Metric

        public init(clientID: String, kind: ClientKind, pid: Int32, footprintBytes: UInt64, cpuPercent: Metric) {
            self.clientID = clientID
            self.kind = kind
            self.pid = pid
            self.footprintBytes = footprintBytes
            self.cpuPercent = cpuPercent
        }

        // Wire keys belong beside the nested summary.
        // swiftlint:disable:next nesting
        enum CodingKeys: String, CodingKey {
            case clientID = "clientId"
            case kind, pid, footprintBytes, cpuPercent
        }
    }

    public var agentInstanceID: String
    public var agentPID: Int32
    public var agentCPUPercent: Metric
    public var agentFootprintBytes: UInt64
    public var samplingActive: Bool
    public var effectiveIntervalMS: SamplingInterval?
    @JSONString public var collectionsTotal: UInt64
    public var lastCollectionMS: Double
    public var collectionP95MS: Double
    public var lastCoverage: Coverage
    @JSONStringCounts public var failures: [String: UInt64]
    public var leases: [LeaseSummary]
    public var clients: [ClientSummary]
    public var historyBytes: UInt64
    public var policy: SamplingPolicy

    public init(agentInstanceID: String, agentPID: Int32, agentCPUPercent: Metric, agentFootprintBytes: UInt64,
                samplingActive: Bool, effectiveIntervalMS: SamplingInterval?, collectionsTotal: UInt64,
                lastCollectionMS: Double, collectionP95MS: Double, lastCoverage: Coverage,
                failures: [String: UInt64], leases: [LeaseSummary], clients: [ClientSummary], historyBytes: UInt64,
                policy: SamplingPolicy)
    {
        self.agentInstanceID = agentInstanceID
        self.agentPID = agentPID
        self.agentCPUPercent = agentCPUPercent
        self.agentFootprintBytes = agentFootprintBytes
        self.samplingActive = samplingActive
        self.effectiveIntervalMS = effectiveIntervalMS
        self.collectionsTotal = collectionsTotal
        self.lastCollectionMS = lastCollectionMS
        self.collectionP95MS = collectionP95MS
        self.lastCoverage = lastCoverage
        self.failures = failures
        self.leases = leases
        self.clients = clients
        self.historyBytes = historyBytes
        self.policy = policy
    }

    enum CodingKeys: String, CodingKey {
        case agentInstanceID = "agentInstanceId"
        case agentPID = "agentPid"
        case agentCPUPercent = "agentCpuPercent"
        case agentFootprintBytes, samplingActive
        case effectiveIntervalMS = "effectiveIntervalMs"
        case collectionsTotal
        case lastCollectionMS = "lastCollectionMs"
        case collectionP95MS = "collectionP95Ms"
        case lastCoverage, failures, leases, clients, historyBytes, policy
    }
}
