import Foundation
import ProcglintCore
import Testing

struct NetworkJSONTests {
    @Test func snapshotsAndHistoryRoundTripAndOlderPayloadsRemainUnsupported() throws {
        var process = try storeProcess()
        process.networkReceiveBps = .ok(123)
        process.networkSendBps = .warmingUp
        process.networkReceivedBytes = .ok(9_000_000_000)
        process.networkSentBytes = .permissionDenied
        var snapshot = storeSnapshot(processes: [process])
        snapshot.system.networkReceiveBps = .ok(999)
        snapshot.system.networkSendBps = .unsupported
        let data = try ProcglintJSON.encoder().encode(snapshot)
        #expect(try ProcglintJSON.decoder().decode(Snapshot.self, from: data) == snapshot)
        let fields = ["network_receive_bps", "network_send_bps", "network_received_bytes", "network_sent_bytes"]
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var processes = try #require(object["processes"] as? [[String: Any]])
        #expect((processes[0]["network_received_bytes"] as? [String: Any])?["value"] as? Double == 9_000_000_000)
        processes[0] = processes[0].filter { !fields.contains($0.key) }
        object["processes"] = processes
        object["system"] = (object["system"] as? [String: Any])?.filter { !fields.contains($0.key) }
        let legacy = try ProcglintJSON.decoder().decode(Snapshot.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(legacy.system.networkReceiveBps == .unsupported)
        #expect(legacy.system.networkSendBps == .unsupported)
        #expect(legacy.processes[0].networkReceiveBps == .unsupported)
        #expect(legacy.processes[0].networkSendBps == .unsupported)
        #expect(legacy.processes[0].networkReceivedBytes == .unsupported)
        #expect(legacy.processes[0].networkSentBytes == .unsupported)
        let point = HistoryPoint(t: snapshot.sampledAt, cpuPercent: .warmingUp, networkReceiveBps: .ok(1), networkSendBps: .stale)
        let encoded = try ProcglintJSON.encoder().encode(point)
        #expect(try ProcglintJSON.decoder().decode(HistoryPoint.self, from: encoded) == point)
        let oldPoint = HistoryPoint(t: snapshot.sampledAt, cpuPercent: .warmingUp)
        let decoded = try ProcglintJSON.decoder().decode(HistoryPoint.self, from: ProcglintJSON.encoder().encode(oldPoint))
        #expect(decoded.networkReceiveBps == nil)
        #expect(decoded.networkSendBps == nil)
    }

    @Test func networkSortAddsDirectionsAndKeepsMissingLastInBothOrders() throws {
        var first = try storeProcess(pid: 42)
        var second = try storeProcess(pid: 43)
        let missing = try storeProcess(pid: 44)
        first.networkReceiveBps = .ok(100)
        first.networkSendBps = .ok(0)
        second.networkReceiveBps = .ok(0)
        second.networkSendBps = .ok(200)
        var store = SnapshotStore(clock: FakeClock())
        store.insert(storeSnapshot(processes: [first, second, missing]))
        for (order, pids) in [(SortOrder.desc, [Int32(43), 42, 44]), (.asc, [42, 43, 44])] {
            let query = try ProcessQuery(sort: .network, order: order, fields: [.networkReceiveBps, .networkSendBps])
            #expect(try store.listProcesses(query, scope: AccessScope()).items.map(\.pid) == pids)
            let projected = try store.listProcessesJSON(query, scope: AccessScope())
            let json = try #require(JSONSerialization.jsonObject(with: projected) as? [String: Any])
            let items = try #require(json["items"] as? [[String: Any]])
            #expect(Set(items[0].keys) == ["process_key", "network_receive_bps", "network_send_bps"])
        }
    }
}
