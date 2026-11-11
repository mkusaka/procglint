import AppKit
@testable import ProcglintApp
import ProcglintCore
import Testing

@Test(arguments: [(0.0, "0 B"), (999, "999 B"), (1000, "1.0 KB"), (340_000, "340 KB"), (1_200_000, "1.2 MB"),
                  (1_000_000_000, "1.0 GB"), (-1, "—"), (.infinity, "—"), (.nan, "—")])
func networkFormatting(bytes: Double, expected: String) {
    #expect(Display.networkBytes(bytes) == expected)
    #expect(Display.networkRate(bytes) == (expected == "—" ? expected : expected + "/s"))
}

@Test(arguments: [Metric.warmingUp, .permissionDenied, .exited, .stale, .unsupported])
func networkDirectionsKeepMissingReasons(missing: Metric) {
    #expect(Display.networkRates(receive: missing, send: .ok(0)) == MetricText(text: "↓ — ↑ 0 B/s", reason: "Receive: " + missing.status.rawValue))
    #expect(Display.networkRates(receive: .ok(1_200_000), send: missing) == MetricText(text: "↓ 1.2 MB/s ↑ —", reason: "Send: " + missing.status.rawValue))
    #expect(Display.networkRates(receive: missing, send: missing).text == "↓ — ↑ —")
}

@MainActor
struct NetworkPresentationTests {
    @Test func networkColumnsAreDefaultAfterWriteAndSortByCombinedRateWithMissingLast() async throws {
        let fixture = try UITestingFixture()
        let prefs = try fixture.preferences()
        defer { fixture.cleanUp() }
        let model = try MonitorViewModel(service: fixture, preferences: prefs)
        await model.setVisibility(window: true, menuBar: false)
        #expect(ProcessColumn.network.sort == .network)
        #expect(ProcessColumn.network.numeric)
        #expect(prefs.visible(.network))
        let columns = ProcessColumn.allCases
        #expect(try columns[#require(columns.firstIndex(of: .writeRate)) + 1] == .network)
        #expect(ProcessColumn.network.tooltip == "TCP/UDP bytes per second attributed by macOS (own processes). Unavailable shows —, never 0.")
        for column in [ProcessColumn.receivedBytes, .sentBytes] {
            #expect(!prefs.visible(column) && column.numeric && column.sort == nil)
            prefs.setVisible(true, column: column)
            #expect(prefs.visible(column))
        }
        let source = ProcessTableDataSource(model: model)
        let table = NSTableView()
        for ascending in [true, false] {
            table.sortDescriptors = [NSSortDescriptor(key: "network", ascending: ascending)]
            source.tableView(table, sortDescriptorsDidChange: [])
            #expect(model.query.sort == .network)
            #expect(model.query.order == (ascending ? .asc : .desc))
            await model.tick()
            let values = model.rows.compactMap { process -> Double? in
                guard let receive = process.networkReceiveBps.value, let send = process.networkSendBps.value else { return nil }
                return receive + send
            }
            #expect(values == values.sorted(by: ascending ? (<) : (>)))
            #expect(model.rows.suffix(3).allSatisfy { $0.networkReceiveBps.value == nil })
        }
        let alpha = try #require(model.rows.first { $0.pid == 4100 })
        #expect(ProcessColumn.network.text(for: alpha) == MetricText(text: "↓ 1.2 MB/s ↑ 340 KB/s", reason: nil))
        #expect(ProcessColumn.receivedBytes.text(for: alpha).text == "12.0 MB")
        #expect(ProcessColumn.sentBytes.text(for: alpha).text == "3.4 MB")
        for (pid, reason) in [(4117, "warming_up"), (4118, "permission_denied"), (4119, "permission_denied")] {
            let index = try #require(model.rows.firstIndex { $0.pid == pid })
            #expect(source.cellText(row: index, column: .network) == MetricText(text: "↓ — ↑ —", reason: "Receive: \(reason); Send: \(reason)"))
        }
    }

    @Test func networkColumnFitsDefaultWindowAndCumulativeColumnsStartHidden() async throws {
        _ = NSApplication.shared
        let fixture = try UITestingFixture()
        let prefs = try fixture.preferences()
        defer { fixture.cleanUp() }
        let model = try MonitorViewModel(service: fixture, preferences: prefs)
        let controller = MainWindowController(model: model)
        defer { controller.window?.close() }
        await model.setVisibility(window: true, menuBar: false)
        controller.render()
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        controller.splitController.splitView.adjustSubviews()
        controller.processScroll.tile()
        let index = controller.table.column(withIdentifier: NSUserInterfaceItemIdentifier("network"))
        #expect(index >= 0)
        #expect(controller.table.rect(ofColumn: index).maxX <= controller.processScroll.contentView.bounds.width)
        for column in [ProcessColumn.receivedBytes, .sentBytes] {
            #expect(controller.table.tableColumns.first { $0.identifier.rawValue == column.rawValue }?.isHidden == true)
        }
    }

    @Test func networkSummaryAndFixtureHistoryKeepSystemAndProcessRatesSeparate() async throws {
        let fixture = try UITestingFixture()
        defer { fixture.cleanUp() }
        let snapshot = try await fixture.snapshot(top: 20, sort: .network)
        #expect(SummaryCard.visible(in: snapshot.header).count == 7)
        #expect(SummaryCard.network.title == "Network")
        #expect(SummaryCard.network.chart == .systemNetwork)
        #expect(SummaryCard.network.value(snapshot.header) == "↓ 12.4 MB/s")
        #expect(SummaryCard.network.caption(snapshot.header) == "↑ 1.2 MB/s")
        let system = try #require(await fixture.history(HistoryRequest(series: ["system"])).first)
        #expect(system.points.last?.networkReceiveBps == snapshot.system.networkReceiveBps)
        #expect(system.points.last?.networkSendBps == snapshot.system.networkSendBps)
        for process in snapshot.processes {
            let history = try #require(await fixture.history(HistoryRequest(series: [process.processKey.rawValue])).first)
            #expect(history.points.last?.networkReceiveBps == process.networkReceiveBps)
            #expect(history.points.last?.networkSendBps == process.networkSendBps)
        }
        var header = snapshot.header
        header.system.networkReceiveBps = .permissionDenied
        header.system.networkSendBps = .warmingUp
        #expect(SummaryCard.network.value(header) == "↓ —")
        #expect(SummaryCard.network.caption(header) == "↑ —")
        header.status = .unavailable
        #expect(SummaryCard.network.value(header) == "—")
        #expect(SummaryCard.network.caption(header) == "Unavailable")
    }

    @Test func networkChartsShareCursorAndSplitBothDirectionsAtMissingValuesAndGaps() {
        let points = [0.0, 5, 10, 15, 20].map {
            HistoryPoint(t: Date(timeIntervalSince1970: $0), cpuPercent: .ok(25),
                         networkReceiveBps: $0 == 5 ? .warmingUp : .ok(1_200_000),
                         networkSendBps: $0 == 5 ? .permissionDenied : .ok(340_000))
        }
        let series = HistorySeries(series: "system", points: points, gaps: [HistoryGap(from: points[3].t, to: points[4].t)])
        let selection = ChartSelection()
        selection.move(to: points[2].t, from: .network)
        for kind in [HistoryChartKind.systemNetwork, .network] {
            #expect(kind.seriesLabels == ["Receive", "Send"])
            #expect(kind.hoverReadout(series: series, time: selection.time, hovered: false) == "Receive: 1.2 MB/s, Send: 340 KB/s")
            #expect(kind.hoverReadout(series: series, time: selection.time, hovered: true)?.hasSuffix(" · Receive: 1.2 MB/s, Send: 340 KB/s") == true)
            #expect(kind.values(at: points[1]) == "Receive: — (warming_up), Send: — (permission_denied)")
            #expect(kind.values(at: HistoryPoint(t: points[0].t, cpuPercent: .ok(0))) == "Receive: No history, Send: No history")
            #expect(kind.hoverReadout(series: series, time: points[3].t, hovered: false) == nil)
            for field in kind.fields {
                #expect(ChartGeometry.segments(series, value: field).map(\.count) == [1, 1, 1])
            }
        }
        #expect(HistoryChartKind.systemNetwork.identifier == "systemNetworkChart")
        #expect(HistoryChartKind.network.identifier == "processNetworkChart")
        selection.clear(from: .systemNetwork)
        #expect(selection.time != nil)
        selection.clear(from: .network)
        #expect(selection.time == nil)
    }
}
