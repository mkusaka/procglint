import Foundation

public enum SamplingInterval: Int, Sendable, Codable, CaseIterable {
    case oneSecond = 1000
    case twoSeconds = 2000
    case fiveSeconds = 5000
    case tenSeconds = 10000

    public var milliseconds: Int {
        rawValue
    }

    public var nanoseconds: UInt64 {
        UInt64(rawValue) * 1_000_000
    }
}

public enum LeaseKind: String, Sendable, Codable, CaseIterable {
    case guiWindow = "gui_window"
    case menuBar = "menu_bar"
    case observation
}

public struct SamplingLease: Sendable, Codable, Equatable {
    public var leaseID: String
    public var clientID: String
    public var kind: LeaseKind
    public var intervalMS: SamplingInterval
    @JSONString public var expiresAt: UInt64

    public init(leaseID: String, clientID: String, kind: LeaseKind, intervalMS: SamplingInterval, expiresAt: UInt64) {
        self.leaseID = leaseID
        self.clientID = clientID
        self.kind = kind
        self.intervalMS = intervalMS
        self.expiresAt = expiresAt
    }

    enum CodingKeys: String, CodingKey {
        case leaseID = "leaseId"
        case clientID = "clientId"
        case kind
        case intervalMS = "intervalMs"
        case expiresAt
    }
}

public struct LeaseRequest: Sendable, Codable, Equatable {
    public var kind: LeaseKind
    public var intervalMS: SamplingInterval
    public var processKeys: [ProcessKey]

    public init(kind: LeaseKind, intervalMS: SamplingInterval, processKeys: [ProcessKey] = []) throws {
        self.kind = kind
        self.intervalMS = intervalMS
        self.processKeys = processKeys
        try validate()
    }

    public func validate() throws {
        guard kind != .observation else { throw AgentError.invalidArgument("Use startObservation for observation leases") }
        guard processKeys.count <= 16, processKeys.isEmpty || kind == .guiWindow else {
            throw AgentError.invalidArgument("Only gui_window leases accept process_keys, at most 16")
        }
    }

    enum CodingKeys: String, CodingKey {
        case kind
        case intervalMS = "intervalMs"
        case processKeys
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(kind: container.decode(LeaseKind.self, forKey: .kind),
                      intervalMS: container.decode(SamplingInterval.self, forKey: .intervalMS),
                      processKeys: container.decodeIfPresent([ProcessKey].self, forKey: .processKeys) ?? [])
    }
}

public struct SamplingPolicy: Sendable, Codable, Equatable {
    public var revision: Int
    public var guiIntervalMS: SamplingInterval
    public var menuBarIntervalMS: SamplingInterval
    public var historyMinutes: Int
    public var maxProcessSeries: Int

    public init(revision: Int = 0, guiIntervalMS: SamplingInterval = .fiveSeconds,
                menuBarIntervalMS: SamplingInterval = .tenSeconds, historyMinutes: Int = 10,
                maxProcessSeries: Int = 16) throws
    {
        self.revision = revision
        self.guiIntervalMS = guiIntervalMS
        self.menuBarIntervalMS = menuBarIntervalMS
        self.historyMinutes = historyMinutes
        self.maxProcessSeries = maxProcessSeries
        try validate()
    }

    public func validate() throws {
        guard revision >= 0, (1 ... 10).contains(historyMinutes), (1 ... 16).contains(maxProcessSeries) else {
            throw AgentError.invalidArgument("Policy requires revision >= 0, history_minutes in 1...10, max_process_series in 1...16")
        }
    }

    enum CodingKeys: String, CodingKey {
        case revision
        case guiIntervalMS = "guiIntervalMs"
        case menuBarIntervalMS = "menuBarIntervalMs"
        case historyMinutes, maxProcessSeries
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(revision: container.decode(Int.self, forKey: .revision),
                      guiIntervalMS: container.decode(SamplingInterval.self, forKey: .guiIntervalMS),
                      menuBarIntervalMS: container.decode(SamplingInterval.self, forKey: .menuBarIntervalMS),
                      historyMinutes: container.decode(Int.self, forKey: .historyMinutes),
                      maxProcessSeries: container.decode(Int.self, forKey: .maxProcessSeries))
    }
}

public struct ObservationRequest: Sendable, Codable, Equatable {
    public var intervalMS: SamplingInterval
    public var durationMS: Int
    public var processKeys: [ProcessKey]

    public init(intervalMS: SamplingInterval, durationMS: Int, processKeys: [ProcessKey] = []) throws {
        self.intervalMS = intervalMS
        self.durationMS = durationMS
        self.processKeys = processKeys
        try validate()
    }

    public func validate() throws {
        guard (1000 ... 60000).contains(durationMS), processKeys.count <= 16 else {
            throw AgentError.invalidArgument("Observation requires duration_ms in 1000...60000 and at most 16 process_keys")
        }
    }

    enum CodingKeys: String, CodingKey {
        case intervalMS = "intervalMs"
        case durationMS = "durationMs"
        case processKeys
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(intervalMS: container.decode(SamplingInterval.self, forKey: .intervalMS),
                      durationMS: container.decode(Int.self, forKey: .durationMS),
                      processKeys: container.decodeIfPresent([ProcessKey].self, forKey: .processKeys) ?? [])
    }
}

public enum ObservationState: String, Sendable, Codable, CaseIterable { case active, expired, stopped }

public struct Observation: Sendable, Codable, Equatable {
    public var observationID: String
    public var intervalMS: SamplingInterval
    public var startedAt: Date
    public var expiresAt: Date
    public var processKeys: [ProcessKey]
    public var state: ObservationState

    public init(observationID: String, intervalMS: SamplingInterval, startedAt: Date, expiresAt: Date,
                processKeys: [ProcessKey], state: ObservationState)
    {
        self.observationID = observationID
        self.intervalMS = intervalMS
        self.startedAt = startedAt
        self.expiresAt = expiresAt
        self.processKeys = processKeys
        self.state = state
    }

    enum CodingKeys: String, CodingKey {
        case observationID = "observationId"
        case intervalMS = "intervalMs"
        case startedAt, expiresAt, processKeys, state
    }
}
