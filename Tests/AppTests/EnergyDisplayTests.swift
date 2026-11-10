import AppKit
@testable import ProcglintApp
import ProcglintCore
import Testing

@Test(arguments: [(0.0, "0 mW"), (12, "12 mW"), (999, "999 mW"), (1000, "1.00 W"), (1030, "1.03 W"), (33100, "33.10 W"), (-1, "—"), (.infinity, "—"), (.nan, "—")])
func powerFormatting(milliwatts: Double, expected: String) {
    #expect(Display.power(milliwatts) == expected)
}

@Test(arguments: [(0.0, "0:00"), (9, "0:09"), (59, "0:59"), (60, "1:00"), (113, "1:53"), (190, "3:10"), (65534, "1092:14"), (65535, "—"), (-1, "—"), (.infinity, "—"), (.nan, "—")])
func batteryTimeFormatting(minutes: Double, expected: String) {
    #expect(Display.batteryTime(minutes) == expected)
}

@Test(arguments: [(0.0, "battery.0"), (12.49, "battery.0"), (12.5, "battery.25"), (37.5, "battery.50"), (62.5, "battery.75"), (69, "battery.75"), (87.5, "battery.100"), (100, "battery.100")])
func batteryLevelSymbols(percent: Double, symbol: String) {
    #expect(BatteryDisplay(battery: BatteryMetrics(percent: .ok(percent))).symbol == symbol)
    #expect(NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil)
}

@MainActor
struct EnergyPresentationTests {
    @Test func batteryStatesKeepSystemPowerSeparateFromDrainAndUnknowns() throws {
        let charging = try BatteryDisplay(battery: #require(UITestingFixture.BatteryState.charging.metrics))
        #expect(charging.battery.isCharging == true)
        #expect(charging.symbol == "battery.75")
        #expect(charging.caption == "Charging · 1:53 to full")
        #expect(charging.power == "Using 33.1 W")
        #expect(charging.tooltip.contains("Health 100% · 5 cycles"))
        let discharging = try BatteryDisplay(battery: #require(UITestingFixture.BatteryState.discharging.metrics))
        #expect(discharging.battery.isCharging == false)
        #expect(discharging.caption == "On battery · 3:10 left")
        #expect(discharging.power == "Using 33.1 W\nDraining 12.4 W")
        #expect(try BatteryDisplay(battery: #require(UITestingFixture.BatteryState.charged.metrics)).caption == "Fully charged")
        let unknown = BatteryDisplay(battery: BatteryMetrics())
        #expect(unknown.caption == "Battery state unavailable")
        #expect(unknown.symbol == "battery.0")
        #expect(unknown.power == "Using — (unsupported)")
        #expect(unknown.tooltip.contains("Time remaining: — (unsupported)"))
        var battery = charging.battery
        battery.timeRemainingMinutes = .unsupported
        #expect(BatteryDisplay(battery: battery).caption == "Charging")
        battery.isCharging = false
        #expect(BatteryDisplay(battery: battery).caption == "On power adapter")
        battery.externalPower = false
        battery.systemPowerMW = .permissionDenied
        battery.batteryPowerMW = .unsupported
        #expect(BatteryDisplay(battery: battery).caption == "On battery")
        #expect(BatteryDisplay(battery: battery).power == "Using — (permission_denied)")
        battery.percent = .ok(100)
        #expect(BatteryDisplay(battery: battery).caption != "Fully charged")
    }

    @Test func fixtureVariantsControlCardVisibilityAndHistory() async throws {
        #expect(!SummaryCard.visible(in: nil).contains(.battery))
        for state in UITestingFixture.BatteryState.allCases {
            let fixture = try UITestingFixture(battery: state)
            defer { fixture.cleanUp() }
            let snapshot = try await fixture.snapshot(top: 20, sort: .power)
            #expect(SummaryCard.visible(in: snapshot.header).contains(.battery) == (state != .none))
            #expect(snapshot.system.battery == state.metrics)
            let system = try #require(await fixture.history(HistoryRequest(series: ["system"])).first)
            #expect(system.points.last?.systemPowerMW == state.metrics?.systemPowerMW)
            #expect(system.points.last?.batteryPercent == state.metrics?.percent)
            #expect(system.points.allSatisfy { $0.powerMW == nil })
            let process = try #require(snapshot.processes.first { $0.pid == 4100 })
            let history = try #require(await fixture.history(HistoryRequest(series: [process.processKey.rawValue])).first)
            #expect(history.points.last?.powerMW == process.powerMW)
            #expect(history.points.allSatisfy { $0.systemPowerMW == nil && $0.batteryPercent == nil })
        }
    }

    @Test func powerColumnIsDefaultAfterCPUAndMapsSortThroughTableDelegate() async throws {
        let fixture = try UITestingFixture()
        let prefs = try fixture.preferences()
        defer { fixture.cleanUp() }
        let model = try MonitorViewModel(service: fixture, preferences: prefs)
        await model.setVisibility(window: true, menuBar: false)
        #expect(ProcessColumn.power.sort == .power)
        #expect(ProcessColumn.power.numeric)
        #expect(prefs.visible(.power))
        let columns = ProcessColumn.allCases
        #expect(try columns[#require(columns.firstIndex(of: .cpu)) + 1] == .power)
        #expect(ProcessColumn.power.tooltip == "OS-attributed average power of this process (own processes only). Not Activity Monitor's Energy Impact.")
        let source = ProcessTableDataSource(model: model)
        let table = NSTableView()
        for ascending in [true, false] {
            table.sortDescriptors = [NSSortDescriptor(key: "power", ascending: ascending)]
            source.tableView(table, sortDescriptorsDidChange: [])
            #expect(model.query.sort == .power)
            #expect(model.query.order == (ascending ? .asc : .desc))
            await model.tick()
            let values = model.rows.compactMap(\.powerMW.value)
            #expect(values == values.sorted(by: ascending ? (<) : (>)))
        }
        for (pid, text, reason) in [(4100, "1.03 W", nil), (4101, "12 mW", nil), (4117, "—", "warming_up"), (4118, "—", "permission_denied"), (4119, "—", "permission_denied")] {
            let row = try #require(model.rows.firstIndex { $0.pid == pid })
            #expect(source.cellText(row: row, column: .power) == MetricText(text: text, reason: reason))
        }
    }

    @Test func powerChartsUseWattsSharedCursorAndDoNotBridgeMissingValuesOrGaps() throws {
        let points = [0.0, 5, 10, 15, 20].map {
            HistoryPoint(t: Date(timeIntervalSince1970: $0), cpuPercent: .ok(25),
                         systemPowerMW: .ok(33100), powerMW: $0 == 5 ? .warmingUp : .ok(1030))
        }
        let series = HistorySeries(series: "system", points: points,
                                   gaps: [HistoryGap(from: points[3].t, to: points[4].t)])
        let selection = ChartSelection()
        selection.move(to: points[2].t, from: .power)
        #expect(HistoryChartKind.systemPower.hoverReadout(series: series, time: selection.time, hovered: false) == "33.1 W")
        #expect(HistoryChartKind.power.hoverReadout(series: series, time: selection.time, hovered: true)?.hasSuffix(" · 1.0 W") == true)
        #expect(HistoryChartKind.power.values(at: points[1]) == "— (warming_up)")
        #expect(HistoryChartKind.power.values(at: HistoryPoint(t: points[0].t, cpuPercent: .ok(0))) == "No history")
        #expect(HistoryChartKind.systemPower.hoverReadout(series: series, time: points[3].t, hovered: false) == nil)
        let field = try #require(HistoryChartKind.power.fields.first)
        #expect(ChartGeometry.segments(series, value: field).map(\.count) == [1, 1, 1])
        selection.clear(from: .systemPower)
        #expect(selection.time != nil)
        selection.clear(from: .power)
        #expect(selection.time == nil)
    }
}
