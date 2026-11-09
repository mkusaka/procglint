import AppKit
@testable import ProcglintApp
import ProcglintCore
import Testing

@MainActor
struct InspectorProcessDetailTests {
    @Test func lineageIsRootFirstSelectableAndArgumentsFollowSettings() async throws {
        let prefs = preferences()
        defer { prefs.defaults.removePersistentDomain(forName: prefs.store.suiteName ?? "") }
        var process = try sample()
        let parent = try sample(pid: 43, key: "p1.boot-a.43.10")
        process.ancestors = [ProcessAncestor(pid: 43, name: "zsh", processKey: parent.processKey,
                                             commandLine: ProcessCommandLine(arguments: ["zsh", "--auth=test-secret"])),
                             ProcessAncestor(pid: 1, name: "launchd")]
        process.ancestorsIncomplete = true
        process.childrenCount = 3
        process.commandLine = ProcessCommandLine(arguments: ["node", "server.js", "--token", "test-secret"])
        process.cwd = WorkingDirectory(value: "/private/project")
        let service = try FakeMonitorService(rows: [process, parent])
        let model = try MonitorViewModel(service: service, preferences: prefs)
        await model.setVisibility(window: true, menuBar: false)
        model.select(process.processKey)
        await model.selectionUpdate?.value
        await model.refreshInspector()
        let controller = MainWindowController(model: model)
        controller.render()
        #expect(model.commandLineText == "Command lines hidden — enable in Settings")
        #expect(model.cwdText.isEmpty)
        #expect(model.detail?.commandLine == nil)
        #expect(model.rootAncestors.map { "\($0.name) (\($0.pid))" } == ["launchd (1)", "zsh (43)"])
        #expect(!model.canSelectAncestor(model.rootAncestors[0]) && model.canSelectAncestor(model.rootAncestors[1]))
        #expect(model.lineageStatusText == "Direct children: 3 · Parent chain incomplete")

        try prefs.store.setAllowedPermissions([.includeCommandLines])
        model.permissionsChanged()
        await model.selectionUpdate?.value
        controller.render()
        #expect(model.commandLineText == "Command: node server.js --token <redacted>")
        #expect(model.cwdText == "Working directory: /private/project")
        #expect(model.rootAncestors.compactMap { $0.commandLine?.displayText } == ["zsh --auth=<redacted>"])
        // Paging within an unchanged snapshot must not discard the lazy detail.
        model.apply(ProcessPage(snapshot: service.current.header, items: [], totalMatched: 2), append: true)
        #expect(model.detail?.commandLine != nil)

        try prefs.store.setAllowedPermissions([])
        model.permissionsChanged()
        #expect(model.detail?.commandLine == nil && model.detail?.cwd == nil)
        #expect(model.detail?.ancestors?.allSatisfy { $0.commandLine == nil } == true)
        await model.selectionUpdate?.value
        controller.render()
        await model.selectAncestor(model.rootAncestors[1])
        controller.render()
        #expect(model.selectedKey == parent.processKey)
        #expect(controller.table.selectedRow == 1)
        controller.window?.close()
        await model.selectionUpdate?.value
        await model.refreshInspector()
    }

    @Test func settingsToggleIsOffByDefaultAndCopiesLaunchFlagOnlyWhenEnabled() throws {
        let prefs = preferences()
        defer { prefs.defaults.removePersistentDomain(forName: prefs.store.suiteName ?? "") }
        #expect(try !prefs.store.allowedPermissions().contains(.includeCommandLines))
        let settings = try SettingsViewModel(service: FakeMonitorService(), preferences: prefs,
                                             helperURL: URL(fileURLWithPath: "/fixture/procglint-mcp"),
                                             registrationStatus: { "enabled" }, registerAgent: {})
        #expect(try !settings.configuration().contains("--include-command-lines"))
        settings.setPermission(.includeCommandLines, allowed: true)
        #expect(try prefs.store.allowedPermissions().contains(.includeCommandLines))
        #expect(try settings.configuration().contains("--include-command-lines"))
        settings.setPermission(.includeCommandLines, allowed: false)
        #expect(try !prefs.store.allowedPermissions().contains(.includeCommandLines))
    }
}
