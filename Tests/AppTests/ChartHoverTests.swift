import AppKit
@testable import ProcglintApp
import ProcglintCore
import Testing

private func date(_ seconds: Double) -> Date {
    Date(timeIntervalSince1970: seconds)
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
@Test func nativeHoverTrackingForHostedChartsReportsMovesAndClears() throws {
    _ = NSApplication.shared
    var locations: [CGPoint?] = []
    let view = ChartTrackingView { locations.append($0) }
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 50), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = view
    defer { window.close() }
    view.frame = NSRect(x: 0, y: 0, width: 200, height: 50)
    view.updateTrackingAreas()
    view.updateTrackingAreas()
    #expect(view.trackingAreas.count == 1)
    #expect(view.hitTest(.zero) == nil)
    let event = try #require(NSEvent.mouseEvent(with: .mouseMoved, location: NSPoint(x: 100, y: 25), modifierFlags: [], timestamp: 0,
                                                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
    view.mouseEntered(with: event)
    #expect(locations == [CGPoint(x: 100, y: 25)])
    view.mouseExited(with: event)
    #expect(locations == [CGPoint(x: 100, y: 25), nil])
    view.viewWillMove(toWindow: nil)
    #expect(locations == [CGPoint(x: 100, y: 25), nil, nil])
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
    let model = try MonitorViewModel(service: fixture, preferences: prefs)
    let series = HistorySeries(series: "system", points: [10.0, 20, 40].map {
        HistoryPoint(t: date($0), cpuPercent: .ok($0), footprintBytes: .ok($0 * 1024),
                     diskReadBps: .ok($0), diskWriteBps: .ok($0 * 2), memoryUsedBytes: .ok($0 * 1024), memoryPressurePercent: .ok($0))
    })
    let cursor = model.chartSelection
    cursor.move(to: date(25), from: .systemCPU)
    #expect(cursor.time == date(25))
    cursor.updateSelection(date(40), from: .swap)
    cursor.updateSelection(nil, from: .systemCPU)
    #expect(cursor.time == date(25))
    cursor.updateSelection(date(24), from: .systemCPU)
    #expect(cursor.time == date(24))
    cursor.move(to: date(25), from: .systemCPU)
    let readout = try #require(HistoryChartKind.systemCPU.hoverReadout(series: series, time: cursor.time, hovered: true))
    #expect(readout.hasSuffix(" · 20.0%"))
    #expect(HistoryChartKind.systemMemory.hoverReadout(series: series, time: cursor.time, hovered: false) == "20.0 KiB")
    #expect(HistoryChartKind.pressure.hoverReadout(series: series, time: cursor.time, hovered: false) == "20%")
    #expect(HistoryChartKind.io.hoverReadout(series: series, time: cursor.time, hovered: false) == "Read: 20 B/s, Write: 40 B/s")
    for kind in [HistoryChartKind.systemCPU, .systemMemory, .pressure, .cpu, .memory, .io] {
        #expect(kind.hoverReadout(series: series, time: cursor.time, hovered: cursor.hoveredChart == kind) != nil)
    }
    #expect(HistoryChartKind.systemCPU.values(at: series.points.last) == "40.0%")
    #expect(HistoryChartKind.systemMemory.values(at: series.points.last) == "40.0 KiB")
    cursor.move(to: date(30), from: .io)
    cursor.clear(from: .systemCPU)
    #expect(cursor.time == date(30))
    #expect(HistoryChartKind.systemMemory.hoverReadout(series: HistorySeries(series: "system", points: [series.points[0]]), time: cursor.time, hovered: false) == nil)
    cursor.clear(from: .io)
    #expect(cursor.time == nil && cursor.hoveredChart == nil)
    var gapped = series
    gapped.gaps = [HistoryGap(from: date(15), to: date(30))]
    #expect(HistoryChartKind.cpu.hoverReadout(series: gapped, time: date(25), hovered: true) == nil)
    cursor.move(to: date(20), from: .cpu)
    await model.setVisibility(window: false, menuBar: false)
    #expect(cursor.time == nil)
}
