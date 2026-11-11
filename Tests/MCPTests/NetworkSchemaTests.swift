import Foundation
import ProcglintCore
@testable import ProcglintMCPKit
import Testing

struct NetworkSchemaTests {
    @Test func networkSortFieldsStatusAndHistoryMatchSchemas() async throws {
        let service = TestMonitor()
        let tools = MCPTools(service: service, flags: MCPFlags())
        let snapshot = try await tools.call("get_snapshot", arguments: ["sort": "network"])
        try Schema.snapshot.validate(snapshot, at: "snapshot")
        #expect(snapshot["system"]?["network_receive_bps"] == ["value": .null, "status": "unsupported"])
        #expect(await service.calls.last?.1["sort"] == "network")
        let page = try await tools.call("list_processes", arguments: ["sort": "network", "fields": ["network_receive_bps", "network_send_bps"]])
        try Schema.page.validate(page, at: "page")
        let items = try #require(page["items"]).decode([[String: JSONValue]].self)
        #expect(try Set(#require(items.first).keys) == ["process_key", "network_receive_bps", "network_send_bps"])
        let detail = try await tools.call("get_process", arguments: ["process_key": "p1.boot-a.42.1"])
        try Schema.process.validate(detail, at: "process")
        #expect(detail["network_received_bytes"] == ["value": .null, "status": "unsupported"])
        let status = try await tools.call("get_monitor_status", arguments: [:])
        try Schema.monitorStatus.validate(status, at: "status")
        #expect(status["system"]?["network_send_bps"] != nil)
        let points = [HistoryPoint(t: testDate, cpuPercent: .warmingUp, networkReceiveBps: .ok(123), networkSendBps: .permissionDenied)]
        try Schema.history.validate(JSONValue.encoded(HistorySeries(series: "system", points: points)), at: "history")
        let definitions = tools.definitions
        #expect(definitions.first { $0.name == "get_snapshot" }?.description.contains("private NetworkStatistics") == true)
        #expect(definitions.first { $0.name == "list_processes" }?.description.contains("permission_denied") == true)
    }
}
