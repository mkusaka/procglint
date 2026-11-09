import AppKit
@testable import ProcglintApp
import ProcglintCore
import Testing

private func date(_ seconds: Double) -> Date {
    Date(timeIntervalSince1970: seconds)
}

@Test func chartTimeMappingRoundTripsAndClampsMousePositions() {
    let plot = CGRect(x: 4, y: 2, width: 160, height: 36)
    for range in [date(10) ... date(30), date(10) ... date(10.5)] {
        let middle = range.lowerBound.addingTimeInterval(range.upperBound.timeIntervalSince(range.lowerBound) / 2)
        #expect(ChartGeometry.x(for: range.lowerBound, in: range, plot: plot) == 4)
        #expect(ChartGeometry.x(for: middle, in: range, plot: plot) == 84)
        #expect(ChartGeometry.x(for: range.upperBound, in: range, plot: plot) == 164)
        #expect(ChartGeometry.time(atX: 84, in: range, plot: plot) == middle)
        #expect(ChartGeometry.time(atX: -100, in: range, plot: plot) == range.lowerBound)
        #expect(ChartGeometry.time(atX: 200, in: range, plot: plot) == range.upperBound)
    }
    #expect(ChartGeometry.time(atX: 84, in: date(10) ... date(10), plot: plot) == date(10))
    #expect(ChartGeometry.x(for: date(10), in: date(10) ... date(10), plot: plot) == 4)
    #expect(ChartGeometry.time(atX: 84, in: date(10) ... date(30), plot: .zero) == date(10))
}

@Test func nearestPointHandlesEmptySingleIrregularAndGappedHistory() {
    var series = HistorySeries(series: "system", points: [])
    #expect(ChartGeometry.nearestPoint(in: series, to: date(10)) == nil)
    series.points = [10, 20, 40].map { HistoryPoint(t: date($0), cpuPercent: .ok($0)) }
    #expect(ChartGeometry.nearestPoint(in: series, to: date(9)) == nil)
    #expect(ChartGeometry.nearestPoint(in: series, to: date(41)) == nil)
    #expect(ChartGeometry.nearestPoint(in: series, to: date(10))?.t == date(10))
    #expect(ChartGeometry.nearestPoint(in: series, to: date(15))?.t == date(10))
    #expect(ChartGeometry.nearestPoint(in: series, to: date(31))?.t == date(40))
    series.gaps = [HistoryGap(from: date(19), to: date(30))]
    #expect(ChartGeometry.nearestPoint(in: series, to: date(25)) == nil)
    #expect(ChartGeometry.nearestPoint(in: series, to: date(30))?.t == date(40))
    series.points.reverse()
    #expect(ChartGeometry.timeRange(series) == date(10) ... date(40))
    #expect(ChartGeometry.nearestPoint(in: series, to: date(30))?.t == date(40))
    series.points = [series.points[2]]
    #expect(ChartGeometry.nearestPoint(in: series, to: date(10))?.t == date(10))
}

@MainActor
@Test func pressureAreasSplitColoursWithoutBridgingGapsOrMissingValues() {
    var series = HistorySeries(series: "system", points: [MemoryPressure.normal, .warning, .critical].enumerated().map { index, level in
        HistoryPoint(t: date(Double(index * 10)), cpuPercent: .ok(25), memoryPressurePercent: .ok(39), memoryPressure: level)
    })
    let segments = ChartGeometry.pressureSegments(series)
    #expect(segments.map { $0.first?.pressure } == [.normal, .warning, .critical])
    #expect(segments.map { $0.map(\.time) } == [[date(0), date(5)], [date(5), date(10), date(15)], [date(15), date(20)]])
    #expect(segments.map { ChartGeometry.pressureColor($0.first?.pressure) } == [.systemGreen, .systemYellow, .systemRed])
    #expect(ChartGeometry.pressureColor(nil) == .secondaryLabelColor)
    series.gaps = [HistoryGap(from: date(1), to: date(9))]
    #expect(ChartGeometry.pressureSegments(series).map(\.count) == [1, 2, 2])
    series.points[1].memoryPressurePercent = .unsupported
    #expect(ChartGeometry.pressureSegments(series).map(\.count) == [1, 1])
    series.points[2].memoryPressure = nil
    #expect(ChartGeometry.pressureSegments(series).last?.first?.pressure == nil)
}

@MainActor
@Test func hoveringSynchronisesEveryChartAndLeavesLatestAccessibilityValuesUnchanged() async throws {
    _ = NSApplication.shared
    let fixture = try UITestingFixture()
    let pressureHistory = try #require(await fixture.history(HistoryRequest(series: ["system"])).first)
    #expect(ChartGeometry.pressureSegments(pressureHistory).contains { $0.first?.pressure == .warning && $0.count > 1 })
    let prefs = try fixture.preferences()
    defer { fixture.cleanUp() }
    let controller = try MainWindowController(model: MonitorViewModel(service: fixture, preferences: prefs))
    defer { controller.window?.close() }
    let series = HistorySeries(series: "system", points: [10.0, 20, 40].map {
        HistoryPoint(t: date($0), cpuPercent: .ok($0), footprintBytes: .ok($0 * 1024),
                     diskReadBps: .ok($0), diskWriteBps: .ok($0 * 2), memoryUsedBytes: .ok($0 * 1024), memoryPressurePercent: .ok($0))
    })
    let charts = [controller.systemCPUChart, controller.systemMemoryChart, controller.systemPressureChart,
                  controller.cpuChart, controller.memoryChart, controller.ioChart]
    for chart in charts {
        chart.update(series)
    }
    controller.window?.contentView?.layoutSubtreeIfNeeded()
    let cpu = controller.systemCPUChart
    let location = cpu.convert(NSPoint(x: cpu.bounds.midX, y: cpu.bounds.midY), to: nil)
    let event = try #require(NSEvent.mouseEvent(with: .mouseMoved, location: location, modifierFlags: [], timestamp: 0,
                                                windowNumber: controller.window?.windowNumber ?? 0, context: nil,
                                                eventNumber: 0, clickCount: 0, pressure: 0))
    cpu.mouseEntered(with: event)
    #expect(controller.chartCursor.time == date(25))
    let readout = try #require(cpu.hoverReadout)
    #expect(readout.range(of: #"^\d{2}:\d{2}:\d{2} · 20\.0%$"#, options: .regularExpression) != nil)
    #expect(controller.systemMemoryChart.hoverReadout == "20.0 KiB")
    #expect(controller.systemPressureChart.hoverReadout == "20%")
    #expect(controller.ioChart.hoverReadout == "Read: 20 B/s, Write: 40 B/s")
    for chart in charts {
        #expect(chart.hoverReadout != nil)
        #expect(chart.accessibilityHelp()?.hasPrefix("Cursor: ") == true)
    }
    #expect(controller.systemCPUChart.accessibilityValue() as? String == "40.0%")
    #expect(controller.systemMemoryChart.accessibilityValue() as? String == "40.0 KiB")
    controller.chartCursor.move(to: date(30), from: controller.ioChart)
    controller.chartCursor.clear(from: controller.systemCPUChart)
    #expect(controller.chartCursor.time == date(30))
    controller.systemMemoryChart.update(HistorySeries(series: "system", points: [series.points[0]]))
    #expect(controller.systemMemoryChart.hoverReadout == nil)
    controller.ioChart.mouseExited(with: NSEvent())
    for chart in charts {
        #expect(chart.hoverReadout == nil)
        #expect(chart.accessibilityHelp() == nil)
    }
}
