import Foundation
@testable import ProcglintApp
import ProcglintCore
import Testing

@MainActor
@Test func pagingUsesCursorWithoutMixingSnapshotsAndHidingReleasesLease() async throws {
    let prefs = preferences()
    defer { prefs.defaults.removePersistentDomain(forName: prefs.store.suiteName ?? "") }
    let first = try sample()
    let second = try sample(pid: 43, key: "p1.boot-a.43.20")
    let service = try FakeMonitorService(rows: [first])
    service.nextCursor = "page-two"
    let model = try MonitorViewModel(service: service, preferences: prefs)
    await model.setVisibility(window: true, menuBar: false)
    service.pageOverride = ProcessPage(snapshot: service.current.header, items: [second], totalMatched: 2)
    await model.loadMore()
    #expect(service.queries.last?.cursor == "page-two")
    #expect(model.rows.map(\.processKey) == [first.processKey, second.processKey])
    #expect(model.nextCursor == nil)

    service.pageOverride = nil
    service.pagesByCursor["page-two"] = ProcessPage(snapshot: service.current.header, items: [second], totalMatched: 2)
    model.select(second.processKey)
    await model.tick()
    #expect(model.selectedKey == second.processKey)
    #expect(model.rows.map(\.processKey) == [first.processKey, second.processKey])
    model.setSearch("worker")
    await model.tick()
    #expect(model.rows.map(\.processKey) == [first.processKey])
    service.pageOverride = ProcessPage(snapshot: snapshot(id: "sample-2").header, items: [second], totalMatched: 2)
    await model.loadMore()
    #expect(model.rows.map(\.processKey) == [first.processKey])
    #expect(model.message.contains("invalid_cursor"))

    service.pageOverride = ProcessPage(snapshot: service.current.header, items: [second], totalMatched: 2)
    let gate = RequestGate()
    service.beforeList = { await gate.suspend() }
    let paging = Task { await model.loadMore() }
    await gate.waitUntilEntered()
    await model.setVisibility(window: false, menuBar: false)
    gate.resume()
    await paging.value
    #expect(service.released == ["gui_window"])
}

@MainActor
@Test func permissionRevokedDuringPathFetchDiscardsSensitiveResult() async throws {
    let prefs = preferences()
    defer { prefs.defaults.removePersistentDomain(forName: prefs.store.suiteName ?? "") }
    let process = try sample()
    let service = try FakeMonitorService(rows: [process])
    let model = try MonitorViewModel(service: service, preferences: prefs)
    await model.setVisibility(window: true, menuBar: false)
    model.select(process.processKey)
    try prefs.store.setAllowedPermissions([.includePaths])
    let gate = RequestGate()
    service.beforeProcess = { await gate.suspend() }
    let fetching = Task { await model.refreshInspector() }
    await gate.waitUntilEntered()
    try prefs.store.setAllowedPermissions([])
    model.permissionsChanged()
    gate.resume()
    await fetching.value
    #expect(model.detail?.path == nil)
}

@MainActor
@Test func terminationUsesConfirmedIdentityEvenIfSelectionChanges() async throws {
    let prefs = preferences()
    defer { prefs.defaults.removePersistentDomain(forName: prefs.store.suiteName ?? "") }
    let first = try sample()
    let second = try sample(pid: 43, key: "p1.boot-a.43.20")
    let service = try FakeMonitorService(rows: [first, second])
    let model = try MonitorViewModel(service: service, preferences: prefs)
    model.apply(ProcessPage(snapshot: service.current.header, items: [first, second], totalMatched: 2))
    model.select(first.processKey)
    await model.terminate(signal: .term) { _, _ in
        model.select(second.processKey)
        await model.terminate(signal: .kill) { _, _ in Issue.record("Concurrent termination must not ask for confirmation"); return true }
        return true
    }
    #expect(service.terminationCalls == ["prepare:p1.boot-a.42.10:term", "terminate:tok-1"])
    #expect(model.selectedKey == second.processKey)
    #expect(!model.inspectorMessage.contains("Signal sent"))
    #expect(!model.terminating)
}

@MainActor
@Test func reconnectAdoptsPolicyAndHistoryErrorsRemainVisible() async throws {
    let prefs = preferences()
    defer { prefs.defaults.removePersistentDomain(forName: prefs.store.suiteName ?? "") }
    let process = try sample()
    let service = try FakeMonitorService(rows: [process])
    service.currentPolicy = try SamplingPolicy(guiIntervalMS: .oneSecond, historyMinutes: 2)
    let model = try MonitorViewModel(service: service, preferences: prefs)
    await model.setVisibility(window: true, menuBar: false)
    #expect(model.pollingInterval == 1)
    #expect(service.leaseRequests.last?.intervalMS == .oneSecond)
    model.select(process.processKey)
    service.historyError = .historyLimitReached("pin limit")
    await model.tick()
    #expect(model.message.contains("history_limit_reached"))
}

@MainActor
@Test func missingHelperIsAnErrorInsteadOfInventingAnInstallationPath() throws {
    let prefs = preferences()
    defer { prefs.defaults.removePersistentDomain(forName: prefs.store.suiteName ?? "") }
    let settings = try SettingsViewModel(service: FakeMonitorService(), preferences: prefs, helperURL: nil,
                                         registrationStatus: { "unknown" }, registerAgent: {})
    #expect(throws: AgentError.self) { try settings.configuration() }
}

@MainActor
@Test func helperLookupUsesRelocatedBundle() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("procglint-app-test-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let bundleURL = root.appendingPathComponent("Relocated App.app")
    let contents = bundleURL.appendingPathComponent("Contents")
    let helper = contents.appendingPathComponent("Helpers/procglint-mcp")
    try FileManager.default.createDirectory(at: helper.deletingLastPathComponent(), withIntermediateDirectories: true)
    let info: [String: Any] = ["CFBundleIdentifier": "procglint.test", "CFBundlePackageType": "APPL", "CFBundleExecutable": "procglint-gui"]
    try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
    try Data("test helper".utf8).write(to: helper)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
    let bundle = try #require(Bundle(url: bundleURL))
    #expect(MCPConfiguration.helperURL(in: bundle) == helper)
}

@MainActor
@Test func chartOmitsPointsInsideGapAndBreaksOnBackwardTime() {
    let series = HistorySeries(series: "system", points: [0, 1, 2, 3, 2, 4].map {
        HistoryPoint(t: Date(timeIntervalSince1970: Double($0)), cpuPercent: .ok(Double($0)))
    }, gaps: [HistoryGap(from: Date(timeIntervalSince1970: 1), to: Date(timeIntervalSince1970: 2))])
    #expect(ChartGeometry.segments(series, value: { $0.cpuPercent }).map { $0.map(\.value) } == [[0], [2, 3], [2, 4]])
}
