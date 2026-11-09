import Foundation
import ProcglintCore
@testable import ProcglintMCPKit
import Testing

struct EnergyIntegrationTests {
    @Test func powerFlowsThroughAgentXPCAndMCPProjection() async throws {
        let harness = try AgentHarness()
        harness.source.update {
            $0.processes[42]?.rusage.energyNJ = 1_000_000_000
            $0.processes[43]?.rusage.energyNJ = 1_000_000_000
        }
        let client = harness.client()
        try await harness.warm(client)
        harness.source.update {
            $0.processes[42]?.rusage.energyNJ = 2_000_000_000
            $0.processes[43]?.rusage.energyNJ = 4_000_000_000
        }
        harness.advance(seconds: 6)
        let snapshot = try await client.snapshot(top: 1, sort: .power)
        #expect(snapshot.processes.first?.pid == 43)
        #expect(snapshot.processes.first?.powerMW == .ok(500))
        let content = try await integrationCall(harness.server(client), "list_processes", arguments: ["sort": "power", "fields": ["pid", "power_mw"]])
        let items = try #require(content["items"]).decode([[String: JSONValue]].self)
        #expect(items.first?["pid"] == 43)
        #expect(items.first?["power_mw"] == ["value": 500, "status": "ok"])
        #expect(items.allSatisfy { $0["process_key"] != nil && $0["name"] == nil })
        await client.invalidate()
        await harness.close()
    }
}
