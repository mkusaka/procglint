import Foundation
@testable import ProcglintCore
import Synchronization
import Testing

struct BatteryTests {
    private func properties(charging: Bool = true) -> [String: Any] {
        ["CurrentCapacity": 69, "IsCharging": charging, "ExternalConnected": charging,
         "TimeRemaining": 113, "CycleCount": 5, "Voltage": 12000, "InstantAmperage": charging ? 1500 : -1500,
         "BatteryData": ["DesignCapacity": 5000, "FullChargeCapacity": 5000],
         "PowerTelemetryData": ["SystemLoad": 33100, "SystemPowerIn": charging ? 60000 : 0, "BatteryPower": 17000]]
    }

    @Test(arguments: [true, false]) func chargingAndDischarging(charging: Bool) throws {
        let battery = try #require(parseBattery(properties(charging: charging)))
        #expect(battery.percent == .ok(69))
        #expect(battery.isCharging == charging)
        #expect(battery.externalPower == charging)
        #expect(battery.timeRemainingMinutes == .ok(113))
        #expect(battery.cycleCount == .ok(5))
        #expect(battery.healthPercent == .ok(100))
        #expect(battery.designCapacityMAH == .ok(5000))
        #expect(battery.fullChargeCapacityMAH == .ok(5000))
        #expect(battery.systemPowerMW == .ok(33100))
        #expect(battery.adapterPowerMW == .ok(charging ? 60000 : 0))
        #expect(battery.batteryPowerMW == .ok(charging ? 18000 : -18000))
    }

    @Test func absentBatteryAndMissingKeys() throws {
        #expect(parseBattery(nil) == nil)
        #expect(parseBattery(["BatteryInstalled": false]) == nil)
        let battery = try #require(parseBattery([:]))
        #expect(battery.percent == .unsupported)
        #expect(battery.isCharging == nil)
        #expect(battery.externalPower == nil)
        #expect(battery.timeRemainingMinutes == .unsupported)
        #expect(battery.cycleCount == .unsupported)
        #expect(battery.healthPercent == .unsupported)
        #expect(battery.systemPowerMW == .unsupported)
        #expect(battery.adapterPowerMW == .unsupported)
        #expect(battery.batteryPowerMW == .unsupported)
    }

    @Test(arguments: [65535, -1, 65536]) func unknownTime(minutes: Int) {
        var dictionary = properties()
        dictionary["TimeRemaining"] = minutes
        #expect(parseBattery(dictionary)?.timeRemainingMinutes == .unsupported)
    }

    @Test func malformedValuesAndRawCapacityFallback() {
        var dictionary = properties()
        dictionary["BatteryData"] = ["DesignCapacity": 5000, "AppleRawMaxCapacity": 4500]
        #expect(parseBattery(dictionary)?.healthPercent == .ok(90))
        dictionary["BatteryData"] = ["DesignCapacity": 0, "FullChargeCapacity": 5000]
        dictionary["CurrentCapacity"] = 101
        dictionary["CycleCount"] = -1
        #expect(parseBattery(dictionary)?.healthPercent == .unsupported)
        #expect(parseBattery(dictionary)?.percent == .unsupported)
        #expect(parseBattery(dictionary)?.cycleCount == .unsupported)
        dictionary["CurrentCapacity"] = true
        dictionary["TimeRemaining"] = "113"
        #expect(parseBattery(dictionary)?.percent == .unsupported)
        #expect(parseBattery(dictionary)?.timeRemainingMinutes == .unsupported)
    }

    @Test func signedTelemetryAndUnsignedRegistryCurrent() {
        var dictionary = properties(charging: false)
        dictionary["PowerTelemetryData"] = ["BatteryPower": -17000]
        #expect(parseBattery(dictionary)?.batteryPowerMW == .ok(-17000))
        dictionary["PowerTelemetryData"] = [:]
        dictionary["InstantAmperage"] = NSNumber(value: UInt64(bitPattern: -1500))
        #expect(parseBattery(dictionary)?.batteryPowerMW == .ok(-18000))
        dictionary.removeValue(forKey: "InstantAmperage")
        dictionary["PowerTelemetryData"] = ["BatteryPower": 17000]
        #expect(parseBattery(dictionary)?.batteryPowerMW == .ok(-17000))
        dictionary.removeValue(forKey: "ExternalConnected")
        #expect(parseBattery(dictionary)?.batteryPowerMW == .unsupported)
    }

    @Test func cacheReadsAtMostOncePerTenSecondsAndKeepsStaticFields() throws {
        let clock = FakeClock()
        let reads = Mutex(0)
        let source = try DarwinProcessSource(readBattery: {
            let count = reads.withLock { $0 += 1; return $0 }
            return ["CurrentCapacity": count, "CycleCount": count,
                    "BatteryData": ["DesignCapacity": 5000, "FullChargeCapacity": 5000 - count]]
        }, clock: clock)
        let first = try #require(source.systemBattery())
        clock.advance(by: 9_999_999_999)
        #expect(source.systemBattery() == first)
        #expect(reads.withLock { $0 } == 1)
        clock.advance(by: 1)
        let second = try #require(source.systemBattery())
        #expect(reads.withLock { $0 } == 2)
        #expect(second.percent == .ok(2))
        #expect(second.cycleCount == first.cycleCount)
        #expect(second.fullChargeCapacityMAH == first.fullChargeCapacityMAH)
        #expect(second.healthPercent == first.healthPercent)
    }

    @Test func noBatteryIsAlsoCachedAndSamplerUsesSharedRead() async throws {
        let clock = FakeClock()
        let reads = Mutex(0)
        let source = try DarwinProcessSource(readBattery: { reads.withLock { $0 += 1 }; return nil }, clock: clock)
        let sampler = try Sampler(source: source, clock: clock)
        #expect(try await sampler.sample().system.battery == nil)
        #expect(try await sampler.sample().system.battery == nil)
        #expect(reads.withLock { $0 } == 1)
        clock.advance(by: 10_000_000_000)
        #expect(source.systemBattery() == nil)
        #expect(reads.withLock { $0 } == 2)
    }
}
