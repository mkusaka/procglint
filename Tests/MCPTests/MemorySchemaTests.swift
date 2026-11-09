import Foundation
import ProcglintCore
@testable import ProcglintMCPKit
import Testing

struct MemorySchemaTests {
    @Test func unavailableMetricsMatchSnapshotAndStatusSchemas() async throws {
        let service = TestMonitor()
        await service.configureMemory(unavailable: true)
        let server = MCPServer(service: service)
        for name in ["get_snapshot", "get_monitor_status"] {
            let result = try await call(server, name)
            let content = try #require(result["result"]?["structuredContent"])
            let system = try #require(content["system"])
            #expect(system["memory_pressure"] == ["status": "unsupported", "value": .null])
            #expect(system["memory_pressure_percent"] == ["status": "unsupported", "value": .null])
            #expect(system["swap_used_bytes"] == ["status": "unsupported", "value": .null])
            #expect(system["swap_total_bytes"] == ["status": "unsupported", "value": .null])
            let schema = name == "get_snapshot" ? Schema.snapshot : Schema.monitorStatus
            try schema.validate(content, at: "output")
        }
    }

    @Test func continuousPressureMatchesSnapshotStatusAndHistorySchemas() async throws {
        let server = MCPServer(service: TestMonitor())
        for name in ["get_snapshot", "get_monitor_status"] {
            let result = try await call(server, name)
            let content = try #require(result["result"]?["structuredContent"])
            #expect(content["system"]?["memory_pressure_percent"] == ["status": "ok", "value": 65])
            try (name == "get_snapshot" ? Schema.snapshot : Schema.monitorStatus).validate(content, at: "output")
        }
        let point = HistoryPoint(t: testDate, cpuPercent: .ok(25), memoryPressurePercent: .ok(65), memoryPressure: .warning)
        try Schema.history.validate(JSONValue.encoded(HistorySeries(series: "system", points: [point])), at: "history")
    }

    @Test func statusRemainsUsefulIfSnapshotCannotBeRead() async throws {
        let service = TestMonitor()
        await service.configureMemory(snapshotFailure: .agentUnavailable("no snapshot"))
        let server = MCPServer(service: service)
        let result = try await call(server, "get_monitor_status")
        #expect(result["result"]?["isError"] == false)
        let content = try #require(result["result"]?["structuredContent"])
        #expect(content["system"] == .null)
        #expect(content["collections_total"] == "9007199254740993")
        try Schema.monitorStatus.validate(content, at: "output")
    }

    @Test func newSystemFieldsAreRequiredAndCategoricalPressureIsNotNumeric() throws {
        let snapshot = try JSONValue.encoded(makeSnapshot())
        let system = try #require(snapshot["system"]?.object)
        for key in ["memory_pressure", "memory_pressure_percent", "swap_used_bytes", "swap_total_bytes"] {
            var missing = system
            missing.removeValue(forKey: key)
            #expect(throws: AgentError.self) { try Schema.system.validate(.object(missing), at: "system") }
        }
        for invalid: JSONValue in [["status": "ok", "value": "unknown"], ["status": "ok", "value": 1]] {
            #expect(throws: AgentError.self) {
                try Schema.system["properties"]?["memory_pressure"]?.validate(invalid, at: "pressure")
            }
        }
        for pressure in MemoryPressure.allCases {
            var fields = system
            fields["memory_pressure"] = ["status": "ok", "value": .string(pressure.rawValue)]
            try Schema.system.validate(.object(fields), at: "system")
        }
    }
}
