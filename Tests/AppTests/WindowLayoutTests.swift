import AppKit
@testable import ProcglintApp
import ProcglintCore
import ProcglintIPC
import Testing

@MainActor
private func expectListLayout(_ controller: MainWindowController, rows: Int) throws {
    let window = try #require(controller.window)
    let root = try #require(window.contentView)
    root.layoutSubtreeIfNeeded()
    controller.splitController.splitView.adjustSubviews()
    root.layoutSubtreeIfNeeded()
    let scroll = controller.processScroll
    scroll.tile()
    let list = try #require(scroll.superview)
    #expect(scroll.bounds.height > 200)
    #expect(abs(scroll.frame.maxY - list.bounds.maxY) < 1)
    #expect(abs(scroll.frame.minY - controller.footer.frame.maxY) < 1)
    #expect(controller.footer.frame.minY == 0)
    #expect(controller.footer.bounds.height == 32)
    let header = try #require(controller.table.headerView)
    #expect(header.isDescendant(of: scroll))
    #expect(header.bounds.height > 10)
    #expect(controller.table.numberOfRows == rows)
    if rows > 0 {
        let cell = try #require(controller.table.view(atColumn: 0, row: 0, makeIfNecessary: true) as? NSTableCellView)
        #expect(cell.textField?.stringValue.isEmpty == false)
        let headerRect = header.convert(header.bounds, to: list)
        let rowRect = controller.table.convert(controller.table.rect(ofRow: 0), to: list)
        #expect(headerRect.minY >= rowRect.maxY - 1)
        #expect(rowRect.minY >= controller.footer.frame.maxY)
    }
}

@MainActor
@Test func listFillsSplitPaneWithFooterBelowRowsAfterSearchingAndResizing() async throws {
    _ = NSApplication.shared
    let fixture = try UITestingFixture()
    let prefs = try fixture.preferences()
    defer { fixture.cleanUp() }
    let model = try MonitorViewModel(service: fixture, preferences: prefs)
    model.setSearch("4100")
    let controller = MainWindowController(model: model)
    defer { controller.window?.close() }
    #expect(controller.search.stringValue == "4100")
    for search in ["", "4100", "no-match"] {
        model.setSearch(search)
        await model.setVisibility(window: true, menuBar: false)
        controller.render()
        for size in [NSSize(width: 1360, height: 900), NSSize(width: 1000, height: 650)] {
            controller.window?.setContentSize(size)
            try expectListLayout(controller, rows: model.rows.count)
        }
    }
}

@MainActor
@Test func onboardingOccupiesSpaceAboveCardsWithoutCollapsingTheList() async throws {
    let fixture = try UITestingFixture()
    let prefs = try fixture.preferences()
    defer { fixture.cleanUp() }
    let model = try MonitorViewModel(service: fixture, preferences: prefs, registrationStatus: { fixture.agentRegistrationStatus })
    let controller = MainWindowController(model: model)
    defer { controller.window?.close() }
    await model.setVisibility(window: true, menuBar: false)
    for value in [AgentRegistration.Status.notRegistered, .notFound, .requiresApproval, .enabled] {
        fixture.agentRegistrationStatus = value
        await model.tick()
        controller.render()
        try expectListLayout(controller, rows: 20)
        let root = try #require(controller.window?.contentView)
        #expect(controller.agentBanner.isHidden == (value == .enabled))
        #expect(controller.agentBannerContainer.frame.maxY == root.bounds.maxY)
        #expect(controller.agentBannerContainer.bounds.height == (value == .enabled ? 0 : 124))
    }
}

@MainActor
@Test(.enabled(if: ProcessInfo.processInfo.environment["PROCGLINT_LIVE_SNAPSHOT_PATH"] != nil))
func liveAgentSnapshotRendersRowsWithoutCapturingOrLoggingProcessData() async throws {
    // The trusted bundled CLI obtains the live agent snapshot; the test never opens a live-data window.
    let path = try #require(ProcessInfo.processInfo.environment["PROCGLINT_LIVE_SNAPSHOT_PATH"])
    let snapshot = try ProcglintJSON.decoder().decode(Snapshot.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    #expect(snapshot.status != .unavailable)
    #expect(!snapshot.processes.isEmpty)
    let prefs = preferences()
    defer { prefs.defaults.removePersistentDomain(forName: prefs.store.suiteName ?? "") }
    var store = SnapshotStore(clock: FakeClock())
    store.insert(snapshot)
    let query = try ProcessQuery(filter: .all, limit: 200, fields: ProcessField.allCases.filter { $0 != .path })
    let page = try store.listProcesses(query, scope: AccessScope(includeSystem: true))
    let service = try FakeMonitorService()
    service.current = snapshot
    service.pageOverride = page
    let model = try MonitorViewModel(service: service, preferences: prefs)
    let controller = MainWindowController(model: model)
    defer { controller.window?.close() }
    await model.setVisibility(window: true, menuBar: false)
    controller.render()
    try expectListLayout(controller, rows: min(200, snapshot.processes.count))
    #expect(model.totalMatched == snapshot.processes.count)
    #expect(controller.loadMore.isHidden == (snapshot.processes.count <= 200))
}
