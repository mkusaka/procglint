import Foundation
@testable import ProcglintApp
import ProcglintCore
import Testing

@MainActor
@Test func historyDeltasAppendTrimAndResetOnFullFetchAndAgentRestart() async throws {
    let prefs = preferences()
    defer { prefs.defaults.removePersistentDomain(forName: prefs.store.suiteName ?? "") }
    let service = try FakeMonitorService()
    let point: (Int) -> HistoryPoint = { HistoryPoint(t: Date(timeIntervalSince1970: Double($0)), cpuPercent: .ok(Double($0))) }
    service.historySeries["system"] = HistorySeries(series: "system", points: [point(1), point(2)], nextCursor: "cursor-a", retainedPointCount: 2)
    let model = try MonitorViewModel(service: service, preferences: prefs)
    await model.setVisibility(window: true, menuBar: false)
    #expect(service.historyRequests.last?.cursor == "")
    service.current.snapshotID = "sample-2"
    service.historySeries["system"] = HistorySeries(series: "system", points: [point(3)], nextCursor: "cursor-b", isDelta: true, retainedPointCount: 2)
    await model.tick()
    #expect(service.historyRequests.last?.cursor == "cursor-a")
    #expect(model.systemHistory?.points == [point(2), point(3)])
    service.current.snapshotID = "sample-3"
    service.historySeries["system"] = HistorySeries(series: "system", points: [point(4)], nextCursor: "cursor-c", retainedPointCount: 1)
    await model.tick()
    #expect(model.systemHistory?.points == [point(4)])
    service.current.agentInstanceID = "agent-b"
    service.current.snapshotID = "restarted"
    service.historySeries["system"] = HistorySeries(series: "system", points: [point(5)], nextCursor: "cursor-d", retainedPointCount: 1)
    await model.tick()
    #expect(service.historyRequests.last?.cursor == "")
    #expect(model.systemHistory?.points == [point(5)])
}
