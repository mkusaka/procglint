import Foundation
import IOKit

public struct BatteryMetrics: Sendable, Codable, Equatable {
    public var percent: Metric
    public var isCharging: Bool?
    public var externalPower: Bool?
    public var timeRemainingMinutes: Metric
    public var cycleCount: Metric
    public var healthPercent: Metric
    public var designCapacityMAH: Metric
    public var fullChargeCapacityMAH: Metric
    public var systemPowerMW: Metric
    public var adapterPowerMW: Metric
    public var batteryPowerMW: Metric

    public init(percent: Metric = .unsupported, isCharging: Bool? = nil, externalPower: Bool? = nil,
                timeRemainingMinutes: Metric = .unsupported, cycleCount: Metric = .unsupported,
                healthPercent: Metric = .unsupported, designCapacityMAH: Metric = .unsupported,
                fullChargeCapacityMAH: Metric = .unsupported, systemPowerMW: Metric = .unsupported,
                adapterPowerMW: Metric = .unsupported, batteryPowerMW: Metric = .unsupported)
    {
        self.percent = percent
        self.isCharging = isCharging
        self.externalPower = externalPower
        self.timeRemainingMinutes = timeRemainingMinutes
        self.cycleCount = cycleCount
        self.healthPercent = healthPercent
        self.designCapacityMAH = designCapacityMAH
        self.fullChargeCapacityMAH = fullChargeCapacityMAH
        self.systemPowerMW = systemPowerMW
        self.adapterPowerMW = adapterPowerMW
        self.batteryPowerMW = batteryPowerMW
    }

    enum CodingKeys: String, CodingKey {
        case percent, isCharging, externalPower, timeRemainingMinutes, cycleCount, healthPercent
        case designCapacityMAH = "designCapacityMah"
        case fullChargeCapacityMAH = "fullChargeCapacityMah"
        case systemPowerMW = "systemPowerMw"
        case adapterPowerMW = "adapterPowerMw"
        case batteryPowerMW = "batteryPowerMw"
    }
}

/// Nil means no battery service; missing properties never become measured zeroes.
func parseBattery(_ properties: [String: Any]?) -> BatteryMetrics? {
    guard let properties, properties["BatteryInstalled"] as? Bool != false else { return nil }
    func number(_ dictionary: [String: Any], _ key: String) -> Double? {
        guard let value = dictionary[key] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
              value.doubleValue.isFinite else { return nil }
        return value.doubleValue
    }
    func nonnegative(_ dictionary: [String: Any], _ key: String, maximum: Double = .greatestFiniteMagnitude) -> Metric {
        guard let value = number(dictionary, key), (0 ... maximum).contains(value) else { return .unsupported }
        return .ok(value)
    }
    let data = properties["BatteryData"] as? [String: Any] ?? [:]
    let telemetry = properties["PowerTelemetryData"] as? [String: Any] ?? [:]
    let design = nonnegative(data, "DesignCapacity")
    let full = nonnegative(data, "FullChargeCapacity").value ?? nonnegative(data, "AppleRawMaxCapacity").value
        ?? nonnegative(properties, "AppleRawMaxCapacity").value
    let health: Metric = if let design = design.value, design > 0, let full, (full / design * 100).isFinite {
        .ok(full / design * 100)
    } else {
        .unsupported
    }
    let charging = properties["IsCharging"] as? Bool
    let external = properties["ExternalConnected"] as? Bool
    var batteryPower = number(telemetry, "BatteryPower")
    // Some registries expose an unsigned magnitude; mA × mV / 1000 retains the current's sign.
    if batteryPower.map({ $0 >= 0 }) ?? true {
        if let current = properties["InstantAmperage"] as? NSNumber, current.doubleValue.isFinite,
           CFGetTypeID(current) != CFBooleanGetTypeID(), let voltage = number(properties, "Voltage"), voltage > 0,
           (Double(current.int64Value) * voltage / 1000).isFinite
        {
            batteryPower = Double(current.int64Value) * voltage / 1000
        } else if let power = batteryPower, power > 0, charging == false, external == false {
            batteryPower = -power
        } else if charging != true, batteryPower != 0 {
            batteryPower = nil
        }
    }
    return BatteryMetrics(
        percent: nonnegative(properties, "CurrentCapacity", maximum: 100), isCharging: charging, externalPower: external,
        timeRemainingMinutes: nonnegative(properties, "TimeRemaining", maximum: 65534),
        cycleCount: nonnegative(properties, "CycleCount"), healthPercent: health,
        designCapacityMAH: design, fullChargeCapacityMAH: full.map(Metric.ok) ?? .unsupported,
        systemPowerMW: nonnegative(telemetry, "SystemLoad"), adapterPowerMW: nonnegative(telemetry, "SystemPowerIn"),
        batteryPowerMW: batteryPower.map(Metric.ok) ?? .unsupported
    )
}

func readBatteryProperties() -> [String: Any]? {
    let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
    guard service != IO_OBJECT_NULL else { return nil }
    defer { IOObjectRelease(service) }
    var properties: Unmanaged<CFMutableDictionary>?
    guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS else { return nil }
    return properties?.takeRetainedValue() as? [String: Any]
}

struct BatteryCache {
    private var sampledAt: UInt64?
    private var value: BatteryMetrics?

    mutating func read(now: UInt64, properties: () -> [String: Any]?) -> BatteryMetrics? {
        if let sampledAt, now >= sampledAt, now - sampledAt < 10_000_000_000 {
            return value
        }
        var fresh = parseBattery(properties())
        if let cached = value, fresh != nil {
            // Capacity/health/cycles are static for the lifetime of this source, not per-sweep work.
            if cached.designCapacityMAH.status == .ok {
                fresh?.designCapacityMAH = cached.designCapacityMAH
            }
            if cached.fullChargeCapacityMAH.status == .ok {
                fresh?.fullChargeCapacityMAH = cached.fullChargeCapacityMAH
            }
            if cached.healthPercent.status == .ok {
                fresh?.healthPercent = cached.healthPercent
            }
            if cached.cycleCount.status == .ok {
                fresh?.cycleCount = cached.cycleCount
            }
        }
        sampledAt = now
        value = fresh
        return value
    }
}
