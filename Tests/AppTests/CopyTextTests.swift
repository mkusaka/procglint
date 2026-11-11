import AppKit
@testable import ProcglintApp
import ProcglintCore
import Testing

struct CopyTextTests {
    @MainActor
    @Test(arguments: [ProcessFilter.all, .mine, .pinned])
    func listUsesFilteredSortedRowsAndVisibleColumns(filter: ProcessFilter) async throws {
        let fixture = try UITestingFixture()
        defer { fixture.cleanUp() }
        let prefs = try fixture.preferences()
        let model = try MonitorViewModel(service: fixture, preferences: prefs)
        let alpha = try ProcessKey("p1.boot-ui.4100.10")
        try await fixture.pin(key: alpha, pinned: true)
        model.setFilter(filter)
        model.setSearch("Worker")
        model.setSort(column: .name, ascending: true)
        await model.setVisibility(window: true, menuBar: false)
        let columns: [ProcessColumn] = [.name, .pid, .cpuTime, .readRate, .network]
        // A pending sort request must not relabel rows that still show the previous query.
        model.setSort(column: .cpu, ascending: false)
        let text = try CopyText.list(rows: model.rows, columns: columns, header: model.header, totalMatched: model.totalMatched, query: #require(model.displayedQuery))
        let count = filter == .all ? 19 : (filter == .mine ? 18 : 1)
        #expect(text.contains("\(count) of \(count) processes · sorted by Name asc"))
        #expect(text.contains("| Name | PID | CPU time | Read/s | Network |\n|---|---:|---:|---:|---:|"))
        #expect(!text.contains("| Power |") && !text.contains("Fixture Terminal"))
        let tableRows = text.components(separatedBy: "\n").dropFirst(5)
        #expect(Array(tableRows) == model.rows.map { row in "| " + columns.map { $0.text(for: row).text }.joined(separator: " | ") + " |" })
        #expect(text.contains("Other User Worker") == (filter == .all))
        if filter != .pinned {
            #expect(text.contains("| Warming Worker | 4117 | 18.0 s | — | ↓ — ↑ — |"))
        }
    }

    @Test func listEscapesPipesAndKeepsUnavailableCellsAndSelectionOrder() throws {
        var first = try sample(cpu: .warmingUp)
        first.name = "Alpha | Worker"
        var second = try sample(pid: 43, key: "p1.boot-a.43.10")
        second.name = "Hidden Worker"
        var third = try sample(pid: 44, key: "p1.boot-a.44.10", cpu: .permissionDenied)
        third.name = "Last Worker"
        let rows = [first, second, third]
        let query = try ProcessQuery(filter: .pinned, sort: .cpu, order: .desc)
        let text = CopyText.list(rows: rows, columns: [.name, .cpu, .writtenBytes], header: snapshot(rows).header,
                                 totalMatched: 763, query: query, selectedRows: IndexSet([2, 0]))
        #expect(text.contains("2 of 763 processes · sorted by CPU desc"))
        #expect(text.hasSuffix("| Name | CPU | Written total |\n|---|---:|---:|\n| Alpha \\| Worker | — | — |\n| Last Worker | — | — |"))
        #expect(!text.contains("Hidden Worker") && !text.contains("0.0%"))
        let all = CopyText.list(rows: rows, columns: [.name], header: snapshot(rows).header, totalMatched: 763, query: query)
        #expect(all.contains("3 of 763 processes") && all.contains("Hidden Worker"))
        let empty = CopyText.list(rows: [], columns: [.name], header: nil, totalMatched: 0, query: query)
        #expect(empty.contains("0 of 0 processes") && empty.hasSuffix("| Name |\n|---|"))
    }

    @MainActor
    @Test(arguments: [UITestingFixture.BatteryState.none, .charging])
    func systemSummaryIncludesBatteryOnlyWhenPresent(battery: UITestingFixture.BatteryState) async throws {
        let fixture = try UITestingFixture(battery: battery)
        defer { fixture.cleanUp() }
        let snapshot = try await fixture.snapshot(top: 20, sort: .cpu)
        let text = try CopyText.list(rows: snapshot.processes, columns: [.name], header: snapshot.header,
                                     totalMatched: 20, query: ProcessQuery())
        #expect(text.contains("System: CPU 25.0% · Memory 4 GB of 8 GB · Pressure Normal 39% · Swap 1 GB · Compressed 512 MB · Network ↓ 12.4 MB/s ↑ 1.2 MB/s"))
        #expect(text.contains("Battery") == (battery != .none))
        if battery == .charging {
            #expect(text.contains("Battery 69% Charging · 1:53 to full"))
        }
    }

    @Test(arguments: [false, true])
    func detailsCopyExactlyDisplayedRedactedStringsOnlyWhenEnabled(enabled: Bool) throws {
        var process = try sample()
        process.path = "/fixture/worker"
        process.networkReceiveBps = .ok(1_200_000)
        process.networkSendBps = .permissionDenied
        process.networkReceivedBytes = .ok(12_000_000)
        process.networkSentBytes = .permissionDenied
        process.commandLine = ProcessCommandLine(arguments: ["node", "server.js", "--token", "test-secret"])
        process.cwd = WorkingDirectory(value: "/fixture/project")
        process.ancestors = [ProcessAncestor(pid: 43, name: "Terminal", commandLine: ProcessCommandLine(arguments: ["shell", "--auth=test-secret"])),
                             ProcessAncestor(pid: 1, name: "launchd", commandLine: ProcessCommandLine(unavailable: .permissionDenied))]
        process.childrenCount = 2
        process.ancestorsIncomplete = true
        let permissions: PermissionSet = enabled ? [.includePaths, .includeCommandLines] : [.includePaths]
        let text = CopyText.details(process: process, permissions: permissions, history: nil, window: Date.distantPast ... Date.distantFuture)
        #expect(text.contains(Display.identity(process)))
        #expect(text.contains("```\nPath: /fixture/worker\n```"))
        #expect(text.contains("## Current metrics"))
        for column in ProcessColumn.allCases {
            #expect(text.contains("| \(column.title) | \(column.text(for: process).text)"))
        }
        #expect(text.contains("| Read/s | — (warming_up) |"))
        #expect(text.contains("| Written total | — (permission_denied) |"))
        #expect(text.contains("| Network | ↓ 1.2 MB/s ↑ — (Send: permission_denied) |"))
        #expect(text.contains("| Received | 12.0 MB |"))
        #expect(text.contains("| Sent | — (permission_denied) |"))
        #expect(text.contains("- launchd (1)\n\n") && text.contains("- Terminal (43)"))
        #expect(try #require(text.range(of: "- launchd (1)")).lowerBound < #require(text.range(of: "- Terminal (43)")).lowerBound)
        #expect(text.contains("Direct children: 2 · Parent chain incomplete"))
        #expect(!text.contains("test-secret") && !text.contains("## History"))
        #expect(text.contains("server.js") == enabled)
        #expect(text.contains("shell --auth") == enabled)
        #expect(text.contains("/fixture/project") == enabled)
        #expect(text.contains("## Command line") == enabled)
        #expect(text.contains("## Working directory") == enabled)
        if enabled {
            #expect(text.contains("```\nCommand: node server.js --token <redacted>\n```"))
            #expect(text.contains("```\nshell --auth=<redacted>\n```"))
            #expect(text.contains("```\n— (permission_denied)\n```"))
            #expect(text.contains("```\nWorking directory: /fixture/project\n```"))
        }
    }

    @Test func detailsKeepUnavailableReasonsAndFenceProcessProvidedBackticks() throws {
        var process = try sample()
        process.path = "/fixture/```/worker"
        process.commandLine = ProcessCommandLine(unavailable: .exited)
        process.cwd = WorkingDirectory(unavailable: .permissionDenied)
        let text = CopyText.details(process: process, permissions: [.includePaths, .includeCommandLines], history: nil,
                                    window: Date.distantPast ... Date.distantFuture)
        #expect(text.contains("````\nPath: /fixture/```/worker\n````"))
        #expect(text.contains("Command: — (exited)") && text.contains("Working directory: — (permission_denied)"))
        let hidden = CopyText.details(process: process, permissions: [], history: nil, window: Date.distantPast ... Date.distantFuture)
        #expect(hidden.contains("Path: — (permission_denied; enable include_paths in Settings)"))
        #expect(!hidden.contains("/fixture/") && !hidden.contains("Command:"))
    }

    @MainActor
    @Test func newlySelectedUnpinnedProcessImmediatelyCopiesItsPastHistory() async throws {
        let fixture = try UITestingFixture()
        defer { fixture.cleanUp() }
        let model = try MonitorViewModel(service: fixture, preferences: fixture.preferences())
        await model.setVisibility(window: true, menuBar: false)
        let key = try ProcessKey("p1.boot-ui.4116.10")
        let process = try #require(model.rows.first { $0.pid == 4116 })
        #expect(process.processKey == key)
        model.select(key)
        await model.refreshInspector()
        #expect(!model.pinned)
        let history = try #require(model.history)
        #expect(history.points.count == 121)
        #expect(try #require(history.points.first).t < #require(model.header).sampledAt)
        let text = CopyText.details(process: process, permissions: model.permissions, history: history,
                                    window: Date.distantPast ... Date.distantFuture)
        #expect(text.contains("CPU history, percent"))
        #expect(text.contains("Memory (footprint) history, bytes"))
        #expect(text.contains("Network history, bytes per second"))
    }

    @Test func historySummariesUseOnlyShownWindowAndExcludeGapsAndMissingValues() throws {
        let process = try sample()
        let points: [(Double, Metric)] = [(0, .ok(999)), (10, .ok(10)), (20, .ok(900)), (30, .ok(30)), (40, .warmingUp), (50, .ok(999))]
        let history = HistorySeries(series: process.processKey.rawValue, points: points.map { time, cpu in
            HistoryPoint(t: Date(timeIntervalSince1970: time), cpuPercent: cpu, footprintBytes: .ok(2048),
                         diskReadBps: .ok(1024), diskWriteBps: .permissionDenied, powerMW: .ok(2000),
                         networkReceiveBps: cpu.value.map { .ok($0 * 1000) } ?? cpu, networkSendBps: .permissionDenied)
        }, gaps: [HistoryGap(from: Date(timeIntervalSince1970: 19), to: Date(timeIntervalSince1970: 21))])
        let text = CopyText.details(process: process, permissions: [], history: history,
                                    window: Date(timeIntervalSince1970: 10) ... Date(timeIntervalSince1970: 40))
        #expect(text.contains("CPU history, percent (one core = 100%): min 10.0% · max 30.0% · latest — (warming_up)"))
        #expect(text.contains("Memory (footprint) history, bytes: min 2.0 KiB · max 2.0 KiB · latest 2.0 KiB"))
        #expect(text.contains("Read: min 1.0 KiB/s · max 1.0 KiB/s · latest 1.0 KiB/s; Write: min — · max — · latest — (permission_denied)"))
        #expect(text.contains("Process power history, watts (OS-attributed): min 2.0 W · max 2.0 W · latest 2.0 W"))
        #expect(text.contains("Network history, bytes per second: Receive: min 10.0 KB/s · max 30.0 KB/s · latest — (warming_up); Send: min — · max — · latest — (permission_denied)"))
        #expect(!text.contains("999.0%") && !text.contains("900.0%") && !text.contains("999 KB/s") && !text.contains("900 KB/s"))
    }

    @MainActor
    @Test func multipleSelectionSurvivesRefreshAndSortAndCopyReachesWindowController() async throws {
        _ = NSApplication.shared
        let prefs = preferences()
        defer { prefs.defaults.removePersistentDomain(forName: prefs.store.suiteName ?? "") }
        let rows = try [sample(), sample(pid: 43, key: "p1.boot-a.43.10"), sample(pid: 44, key: "p1.boot-a.44.10")]
        let model = try MonitorViewModel(service: FakeMonitorService(rows: rows), preferences: prefs)
        let controller = MainWindowController(model: model)
        defer { controller.window?.close() }
        model.apply(ProcessPage(snapshot: snapshot(rows).header, items: rows, totalMatched: 3))
        controller.render()
        controller.table.selectRowIndexes(IndexSet([0, 2]), byExtendingSelection: false)
        controller.dataSource.tableViewSelectionDidChange(Notification(name: NSTableView.selectionDidChangeNotification, object: controller.table))
        controller.render()
        #expect(controller.table.selectedRowIndexes == IndexSet([0, 2]))
        model.apply(ProcessPage(snapshot: snapshot(rows).header, items: [rows[1], rows[2], rows[0]], totalMatched: 3))
        controller.render()
        #expect(controller.table.selectedRowIndexes == IndexSet([1, 2]))
        let window = try #require(controller.window)
        #expect(window.makeFirstResponder(controller.table))
        #expect(window.nextResponder as? MainWindowController === controller)
        #expect(controller.responds(to: #selector(NSText.copy(_:))))
        let copy = NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        #expect(controller.validateUserInterfaceItem(copy))
        controller.table.isHidden = true
        #expect(!controller.validateUserInterfaceItem(copy))
        controller.table.isHidden = false
        controller.table.deselectAll(nil)
        #expect(!controller.validateUserInterfaceItem(copy))
        await model.selectionUpdate?.value
    }
}
