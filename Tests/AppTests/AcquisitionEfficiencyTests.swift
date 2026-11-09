import Foundation
@testable import ProcglintApp
import ProcglintCore
import Testing

@MainActor
@Test func visibleTickUsesPageHeaderAndOneBatchedHistoryRequest() async throws {
    let prefs = preferences()
    defer { prefs.defaults.removePersistentDomain(forName: prefs.store.suiteName ?? "") }
    let process = try sample()
    let service = try FakeMonitorService(rows: [process])
    let clock = FakeClock()
    service.clock = clock
    let model = try MonitorViewModel(service: service, preferences: prefs, clock: clock)
    await model.setVisibility(window: true, menuBar: false)
    service.queries.removeAll()
    service.historyRequests.removeAll()
    clock.advance(by: 5_000_000_000)
    service.current.snapshotID = "sample-2"
    await model.tick()
    #expect(service.snapshotCalls == 0)
    #expect(service.queries.count == 1)
    #expect(service.historyRequests.count == 1)
    #expect(service.leaseRequests.count == 1)
    #expect(model.header == service.current.header)
    // No new collection: only the page is read, no repeated history or inspector payload.
    await model.tick()
    #expect(service.queries.count == 2)
    #expect(service.historyRequests.count == 1)

    model.select(process.processKey)
    await model.selectionUpdate?.value
    service.historyRequests.removeAll()
    service.queries.removeAll()
    await model.tick()
    #expect(service.historyRequests.map(\.series) == [["system", process.processKey.rawValue]])
    #expect(service.queries.count == 2) // Main page plus the pin lookup (not represented by the contract's row).
    #expect(service.processCalls == [process.processKey]) // Lineage is available even when paths/arguments are hidden.
}

@MainActor
@Test func reconnectReacquiresLeasesDespiteAnUnchangedAgentAndFutureTTL() async throws {
    let prefs = preferences()
    defer { prefs.defaults.removePersistentDomain(forName: prefs.store.suiteName ?? "") }
    let service = try FakeMonitorService()
    let clock = FakeClock()
    service.clock = clock
    let model = try MonitorViewModel(service: service, preferences: prefs, clock: clock)
    await model.setVisibility(window: true, menuBar: true)
    #expect(service.leaseRequests.count == 2)
    await model.agentDidReconnect()
    #expect(service.leaseRequests.count == 4)
    #expect(model.header?.agentInstanceID == "agent-a")
}

@MainActor
@Test func exitedHistorySelectionDoesNotSuppressSystemHistory() async throws {
    let prefs = preferences()
    defer { prefs.defaults.removePersistentDomain(forName: prefs.store.suiteName ?? "") }
    let process = try sample()
    let service = try FakeMonitorService(rows: [process])
    let model = try MonitorViewModel(service: service, preferences: prefs)
    await model.setVisibility(window: true, menuBar: false)
    model.select(process.processKey)
    await model.selectionUpdate?.value
    let system = HistorySeries(series: "system", points: [HistoryPoint(t: Date(), cpuPercent: .ok(25))])
    service.historySeries["system"] = system
    service.beforeHistory = {
        service.historyError = service.historyRequests.last?.series.contains(process.processKey.rawValue) == true
            ? .notFound("Selected process exited") : nil
    }
    service.historyRequests.removeAll()
    await model.tick()
    #expect(service.historyRequests.map(\.series) == [["system", process.processKey.rawValue], ["system"]])
    #expect(model.systemHistory == system)
    #expect(model.history == nil)
    #expect(model.message.contains("not_found"))
}

@MainActor
@Test func leaseRenewsOnlyBelowTwoIntervalsAndSelectionStillUpdatesImmediately() async throws {
    let prefs = preferences()
    defer { prefs.defaults.removePersistentDomain(forName: prefs.store.suiteName ?? "") }
    let service = try FakeMonitorService(rows: [sample()])
    let clock = FakeClock()
    service.clock = clock
    let model = try MonitorViewModel(service: service, preferences: prefs, clock: clock)
    await model.setVisibility(window: true, menuBar: true)
    #expect(service.leaseRequests.count == 2)
    clock.advance(by: 10_000_000_000)
    await model.tick()
    #expect(service.leaseRequests.count == 2) // Menu bar: exactly 2 × interval remains.
    clock.advance(by: 1_000_000_000)
    await model.tick()
    #expect(service.leaseRequests.count == 3)
    #expect(service.leaseRequests.last?.kind == .menuBar)
    clock.advance(by: 10_000_000_000)
    await model.tick()
    #expect(service.leaseRequests.count == 4)
    #expect(service.leaseRequests.last?.kind == .guiWindow)
    let key = try #require(service.current.processes.first?.processKey)
    model.select(key)
    await model.selectionUpdate?.value
    #expect(service.leaseRequests.count == 5)
    #expect(service.leaseRequests.last?.processKeys == [key])
    await model.setVisibility(window: false, menuBar: false)
    #expect(Set(service.released) == ["gui_window", "menu_bar"])
}
