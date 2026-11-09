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
        #expect(controller.launchedBy.stringValue == "Launched by")
        #expect(controller.commandLine.stringValue == "Command lines hidden — enable in Settings")
        #expect(controller.cwd.stringValue.isEmpty)
        #expect(model.detail?.commandLine == nil)
        let groups = controller.lineage.arrangedSubviews.compactMap { $0 as? NSStackView }
        let buttons = groups.compactMap { $0.arrangedSubviews.first as? NSButton }
        #expect(buttons.map(\.title) == ["launchd (1)", "zsh (43)"])
        #expect(!buttons[0].isEnabled && buttons[1].isEnabled)
        #expect(controller.lineageStatus.stringValue == "Direct children: 3 · Parent chain incomplete")

        try prefs.store.setAllowedPermissions([.includeCommandLines])
        model.permissionsChanged()
        await model.selectionUpdate?.value
        controller.render()
        #expect(controller.commandLine.stringValue == "Command: node server.js --token <redacted>")
        #expect(controller.commandLine.isSelectable)
        #expect(controller.cwd.stringValue == "Working directory: /private/project")
        #expect(controller.cwd.isSelectable)
        let commands = controller.lineage.arrangedSubviews.compactMap { $0 as? NSStackView }.flatMap(\.arrangedSubviews).compactMap { $0 as? NSTextField }
        #expect(commands.map(\.stringValue) == ["zsh --auth=<redacted>"])
        // Paging within an unchanged snapshot must not discard the lazy detail.
        model.apply(ProcessPage(snapshot: service.current.header, items: [], totalMatched: 2), append: true)
        #expect(model.detail?.commandLine != nil)

        try prefs.store.setAllowedPermissions([])
        model.permissionsChanged()
        #expect(model.detail?.commandLine == nil && model.detail?.cwd == nil)
        #expect(model.detail?.ancestors?.allSatisfy { $0.commandLine == nil } == true)
        await model.selectionUpdate?.value
        controller.render()
        let parentButton = try #require((controller.lineage.arrangedSubviews.last as? NSStackView)?.arrangedSubviews.first as? NSButton)
        parentButton.performClick(nil)
        #expect(model.selectedKey == parent.processKey)
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
