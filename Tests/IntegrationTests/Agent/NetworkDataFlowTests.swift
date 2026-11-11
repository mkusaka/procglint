import Foundation
import ProcglintCore
@testable import ProcglintMCPKit
import Testing

actor NetworkFixture: NetworkSource {
    var bytes: UInt64 = 100

    func setBytes(_ bytes: UInt64) {
        self.bytes = bytes
    }

    func counters() -> NetworkCounters {
        NetworkCounters(interfaces: [1: NetworkBytes(received: bytes, sent: bytes * 2)],
                        processes: [NetworkProcess(pid: 42, startTimeUS: 100): NetworkBytes(received: bytes, sent: bytes * 2),
                                    NetworkProcess(pid: 43, startTimeUS: 100): NetworkBytes(received: bytes * 3, sent: bytes * 4)],
                        processStatus: .ok)
    }
}

struct NetworkDataFlowTests {
    @Test func samplerAgentIPCMCPCLIAndHistoryPreserveNetworkMetrics() async throws {
        let network = NetworkFixture()
        let harness = try AgentHarness(networkSource: network)
        let client = harness.client(flags: [.includeSystem, .observe])
        try await harness.warm(client)
        _ = try await client.startObservation(ObservationRequest(intervalMS: .fiveSeconds, durationMS: 60000, processKeys: [harness.key()]))
        await network.setBytes(700)
        harness.advance(seconds: 6)
        let snapshot = try await client.snapshot(top: 200, sort: .network)
        #expect(snapshot.processes.first?.pid == 43)
        #expect(snapshot.system.networkReceiveBps == .ok(100))
        #expect(snapshot.system.networkSendBps == .ok(200))
        let own = try #require(snapshot.processes.first { $0.pid == 42 })
        #expect(own.networkReceiveBps == .ok(100))
        #expect(own.networkSendBps == .ok(200))
        #expect(own.networkReceivedBytes == .ok(700))
        #expect(own.networkSentBytes == .ok(1400))
        #expect(snapshot.processes.first { $0.pid == 84 }?.networkReceiveBps == .permissionDenied)
        let page = try await integrationCall(harness.server(client, flags: [.includeSystem]), "list_processes",
                                             arguments: ["sort": "network", "fields": ["pid", "network_receive_bps", "network_send_bps"]])
        let items = try #require(page["items"]).decode([[String: JSONValue]].self)
        #expect(items.first?["pid"] == 43)
        #expect(items.first?["network_receive_bps"] == ["value": 300, "status": "ok"])
        #expect(items.first?["network_send_bps"] == ["value": 400, "status": "ok"])
        #expect(items.first?["name"] == nil)
        let detail = try await client.process(key: own.processKey)
        #expect(detail.networkSentBytes == own.networkSentBytes)
        let history = try await client.history(HistoryRequest(series: ["system", own.processKey.rawValue]))
        #expect(history.first { $0.series == "system" }?.points.last?.networkReceiveBps == .ok(100))
        #expect(history.first { $0.series == own.processKey.rawValue }?.points.last?.networkSendBps == .ok(200))
        #expect(networkSummary(receive: .ok(1_200_000), send: .ok(340_000)) == "Network: ↓ 1.2 MB/s ↑ 340 KB/s")
        #expect(processSummary(detail).contains("Network: ↓ 100 B/s ↑ 200 B/s"))
        #expect(networkSummary(receive: .permissionDenied, send: .unsupported).contains("permission_denied"))
        #expect(try CLICommand.parse(["export", "snapshot", "--sort", "network"]) == .snapshot(format: .json, all: false, sort: .network))
        let csv = snapshotCSV(snapshot).components(separatedBy: "\r\n")
        let headers = csv[0].components(separatedBy: ",")
        let row = Dictionary(uniqueKeysWithValues: zip(headers, csv[1].components(separatedBy: ",")))
        #expect(row["network_receive_bps"] == "300.0")
        #expect(row["network_sent_bytes"] == "2800.0")
        #expect(row["system_network_send_bps"] == "200.0")
        #expect(historyCSV(history).contains("network_receive_bps,network_receive_bps_status,network_send_bps,network_send_bps_status"))
        #expect(try jsonOutput(snapshot).contains("network_received_bytes"))
        let status = try await client.status()
        #expect(statusSummary(status, system: snapshot.system).contains("Network: ↓ 100 B/s ↑ 200 B/s"))
        await client.invalidate()
        await harness.close()
    }
}
