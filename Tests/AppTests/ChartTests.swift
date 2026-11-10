import AppKit
@testable import ProcglintApp
import ProcglintCore
import Testing

@MainActor
@Test func selectionImmediatelyRenewsOnlyTheWindowLease() async throws {
    let prefs = preferences()
    defer { prefs.defaults.removePersistentDomain(forName: prefs.store.suiteName ?? "") }
    let process = try sample()
    let service = try FakeMonitorService(rows: [process])
    let model = try MonitorViewModel(service: service, preferences: prefs)
    await model.setVisibility(window: true, menuBar: true)
    let previous = service.leaseRequests.count
    model.select(process.processKey)
    await model.selectionUpdate?.value
    #expect(service.leaseRequests.count == previous + 1)
    #expect(service.leaseRequests.last?.kind == .guiWindow)
    #expect(service.leaseRequests.last?.processKeys == [process.processKey])
    await model.tick()
    #expect(service.leaseRequests.last { $0.kind == .guiWindow }?.processKeys == [process.processKey])
    let menuKeysAreEmpty = service.leaseRequests.filter { $0.kind == .menuBar }.allSatisfy(\.processKeys.isEmpty)
    #expect(menuKeysAreEmpty)
    #expect(model.history?.points.isEmpty == true)
    model.select(nil)
    await model.selectionUpdate?.value
    #expect(service.leaseRequests.last?.processKeys.isEmpty == true)
    #expect(model.history == nil)
    await model.setVisibility(window: false, menuBar: true)
    let hidden = service.leaseRequests.count
    model.select(process.processKey)
    await model.selectionUpdate?.value
    #expect(service.leaseRequests.count == hidden)
    await model.setVisibility(window: true, menuBar: true)
    #expect(service.leaseRequests.last { $0.kind == .guiWindow }?.processKeys == [process.processKey])
}

@MainActor
@Test func selectionChangedDuringLeaseRenewalInstallsTheLatestKeys() async throws {
    let prefs = preferences()
    defer { prefs.defaults.removePersistentDomain(forName: prefs.store.suiteName ?? "") }
    let first = try sample()
    let second = try sample(pid: 43, key: "p1.boot-a.43.20")
    let service = try FakeMonitorService(rows: [first, second])
    let model = try MonitorViewModel(service: service, preferences: prefs)
    await model.setVisibility(window: true, menuBar: false)
    let gate = RequestGate()
    service.beforeLease = { service.beforeLease = nil; await gate.suspend() }
    model.select(first.processKey)
    await gate.waitUntilEntered()
    model.select(second.processKey)
    let pending = model.selectionUpdate
    gate.resume()
    await pending?.value
    #expect(service.leaseRequests.suffix(2).map(\.processKeys) == [[first.processKey], [second.processKey]])
    #expect(model.selectedKey == second.processKey)
}

@MainActor
@Test func systemHistoryUsesCursorOnlyForNewVisibleSnapshots() async throws {
    let prefs = preferences()
    defer { prefs.defaults.removePersistentDomain(forName: prefs.store.suiteName ?? "") }
    let service = try FakeMonitorService()
    service.currentPolicy = try SamplingPolicy(historyMinutes: 2)
    let system = HistorySeries(series: "system", points: [HistoryPoint(t: Date(), cpuPercent: .ok(25), memoryUsedBytes: .ok(4096))])
    service.historySeries["system"] = system
    let model = try MonitorViewModel(service: service, preferences: prefs)
    await model.setVisibility(window: false, menuBar: true)
    #expect(service.historyRequests.isEmpty)
    await model.setVisibility(window: true, menuBar: true)
    #expect(service.historyRequests.count == 1)
    let request = try #require(service.historyRequests.first)
    #expect(request.series == ["system"])
    #expect(request.since == nil)
    #expect(request.cursor == "")
    #expect(model.systemHistory == system)
    await model.tick()
    #expect(service.historyRequests.count == 1)
    service.current.snapshotID = "sample-2"
    await model.tick()
    #expect(service.historyRequests.count == 2)
    await model.setVisibility(window: false, menuBar: true)
    await model.tick()
    #expect(service.historyRequests.count == 2)
    await model.setVisibility(window: false, menuBar: false)
    await model.tick()
    #expect(service.historyRequests.count == 2)
}

@MainActor
@Test func systemHistoryResponseIsDiscardedIfTheWindowBecomesHidden() async throws {
    let prefs = preferences()
    defer { prefs.defaults.removePersistentDomain(forName: prefs.store.suiteName ?? "") }
    let service = try FakeMonitorService()
    let model = try MonitorViewModel(service: service, preferences: prefs)
    let gate = RequestGate()
    service.beforeHistory = { await gate.suspend() }
    let fetching = Task { await model.setVisibility(window: true, menuBar: false) }
    await gate.waitUntilEntered()
    await model.setVisibility(window: false, menuBar: false)
    gate.resume()
    await fetching.value
    #expect(model.systemHistory == nil)
    #expect(service.released == ["gui_window"])
}

@MainActor
@Test func fullProcessHistoryKeepsSystemMonitoringAndExplainsTheLimit() async throws {
    let prefs = preferences()
    defer { prefs.defaults.removePersistentDomain(forName: prefs.store.suiteName ?? "") }
    let process = try sample()
    let service = try FakeMonitorService(rows: [process])
    let model = try MonitorViewModel(service: service, preferences: prefs)
    await model.setVisibility(window: true, menuBar: false)
    service.leaseHistoryError = .historyLimitReached("full")
    model.select(process.processKey)
    await model.selectionUpdate?.value
    await model.tick()
    #expect(model.message.contains("history_limit_reached"))
    #expect(model.message.contains("Unpin"))
    #expect(model.header != nil)
    #expect(model.systemHistory != nil)
    #expect(model.history == nil)
    #expect(service.leaseRequests.last?.processKeys.isEmpty == true)
    #expect(service.historyRequests.allSatisfy { $0.series == ["system"] })
    service.leaseHistoryError = nil
    await model.tick()
    #expect(model.message.isEmpty)
    #expect(model.history != nil)
}

@MainActor
@Test func exitedSelectionDoesNotBlockTheNextProcessListRefresh() async throws {
    let prefs = preferences()
    defer { prefs.defaults.removePersistentDomain(forName: prefs.store.suiteName ?? "") }
    let process = try sample()
    let service = try FakeMonitorService(rows: [process])
    let model = try MonitorViewModel(service: service, preferences: prefs)
    await model.setVisibility(window: true, menuBar: false)
    model.select(process.processKey)
    await model.selectionUpdate?.value
    service.current = snapshot()
    service.leaseHistoryError = .notFound("Process exited")
    await model.tick()
    await model.selectionUpdate?.value
    #expect(model.selectedKey == nil)
    #expect(model.rows.isEmpty)
    #expect(model.header != nil)
    #expect(service.leaseRequests.last?.processKeys.isEmpty == true)
}

@MainActor
@Test func compactChartsKeepFixedScaleSplitGapsAndMissingValues() throws {
    let series = HistorySeries(series: "system", points: [0, 1, 4, 5].map {
        HistoryPoint(t: Date(timeIntervalSince1970: Double($0)), cpuPercent: .ok(25), memoryUsedBytes: .ok(4096))
    }, gaps: [HistoryGap(from: Date(timeIntervalSince1970: 2), to: Date(timeIntervalSince1970: 3))])
    #expect(ChartGeometry.segments(series, value: { $0.cpuPercent }).map(\.count) == [2, 2])
    let prefs = preferences()
    defer { prefs.defaults.removePersistentDomain(forName: prefs.store.suiteName ?? "") }
    let model = try MonitorViewModel(service: FakeMonitorService(), preferences: prefs)
    model.apply(ProcessPage(snapshot: snapshot().header, items: [], totalMatched: 0))
    #expect(HistoryChart(model: model, kind: .systemCPU).fixedMaximum == 100)
    #expect(HistoryChart(model: model, kind: .pressure).fixedMaximum == 100)
    #expect(HistoryChart(model: model, kind: .systemMemory).fixedMaximum == 8192)
    #expect(HistoryChart(model: model, kind: .cpu).fixedMaximum == nil)
    #expect(HistoryChartKind.systemCPU.values(at: series.points.last) == "25.0%")
    #expect(HistoryChartKind.cpu.values(at: HistoryPoint(t: Date(), cpuPercent: .warmingUp)).contains("warming_up"))
}

@MainActor
@Test func windowChartsHaveStableAccessibilityIdentifiersAndLatestValues() async throws {
    _ = NSApplication.shared
    let prefs = preferences()
    defer { prefs.defaults.removePersistentDomain(forName: prefs.store.suiteName ?? "") }
    let process = try sample()
    let service = try FakeMonitorService(rows: [process])
    let time = Date()
    service.historySeries["system"] = HistorySeries(series: "system", points: [
        HistoryPoint(t: time, cpuPercent: .ok(25), memoryUsedBytes: .ok(4096), memoryPressurePercent: .ok(39), memoryPressure: .normal),
    ])
    service.historySeries[process.processKey.rawValue] = HistorySeries(series: process.processKey.rawValue, points: [
        HistoryPoint(t: time, cpuPercent: .ok(12.5), footprintBytes: .ok(2048), diskReadBps: .ok(1024), diskWriteBps: .ok(512)),
    ])
    let model = try MonitorViewModel(service: service, preferences: prefs)
    let controller = MainWindowController(model: model)
    await model.setVisibility(window: true, menuBar: false)
    model.select(process.processKey)
    await model.selectionUpdate?.value
    await model.refreshInspector()
    #expect([HistoryChartKind.systemCPU, .systemMemory, .pressure, .cpu, .memory, .io].map(\.identifier) == [
        "systemCPUChart", "systemMemoryChart", "systemPressureChart", "processCPUChart", "processMemoryChart", "processIOChart",
    ])
    controller.render()
    #expect(HistoryChartKind.systemCPU.values(at: model.systemHistory?.points.last) == "25.0%")
    #expect(HistoryChartKind.systemMemory.values(at: model.systemHistory?.points.last) == "4.0 KiB")
    #expect(HistoryChartKind.pressure.values(at: model.systemHistory?.points.last) == "39%")
    #expect(HistoryChartKind.cpu.values(at: model.history?.points.last) == "12.5%")
    #expect(HistoryChartKind.memory.values(at: model.history?.points.last) == "2.0 KiB")
    #expect(HistoryChartKind.io.values(at: model.history?.points.last) == "Read: 1.0 KiB/s, Write: 512 B/s")
    controller.window?.close()
}

@MainActor
@Test func summaryChartsKeepTheirSizeAndLabelsAtDefaultAndMinimumWindowWidths() throws {
    _ = NSApplication.shared
    let prefs = preferences()
    defer { prefs.defaults.removePersistentDomain(forName: prefs.store.suiteName ?? "") }
    let model = try MonitorViewModel(service: FakeMonitorService(), preferences: prefs)
    let controller = MainWindowController(model: model)
    let window = try #require(controller.window)
    defer { window.close() }
    controller.render()
    for width in [window.frame.width, window.minSize.width] {
        window.setFrame(NSRect(x: 0, y: 0, width: width, height: window.frame.height), display: false)
        let content = try #require(window.contentView)
        content.layoutSubtreeIfNeeded()
        controller.splitController.splitView.adjustSubviews()
        controller.splitController.view.layoutSubtreeIfNeeded()
        #expect(controller.splitController.splitViewItems.count == 2)
        #expect(controller.splitController.splitViewItems.last?.canCollapse == true)
        #expect(controller.splitController.view.frame.width <= content.bounds.width)
        #expect(window.toolbarStyle == .unified)
        #expect(window.toolbar?.items.contains { $0 is NSSearchToolbarItem } == true)
        controller.toggleInspector()
        #expect(controller.splitController.splitViewItems.last?.isCollapsed == true)
        controller.toggleInspector()
        #expect(controller.splitController.splitViewItems.last?.isCollapsed == false)
        #expect(SummaryCard.visible(in: model.header).map(\.title) == ["CPU", "Memory used / physical", "Memory pressure", "Swap", "Compressed"])
    }
}
