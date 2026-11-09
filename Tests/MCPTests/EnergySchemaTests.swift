import Foundation
import ProcglintCore
@testable import ProcglintMCPKit
import Testing

struct EnergySchemaTests {
    @Test func snapshotPowerSortAndProjectedPowerMatchSchemas() async throws {
        let service = TestMonitor()
        let tools = MCPTools(service: service, flags: MCPFlags())
        let snapshot = try await tools.call("get_snapshot", arguments: ["sort": "power"])
        try Schema.snapshot.validate(snapshot, at: "snapshot")
        #expect(snapshot["system"]?["battery"]?["percent"] == ["value": 69, "status": "ok"])
        let processes = try #require(snapshot["processes"]).decode([JSONValue].self)
        #expect(processes.first?["power_mw"] == ["value": 3000, "status": "ok"])
        #expect(await service.calls.last?.1["sort"] == "power")
        let page = try await tools.call("list_processes", arguments: ["sort": "power", "fields": ["power_mw"]])
        try Schema.page.validate(page, at: "page")
        let items = try #require(page["items"]).decode([[String: JSONValue]].self)
        let item = try #require(items.first)
        #expect(Set(item.keys) == ["process_key", "power_mw"])
        let detail = try await tools.call("get_process", arguments: ["process_key": "p1.boot-a.42.1"])
        try Schema.process.validate(detail, at: "process")
        let status = try await tools.call("get_monitor_status", arguments: [:])
        try Schema.monitorStatus.validate(status, at: "status")
        #expect(status["system"]?["battery"] != nil)
    }

    @Test func noBatteryUnsupportedMetricsAndHistoryMatchSchemas() throws {
        var snapshot = try makeSnapshot()
        snapshot.system.battery = nil
        snapshot.processes[0].powerMW = .unsupported
        try Schema.snapshot.validate(JSONValue.encoded(snapshot), at: "snapshot")
        snapshot.system.battery = BatteryMetrics()
        try Schema.snapshot.validate(JSONValue.encoded(snapshot), at: "snapshot")
        let points = [HistoryPoint(t: testDate, cpuPercent: .warmingUp, systemPowerMW: .unsupported, batteryPercent: .ok(69)),
                      HistoryPoint(t: testDate, cpuPercent: .ok(1), powerMW: .ok(3000))]
        try Schema.history.validate(JSONValue.encoded(HistorySeries(series: "system", points: points)), at: "history")
        let definitions = MCPTools(service: TestMonitor(), flags: MCPFlags()).definitions
        for name in ["get_snapshot", "list_processes"] {
            let definition = try #require(definitions.first { $0.name == name })
            try definition.input.validate(["sort": "power"], at: "input")
        }
    }
}
