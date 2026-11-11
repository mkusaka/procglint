import AppKit
import func Observation.withObservationTracking
@testable import ProcglintApp
import ProcglintCore
import Synchronization
import Testing

@MainActor
private final class ScrollSpyTable: NSTableView {
    var scrolledRows: [Int] = []
    override func scrollRowToVisible(_ row: Int) {
        scrolledRows.append(row)
    }
}

@MainActor
struct ModernPresentationTests {
    @Test func cardsFormatViewModelMetricsWithoutSubstitutingMissingValues() async throws {
        let fixture = try UITestingFixture()
        let prefs = try fixture.preferences()
        defer { fixture.cleanUp() }
        let model = try MonitorViewModel(service: fixture, preferences: prefs)
        await model.setVisibility(window: true, menuBar: false)
        #expect(SummaryCard.allCases.map { $0.value(model.header) } == ["25.0%", "4 GB", "39%", "1 GB", "512 MB", "↓ 12.4 MB/s", "69%"])
        #expect(SummaryCard.allCases.map { $0.caption(model.header) } == ["Across all cores", "of 8 GB", "Normal", "On disk", "In memory", "↑ 1.2 MB/s", "Charging · 1:53 to full"])
        var header = try #require(model.header)
        header.system.cpuPercent = .warmingUp
        header.system.swapUsedBytes = .permissionDenied
        header.system.memoryPressure = .unsupported
        header.system.memoryPressurePercent = .unsupported
        #expect(SummaryCard.cpu.value(header) == "—")
        #expect(SummaryCard.cpu.caption(header) == "warming_up")
        #expect(SummaryCard.swap.value(header) == "—")
        #expect(SummaryCard.swap.caption(header) == "permission_denied")
        #expect(SummaryCard.pressure.value(header) == "—")
        #expect(SummaryCard.pressure.caption(header) == "Unavailable")
        header.status = .unavailable
        #expect(SummaryCard.allCases.allSatisfy { $0.value(header) == "—" })
        #expect(SummaryCard.allCases.allSatisfy { $0.value(nil) == "—" })
    }

    @Test func tableRefreshDoesNotInvalidateHeaderHistoryOrInspectorState() throws {
        let prefs = preferences()
        defer { prefs.defaults.removePersistentDomain(forName: prefs.store.suiteName ?? "") }
        let process = try sample()
        let model = try MonitorViewModel(service: FakeMonitorService(), preferences: prefs)
        let page = ProcessPage(snapshot: snapshot().header, items: [process], totalMatched: 1)
        model.apply(page)
        model.select(process.processKey)
        let changes = Mutex(0)
        withObservationTracking {
            _ = model.header
            _ = model.systemHistory
            _ = model.history
            _ = model.identityText
        } onChange: {
            changes.withLock { $0 += 1 }
        }
        var more = page
        try more.items.append(sample(pid: 43, key: "p1.boot-a.43.20"))
        model.apply(more, append: true)
        #expect(changes.withLock { $0 } == 0)
    }

    @Test func supplementalSparklinesAreBoundedAndBreakOnHidingAndMissingValues() async throws {
        let prefs = preferences()
        defer { prefs.defaults.removePersistentDomain(forName: prefs.store.suiteName ?? "") }
        let service = try FakeMonitorService()
        let model = try MonitorViewModel(service: service, preferences: prefs)
        await model.setVisibility(window: true, menuBar: false)
        #expect(!HistoryChart(model: model, kind: .swap).hasTrend)
        #expect(!HistoryChart(model: model, kind: .compressed).hasTrend)
        for index in 1 ... 605 {
            service.current.sampledAt = Date(timeIntervalSince1970: 100 + Double(index))
            service.current.snapshotID = "sample-\(index + 1)"
            service.current.system.swapUsedBytes = index == 604 ? .permissionDenied : .ok(Double(index))
            model.apply(ProcessPage(snapshot: service.current.header, items: [], totalMatched: 0))
        }
        #expect(model.memorySummaryHistory.count == 600)
        #expect(HistoryChart(model: model, kind: .swap).hasTrend)
        #expect(HistoryChart(model: model, kind: .compressed).hasTrend)
        #expect(ChartGeometry.memorySegments(model.memorySummaryHistory, value: { $0.swap }).map(\.count) == [598, 1])
        let count = model.memorySummaryHistory.count
        model.apply(ProcessPage(snapshot: service.current.header, items: [], totalMatched: 0))
        #expect(model.memorySummaryHistory.count == count)
        await model.setVisibility(window: false, menuBar: false)
        service.current.snapshotID = "after-hide"
        service.current.sampledAt = Date(timeIntervalSince1970: 710)
        await model.setVisibility(window: true, menuBar: false)
        #expect(model.memorySummaryHistory.last?.startsSegment == true)
        #expect(ChartGeometry.memorySegments(model.memorySummaryHistory, value: { $0.compressed }).count == 2)
        #expect(ChartGeometry.nearestMemoryPoint(in: model.memorySummaryHistory, to: Date(timeIntervalSince1970: 707)) == nil)
        #expect(ChartGeometry.nearestMemoryPoint(in: model.memorySummaryHistory, to: Date(timeIntervalSince1970: 710))?.time == Date(timeIntervalSince1970: 710))
        #expect(ChartGeometry.nearestMemoryPoint(in: [], to: Date()) == nil)
        service.current.agentInstanceID = "agent-b"
        service.current.snapshotID = "restart"
        service.current.sampledAt = Date(timeIntervalSince1970: 720)
        await model.tick()
        #expect(model.memorySummaryHistory.count == 1)
    }

    @Test func chartDomainRemainsTheWholeRetainedWindowForSparseHistory() {
        let end = Date(timeIntervalSince1970: 1000)
        #expect(ChartGeometry.historyWindow(endingAt: end, minutes: 10) == Date(timeIntervalSince1970: 400) ... end)
        #expect(ChartGeometry.historyWindow(endingAt: end, minutes: 1) == Date(timeIntervalSince1970: 940) ... end)
        #expect(ChartGeometry.historyWindow(endingAt: nil, minutes: 1).upperBound == Date(timeIntervalSince1970: 0))
    }

    @Test func supplementalSparklinesAlsoHonorAgentSleepGaps() {
        let samples = [0.0, 10, 20].map {
            MemorySummaryPoint(time: Date(timeIntervalSince1970: $0), swap: .ok($0), compressed: .ok($0), startsSegment: false)
        }
        let gaps = [HistoryGap(from: Date(timeIntervalSince1970: 5), to: Date(timeIntervalSince1970: 15))]
        #expect(ChartGeometry.memorySegments(samples, gaps: gaps, value: { $0.swap }).map(\.count) == [1, 1])
        #expect(ChartGeometry.nearestMemoryPoint(in: samples, to: Date(timeIntervalSince1970: 9), gaps: gaps) == nil)
        #expect(ChartGeometry.nearestMemoryPoint(in: samples, to: Date(timeIntervalSince1970: 16), gaps: gaps)?.time == samples[2].time)
    }

    @Test func refreshPreservesViewportButAncestorSelectionScrollsIntoView() throws {
        let prefs = preferences()
        defer { prefs.defaults.removePersistentDomain(forName: prefs.store.suiteName ?? "") }
        let first = try sample()
        let second = try sample(pid: 43, key: "p1.boot-a.43.20")
        let model = try MonitorViewModel(service: FakeMonitorService(), preferences: prefs)
        model.apply(ProcessPage(snapshot: snapshot().header, items: [first, second], totalMatched: 2))
        model.select(first.processKey)
        let source = ProcessTableDataSource(model: model)
        let table = ScrollSpyTable()
        table.dataSource = source
        table.delegate = source
        source.reload(table)
        #expect(table.selectedRow == 0)
        #expect(table.scrolledRows.isEmpty)
        model.select(second.processKey)
        source.restoreSelection(table)
        #expect(table.selectedRow == 1)
        #expect(table.scrolledRows == [1])
    }

    @Test func numericCellsUseAlignedMonospacedDigits() async throws {
        let prefs = preferences()
        defer { prefs.defaults.removePersistentDomain(forName: prefs.store.suiteName ?? "") }
        let model = try MonitorViewModel(service: FakeMonitorService(rows: [sample()]), preferences: prefs)
        await model.setVisibility(window: true, menuBar: false)
        let source = ProcessTableDataSource(model: model)
        for column in ProcessColumn.allCases {
            let item = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.rawValue))
            let cell = try #require(source.tableView(NSTableView(), viewFor: item, row: 0) as? NSTableCellView)
            #expect(cell.textField?.alignment == (column.numeric ? .right : .left))
            if column.numeric {
                #expect(cell.textField?.font == NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular))
            }
        }
    }
}
