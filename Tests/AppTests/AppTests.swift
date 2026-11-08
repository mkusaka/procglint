import AppKit
@testable import ProcglintApp
import ProcglintCore
import Testing

@MainActor
func preferences() -> AppPreferences {
    AppPreferences(suiteName: "procglint-app-tests-" + UUID().uuidString)
}

@MainActor
@Test func metricFormattingAndReasons() throws {
    #expect(Display.bytes(0) == "0 B")
    #expect(Display.bytes(1024) == "1.0 KiB")
    #expect(Display.bytes(1_073_741_824) == "1.0 GiB")
    #expect(Display.bytes(.infinity) == "—")
    #expect(Display.percent(212.34) == "212.3%")
    for metric in [Metric.warmingUp, .permissionDenied, .exited, .stale, .unsupported] {
        #expect(Display.metric(metric, format: Display.percent) == MetricText(text: "—", reason: metric.status.rawValue))
    }
    let process = try sample()
    #expect(ProcessColumn.cpuTime.text(for: process).text == "2.0 s")
    #expect(ProcessColumn.footprint.text(for: process).text == "2.0 KiB")
    #expect(ProcessColumn.readRate.text(for: process).reason == "warming_up")
    #expect(ProcessColumn.writtenBytes.text(for: process).reason == "permission_denied")
    #expect(Display.summary(snapshot(status: .warmingUp).header).contains("CPU — (warming_up)"))
    #expect(Display.summary(snapshot(status: .stale).header).contains("stale"))
    #expect(Display.summary(snapshot(status: .unavailable).header).contains("Memory —"))
}

@MainActor
@Test func tableUsesSnapshotAndRendersCellOnDemand() async throws {
    let prefs = preferences()
    defer { prefs.defaults.removePersistentDomain(forName: prefs.store.suiteName ?? "") }
    let service = try FakeMonitorService(rows: [sample()])
    let model = try MonitorViewModel(service: service, preferences: prefs)
    await model.setVisibility(window: true, menuBar: false)
    let source = ProcessTableDataSource(model: model)
    let table = NSTableView()
    #expect(source.numberOfRows(in: table) == 1)
    #expect(source.cellText(row: 0, column: .name)?.text == "worker")
    #expect(source.cellText(row: 0, column: .pid)?.text == "42")
    #expect(source.cellText(row: 1, column: .name) == nil)
    let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(ProcessColumn.readRate.rawValue))
    let cell = source.tableView(table, viewFor: column, row: 0) as? NSTableCellView
    #expect(cell?.textField?.stringValue == "—")
    #expect(cell?.textField?.toolTip == "warming_up")
    #expect(model.summary.contains("25.0%"))
    #expect(model.summary.contains("wired 1.0 KiB"))
}

@MainActor
@Test func selectionIsAnOpaqueKeyNotAPID() throws {
    let prefs = preferences()
    defer { prefs.defaults.removePersistentDomain(forName: prefs.store.suiteName ?? "") }
    let first = try sample()
    let other = try sample(pid: 43, key: "p1.boot-a.43.20")
    let service = try FakeMonitorService()
    let model = try MonitorViewModel(service: service, preferences: prefs)
    model.apply(ProcessPage(snapshot: snapshot().header, items: [first, other], totalMatched: 2))
    model.select(first.processKey)
    model.apply(ProcessPage(snapshot: snapshot(id: "sample-2").header, items: [other, first], totalMatched: 2))
    #expect(model.selectedKey == first.processKey)
    #expect(model.detail?.processKey == first.processKey)
    let reused = try sample(key: "p1.boot-a.42.30")
    model.apply(ProcessPage(snapshot: snapshot(id: "sample-3").header, items: [reused, other], totalMatched: 2))
    #expect(model.selectedKey == nil)
    #expect(model.detail == nil)
    model.select(reused.processKey)
    model.apply(ProcessPage(snapshot: snapshot(status: .unavailable).header, items: [], totalMatched: 0))
    #expect(model.selectedKey == reused.processKey)
    #expect(model.rows.count == 2)
}

@MainActor
@Test func unavailableSnapshotKeepsRowsAndSelectionUntilRecovery() async throws {
    let prefs = preferences()
    defer { prefs.defaults.removePersistentDomain(forName: prefs.store.suiteName ?? "") }
    let process = try sample()
    let service = try FakeMonitorService(rows: [process])
    let model = try MonitorViewModel(service: service, preferences: prefs)
    await model.setVisibility(window: true, menuBar: false)
    model.select(process.processKey)
    await model.selectionUpdate?.value
    let queries = service.queries.count
    service.current = snapshot(id: "failed", status: .unavailable)
    await model.tick()
    #expect(model.header?.status == .unavailable)
    #expect(model.summary.contains("unavailable"))
    #expect(model.message.contains("could not enumerate processes"))
    #expect(model.rows == [process])
    #expect(model.totalMatched == 1)
    #expect(model.selectedKey == process.processKey)
    #expect(model.detail?.processKey == process.processKey)
    #expect(service.queries.count == queries)
    service.current = snapshot(id: "recovered")
    await model.tick()
    await model.selectionUpdate?.value
    #expect(model.header?.status == .ok)
    #expect(model.message.isEmpty)
    #expect(model.rows.isEmpty)
    #expect(model.totalMatched == 0)
    #expect(model.selectedKey == nil)
}

@MainActor
@Test func queryMappingKeepsGUIFilterAndDoesNotFetchAllProcesses() async throws {
    let prefs = preferences()
    defer { prefs.defaults.removePersistentDomain(forName: prefs.store.suiteName ?? "") }
    let service = try FakeMonitorService()
    let model = try MonitorViewModel(service: service, preferences: prefs)
    #expect(model.query.filter == .all)
    model.setSearch("  42 \n")
    model.setFilter(.mine)
    model.setSort(column: .footprint, ascending: true)
    await model.setVisibility(window: true, menuBar: false)
    let expected = try ProcessQuery(search: "42", filter: .mine, sort: .footprint, order: .asc, limit: 200,
                                    fields: ProcessField.allCases.filter { $0 != .path })
    #expect(service.queries == [expected])
    #expect(service.snapshotCalls == 1)
    model.setSearch(" Worker ")
    model.setFilter(.pinned)
    model.setSort(column: .cpuTime, ascending: false)
    await model.tick()
    #expect(service.queries.last?.search == "Worker")
    #expect(service.queries.last?.filter == .pinned)
    #expect(service.queries.last?.sort == .cpuTime)
    #expect(service.queries.last?.order == .desc)
    model.setSearch("  ")
    #expect(model.query.search == nil)
}

@MainActor
@Test func visibilityAcquiresRenewsAndReleasesIndependentLeases() async throws {
    let prefs = preferences()
    defer { prefs.defaults.removePersistentDomain(forName: prefs.store.suiteName ?? "") }
    let service = try FakeMonitorService()
    let model = try MonitorViewModel(service: service, preferences: prefs)
    await model.setVisibility(window: false, menuBar: false)
    #expect(service.leaseRequests.isEmpty)
    #expect(service.snapshotCalls == 0)
    #expect(model.pollingInterval == nil)
    await model.setVisibility(window: true, menuBar: false)
    #expect(service.leaseRequests.last?.kind == .guiWindow)
    #expect(service.leaseRequests.last?.intervalMS == .fiveSeconds)
    #expect(model.pollingInterval == 5)
    await model.tick()
    #expect(service.leaseRequests.count == 2)
    await model.setVisibility(window: true, menuBar: true)
    #expect(service.leaseRequests.last?.kind == .menuBar)
    #expect(model.pollingInterval == 5)
    await model.setVisibility(window: false, menuBar: true)
    #expect(service.released == ["gui_window"])
    #expect(model.pollingInterval == 10)
    let lists = service.queries.count
    await model.tick()
    #expect(service.queries.count == lists)
    await model.setVisibility(window: false, menuBar: false)
    #expect(service.released == ["gui_window", "menu_bar"])
    #expect(model.pollingInterval == nil)
}

@MainActor
@Test func leasesRecoverAfterAgentRestartAndUnavailable() async throws {
    let prefs = preferences()
    defer { prefs.defaults.removePersistentDomain(forName: prefs.store.suiteName ?? "") }
    let service = try FakeMonitorService()
    let model = try MonitorViewModel(service: service, preferences: prefs)
    await model.setVisibility(window: true, menuBar: true)
    service.current = snapshot(instance: "agent-b")
    await model.tick()
    #expect(service.leaseRequests.count == 6)
    service.snapshotError = .agentUnavailable("disconnected")
    await model.tick()
    #expect(model.summary.contains("unavailable"))
    #expect(model.message.contains("register/enable"))
    service.snapshotError = nil
    let previous = service.leaseRequests.count
    await model.tick()
    #expect(service.leaseRequests.count == previous + 2)
    #expect(model.header?.agentInstanceID == "agent-b")
}

@MainActor
@Test func concurrentPollIsSkippedAndOcclusionDuringFetchReleasesLease() async throws {
    let prefs = preferences()
    defer { prefs.defaults.removePersistentDomain(forName: prefs.store.suiteName ?? "") }
    let service = try FakeMonitorService()
    let model = try MonitorViewModel(service: service, preferences: prefs)
    let gate = RequestGate()
    service.beforeSnapshot = { await gate.suspend() }
    let fetching = Task { await model.setVisibility(window: true, menuBar: false) }
    await gate.waitUntilEntered()
    await model.tick()
    await model.setVisibility(window: false, menuBar: false)
    #expect(service.snapshotCalls == 1)
    gate.resume()
    await fetching.value
    #expect(service.released == ["gui_window"])
    #expect(service.queries.isEmpty)
}

@MainActor
@Test func queryChangedInFlightDiscardsOldPage() async throws {
    let prefs = preferences()
    defer { prefs.defaults.removePersistentDomain(forName: prefs.store.suiteName ?? "") }
    let service = try FakeMonitorService(rows: [sample()])
    let model = try MonitorViewModel(service: service, preferences: prefs)
    let gate = RequestGate()
    service.beforeList = { service.beforeList = nil; await gate.suspend() }
    let fetching = Task { await model.setVisibility(window: true, menuBar: false) }
    await gate.waitUntilEntered()
    model.setSearch("new search")
    gate.resume()
    await fetching.value
    #expect(service.queries.count == 2)
    #expect(service.queries.last?.search == "new search")
}

@MainActor
@Test func inspectorLoadsPathsOnlyWhenAllowedAndPinGoesThroughService() async throws {
    let prefs = preferences()
    defer { prefs.defaults.removePersistentDomain(forName: prefs.store.suiteName ?? "") }
    let process = try sample()
    let service = try FakeMonitorService(rows: [process])
    let model = try MonitorViewModel(service: service, preferences: prefs)
    await model.setVisibility(window: true, menuBar: false)
    model.select(process.processKey)
    await model.refreshInspector()
    #expect(service.processCalls.isEmpty)
    #expect(model.detail?.path == nil)
    #expect(service.historyRequests.last?.series == [process.processKey.rawValue])
    try prefs.store.setAllowedPermissions([.includePaths])
    await model.refreshInspector()
    #expect(service.processCalls == [process.processKey])
    #expect(model.detail?.path?.hasSuffix("worker") == true)
    await model.togglePin()
    #expect(model.pinned)
    #expect(service.pinned.contains(process.processKey))
    await model.togglePin()
    #expect(!model.pinned)
    try prefs.store.setAllowedPermissions([])
    model.permissionsChanged()
    #expect(model.detail?.path == nil)
}

@MainActor
@Test func chartSegmentsSplitAtGapsAndMissingMetrics() {
    let point: (Int, Metric) -> HistoryPoint = { HistoryPoint(t: Date(timeIntervalSince1970: Double($0)), cpuPercent: $1) }
    let series = HistorySeries(series: "system", points: [point(0, .ok(1)), point(1, .ok(2)), point(4, .ok(3)),
                                                          point(5, .stale), point(6, .ok(4)), point(7, .ok(5))],
                               gaps: [HistoryGap(from: Date(timeIntervalSince1970: 2), to: Date(timeIntervalSince1970: 3))])
    #expect(ChartGeometry.segments(series, value: { $0.cpuPercent }).map { $0.map(\.value) } == [[1, 2], [3], [4, 5]])
    #expect(ChartGeometry.segments(series, value: { $0.footprintBytes }).isEmpty)
}

@MainActor
@Test func mcpConfigurationAllFlagCombinationsKeepActualHelperPath() throws {
    let url = URL(fileURLWithPath: "/Applications/My Apps/Procglint.app/Contents/Helpers/procglint-mcp")
    let flags = ["--allow-observe", "--allow-configure", "--allow-terminate", "--allow-force-kill", "--include-system", "--include-paths"]
    struct Config: Decodable {
        struct Server: Decodable { var command: String; var args: [String] }
        var mcpServers: [String: Server]
    }
    for mask in 0 ..< 64 {
        let permissions = PermissionSet(Set(Permission.allCases.enumerated().filter { mask & (1 << $0.offset) != 0 }.map(\.element)))
        let json = try MCPConfiguration.json(helperURL: url, permissions: permissions)
        let decoder = ProcglintJSON.decoder()
        decoder.keyDecodingStrategy = .useDefaultKeys
        let config = try decoder.decode(Config.self, from: Data(json.utf8))
        #expect(config.mcpServers["procglint"]?.command == url.path)
        #expect(config.mcpServers["procglint"]?.args == flags.enumerated().filter { mask & (1 << $0.offset) != 0 }.map(\.element))
    }
}

@MainActor
@Test func terminationRequiresConfirmationAndDistinguishesSentFromExited() async throws {
    let prefs = preferences()
    defer { prefs.defaults.removePersistentDomain(forName: prefs.store.suiteName ?? "") }
    let process = try sample()
    let service = try FakeMonitorService(rows: [process])
    let model = try MonitorViewModel(service: service, preferences: prefs)
    model.apply(ProcessPage(snapshot: service.current.header, items: [process], totalMatched: 1))
    model.select(process.processKey)
    await model.terminate(signal: .term) { _, _ in false }
    #expect(service.terminationCalls.isEmpty)
    await model.terminate(signal: .term) { target, signal in
        #expect(target.processKey == process.processKey)
        #expect(signal == .term)
        #expect(service.terminationCalls.isEmpty)
        return true
    }
    #expect(service.terminationCalls == ["prepare:p1.boot-a.42.10:term", "terminate:tok-1"])
    #expect(model.inspectorMessage == "Signal sent; exit not confirmed")
    service.terminationResult = try TerminationResult(outcome: .signalSent, exitedConfirmed: true)
    await model.terminate(signal: .kill) { _, _ in true }
    #expect(service.terminationCalls.suffix(2) == ["prepare:p1.boot-a.42.10:kill", "terminate:tok-1"])
    #expect(model.inspectorMessage == "Exited (confirmed)")
    service.terminationResult = try TerminationResult(outcome: .rejected, rejection: .processChanged, exitedConfirmed: false)
    await model.terminate(signal: .term) { _, _ in true }
    #expect(model.inspectorMessage == "Rejected: process_changed")
    service.prepareError = .terminationRejected(.protectedPID)
    let previous = service.terminationCalls.count
    await model.terminate(signal: .term) { _, _ in true }
    #expect(service.terminationCalls.count == previous + 1)
    #expect(model.inspectorMessage.contains("termination_rejected"))
}

@MainActor
@Test func columnAndSettingsPersistenceUsesDedicatedDefaultsSuite() throws {
    let prefs = preferences()
    defer { prefs.defaults.removePersistentDomain(forName: prefs.store.suiteName ?? "") }
    #expect(!prefs.visible(.rss))
    #expect(prefs.visible(.cpu))
    prefs.setVisible(true, column: .rss)
    prefs.setVisible(true, column: .cpuTime)
    prefs.setVisible(false, column: .cpu)
    prefs.menuBar = true
    let reloaded = AppPreferences(suiteName: prefs.store.suiteName)
    #expect(reloaded.visible(.rss))
    #expect(reloaded.visible(.cpuTime))
    #expect(reloaded.visible(.cpu))
    #expect(reloaded.menuBar)
    reloaded.setVisible(false, column: .rss)
    #expect(!prefs.visible(.rss))
    let policy = try SamplingPolicy(revision: 3, guiIntervalMS: .oneSecond, historyMinutes: 2)
    try prefs.store.setSamplingPolicy(policy)
    try prefs.store.setAllowedPermissions([.terminate, .observe])
    #expect(try reloaded.store.samplingPolicy() == policy)
    #expect(try reloaded.store.allowedPermissions() == [.terminate, .observe])
}

@MainActor
@Test func settingsSavesRevisionAndShowsAgentAndClientDiagnostics() async throws {
    let prefs = preferences()
    defer { prefs.defaults.removePersistentDomain(forName: prefs.store.suiteName ?? "") }
    let service = try FakeMonitorService()
    var registered = false
    let settings = try SettingsViewModel(service: service, preferences: prefs, helperURL: URL(fileURLWithPath: "/tmp/procglint-mcp"),
                                         registrationStatus: { registered ? "registered" : "not registered" }, registerAgent: { registered = true })
    await settings.refresh()
    #expect(settings.diagnostics.contains("p95: 4.0 ms"))
    #expect(settings.diagnostics.contains("warming_up"))
    #expect(settings.diagnostics.contains("mcp PID 30"))
    #expect(settings.diagnostics.contains("Failure denied: 3"))
    await settings.savePolicy(interval: .twoSeconds, historyMinutes: 3)
    #expect(service.expectedRevisions == [0])
    #expect(settings.policy.revision == 1)
    #expect(try prefs.store.samplingPolicy().guiIntervalMS == .twoSeconds)
    await settings.savePolicy(interval: .oneSecond, historyMinutes: 11)
    #expect(service.expectedRevisions == [0])
    #expect(settings.message.contains("invalid_argument"))
    settings.setPermission(.observe, allowed: true)
    #expect(try prefs.store.allowedPermissions().contains(.observe))
    settings.setPermission(.observe, allowed: false)
    #expect(try prefs.store.allowedPermissions().isEmpty)
    settings.register()
    #expect(registered)
}
