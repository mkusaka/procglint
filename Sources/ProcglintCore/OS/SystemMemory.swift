import Foundation

public enum MemoryPressure: String, Sendable, Codable, CaseIterable {
    case normal, warning, critical
}

/// Pressure is categorical; Metric's numeric value cannot represent it without losing the wire label.
public struct MemoryPressureMetric: Sendable, Codable, Equatable {
    public let value: MemoryPressure?
    public let status: MetricStatus

    public init(value: MemoryPressure?, status: MetricStatus) throws {
        guard (value != nil) == (status == .ok) else {
            throw AgentError.invalidArgument("Pressure value must be non-null if and only if status is ok")
        }
        self.value = value
        self.status = status
    }

    public static func ok(_ value: MemoryPressure) -> Self {
        Self(value: value)
    }

    public static let unsupported = Self(value: nil)

    private init(value: MemoryPressure?) {
        self.value = value
        status = value == nil ? .unsupported : .ok
    }

    enum CodingKeys: String, CodingKey { case value, status }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(value: container.decodeIfPresent(MemoryPressure.self, forKey: .value),
                      status: container.decode(MetricStatus.self, forKey: .status))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(value, forKey: .value)
        try container.encode(status, forKey: .status)
    }
}

struct SystemMemorySample: Sendable {
    var pressure: MemoryPressureMetric = .unsupported
    var pressurePercent: Metric = .unsupported
    var swapUsed: Metric = .unsupported
    var swapTotal: Metric = .unsupported
}
