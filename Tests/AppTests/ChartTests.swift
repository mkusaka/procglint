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
@Test func compactChartsKeepFixedScaleSplitGapsAndOnlyRedrawChanges() {
    let series = HistorySeries(series: "system", points: [0, 1, 4, 5].map {
        HistoryPoint(t: Date(timeIntervalSince1970: Double($0)), cpuPercent: .ok(25), memoryUsedBytes: .ok(4096))
    }, gaps: [HistoryGap(from: Date(timeIntervalSince1970: 2), to: Date(timeIntervalSince1970: 3))])
    let segments = ChartGeometry.segments(series, value: { $0.cpuPercent })
    #expect(segments.map(\.count) == [2, 2])
    #expect(segments.flatMap(\.self).map { ChartGeometry.fraction($0.value, in: 0 ... 100) } == [0.25, 0.25, 0.25, 0.25])
    #expect(ChartGeometry.fraction(4096, in: 0 ... 8192) == 0.5)
    #expect(ChartGeometry.fraction(150, in: 0 ... 100) == 1)
    #expect(ChartGeometry.fraction(-1, in: 0 ... 100) == 0)
    let chart = HistoryChartView(label: "System CPU", fields: [{ $0.cpuPercent }], compact: true, format: Display.percent)
    chart.update(series, fixedYRange: 0 ... 100)
    #expect(chart.accessibilityLabel()?.contains("25.0%") == true)
    #expect(chart.accessibilityValue() as? String == "25.0%")
    #expect(chart.fixedYRange == 0 ... 100)
    chart.setAccessibilityValue("unchanged")
    chart.update(series, fixedYRange: 0 ... 100)
    #expect(chart.accessibilityValue() as? String == "unchanged")
    chart.update(series, fixedYRange: 0 ... 200)
    #expect(chart.fixedYRange == 0 ... 200)
    #expect(chart.accessibilityValue() as? String == "25.0%")
    var updated = series
    updated.points.append(HistoryPoint(t: Date(timeIntervalSince1970: 6), cpuPercent: .warmingUp))
    chart.update(updated, fixedYRange: 0 ... 100)
    #expect(chart.accessibilityLabel()?.contains("warming_up") == true)
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
    #expect(controller.systemCPUChart.accessibilityIdentifier() == "systemCPUChart")
    #expect(controller.systemMemoryChart.accessibilityIdentifier() == "systemMemoryChart")
    #expect(controller.systemPressureChart.accessibilityIdentifier() == "systemPressureChart")
    #expect(controller.cpuChart.accessibilityIdentifier() == "processCPUChart")
    #expect(controller.memoryChart.accessibilityIdentifier() == "processMemoryChart")
    #expect(controller.ioChart.accessibilityIdentifier() == "processIOChart")
    controller.render()
    #expect(controller.systemCPUChart.fixedYRange == 0 ... 100)
    #expect(controller.systemPressureChart.fixedYRange == 0 ... 100)
    #expect(controller.systemPressureChart.accessibilityValue() as? String == "39%")
    #expect(controller.systemMemoryChart.fixedYRange == 0 ... 8192)
    #expect(controller.cpuChart.fixedYRange == nil)
    #expect(controller.systemCPUChart.accessibilityLabel()?.contains("25.0%") == true)
    #expect(controller.systemMemoryChart.accessibilityLabel()?.contains("4.0 KiB") == true)
    #expect(controller.cpuChart.accessibilityLabel()?.contains("12.5%") == true)
    #expect(controller.memoryChart.accessibilityLabel()?.contains("2.0 KiB") == true)
    #expect(controller.ioChart.accessibilityLabel()?.contains("1.0 KiB/s, 512 B/s") == true)
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
    controller.summary.stringValue = "CPU 25.0% · Memory 4.0 GiB/8.0 GiB · wired 1.0 GiB · compressed 512 MiB · ok"
    for width in [window.frame.width, window.minSize.width] {
        window.setFrame(NSRect(x: 0, y: 0, width: width, height: window.frame.height), display: false)
        let content = try #require(window.contentView)
        content.layoutSubtreeIfNeeded()
        let summaryContainer = try #require(controller.summary.superview)
        let summaryRect = controller.summary.alignmentRect(forFrame: controller.summary.frame)
        let summaryFrame = summaryContainer.convert(summaryRect, to: content)
        var previousRight = summaryFrame.maxX
        for chart in [controller.systemCPUChart, controller.systemMemoryChart, controller.systemPressureChart] {
            #expect(chart.bounds.size == NSSize(width: 160, height: 36))
            let group = try #require(chart.superview as? NSStackView)
            let label = try #require(group.arrangedSubviews.first as? NSTextField)
            #expect(label.frame.width >= label.intrinsicContentSize.width)
            let frame = group.convert(group.bounds, to: content)
            #expect(frame.minX >= previousRight + 16)
            #expect(frame.maxX <= content.bounds.maxX - 12)
            previousRight = frame.maxX
        }
    }
}
