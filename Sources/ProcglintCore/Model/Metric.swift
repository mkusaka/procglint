import Foundation

public enum MetricStatus: String, Sendable, Codable, CaseIterable {
    case ok
    case warmingUp = "warming_up"
    case permissionDenied = "permission_denied"
    case exited, stale, unsupported
}

public struct Metric: Sendable, Codable, Equatable {
    public let value: Double?
    public let status: MetricStatus

    public init(value: Double?, status: MetricStatus) throws {
        guard (value != nil) == (status == .ok) else {
            throw AgentError.invalidArgument("Metric value must be non-null if and only if status is ok")
        }
        self.value = value
        self.status = status
    }

    private init(_ value: Double?, _ status: MetricStatus) {
        self.value = value
        self.status = status
    }

    public static func ok(_ value: Double) -> Metric {
        Metric(value, .ok)
    }

    public static let warmingUp = Metric(nil, .warmingUp)
    public static let permissionDenied = Metric(nil, .permissionDenied)
    public static let exited = Metric(nil, .exited)
    public static let stale = Metric(nil, .stale)
    public static let unsupported = Metric(nil, .unsupported)

    enum CodingKeys: String, CodingKey { case value, status }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            value: container.decodeIfPresent(Double.self, forKey: .value),
            status: container.decode(MetricStatus.self, forKey: .status)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(value, forKey: .value)
        try container.encode(status, forKey: .status)
    }
}
