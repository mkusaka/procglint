import Foundation
import ProcglintCore
import Testing

struct EnergyJSONTests {
    @Test func roundTripAndLegacyPayloads() throws {
        var process = try storeProcess()
        process.powerMW = .ok(3000)
        var snapshot = storeSnapshot(processes: [process])
        snapshot.system.battery = BatteryMetrics(percent: .ok(69), isCharging: true, externalPower: true,
                                                 designCapacityMAH: .ok(5000), systemPowerMW: .ok(33100), batteryPowerMW: .ok(-18000))
        let encoded = try ProcglintJSON.encoder().encode(snapshot)
        #expect(try ProcglintJSON.decoder().decode(Snapshot.self, from: encoded) == snapshot)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let system = try #require(object["system"] as? [String: Any])
        let battery = try #require(system["battery"] as? [String: Any])
        #expect(battery["system_power_mw"] != nil)
        #expect(battery["design_capacity_mah"] != nil)
        var processes = try #require(object["processes"] as? [[String: Any]])
        #expect(processes[0]["power_mw"] != nil)
        processes[0].removeValue(forKey: "power_mw")
        object["processes"] = processes
        object["system"] = system.filter { $0.key != "battery" }
        let legacy = try JSONSerialization.data(withJSONObject: object)
        let decoded = try ProcglintJSON.decoder().decode(Snapshot.self, from: legacy)
        #expect(decoded.system.battery == nil)
        #expect(decoded.processes[0].powerMW == .unsupported)
        #expect(decoded.processes[0].cpuPercent == process.cpuPercent)
    }

    @Test func historyStoresCorrectSeriesAndLegacyPointsDecode() throws {
        let clock = FakeClock()
        var store = try HistoryStore(clock: clock, policy: SamplingPolicy())
        var process = try storeProcess()
        process.powerMW = .warmingUp
        var snapshot = storeSnapshot(processes: [process])
        snapshot.system.battery = BatteryMetrics(percent: .ok(69), systemPowerMW: .ok(33100))
        try store.pin(key: process.processKey, pinned: true)
        store.record(snapshot)
        let system = try #require(try store.series("system").points.first)
        let point = try #require(try store.series(process.processKey.rawValue).points.first)
        #expect(system.systemPowerMW == .ok(33100))
        #expect(system.batteryPercent == .ok(69))
        #expect(system.powerMW == nil)
        #expect(point.powerMW == .warmingUp)
        #expect(point.systemPowerMW == nil)
        #expect(point.batteryPercent == nil)
        for value in [system, point] {
            let encoded = try ProcglintJSON.encoder().encode(value)
            #expect(try ProcglintJSON.decoder().decode(HistoryPoint.self, from: encoded) == value)
            var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            for field in ["system_power_mw", "battery_percent", "power_mw"] {
                object.removeValue(forKey: field)
            }
            let legacy = try ProcglintJSON.decoder().decode(HistoryPoint.self, from: JSONSerialization.data(withJSONObject: object))
            #expect(legacy.systemPowerMW == nil)
            #expect(legacy.batteryPercent == nil)
            #expect(legacy.powerMW == nil)
        }
    }
}
