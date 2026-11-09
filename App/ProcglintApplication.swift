import AppKit
import ProcglintCore
import ProcglintIPC

@MainActor
public final class ProcglintApplication: NSObject, NSApplicationDelegate {
    private let model: MonitorViewModel
    private let uiTestingFixture: UITestingFixture?
    private let settingsModel: SettingsViewModel
    private let bundle: Bundle
    private let unregisterAgent: @MainActor () async throws -> Void
    private let openLoginItems: @MainActor () -> Void
    private var mainWindow: MainWindowController?
    private var settingsWindow: SettingsWindowController?
    private var statusItem: NSStatusItem?
    private var statusText: NSMenuItem?
    private var timer: Timer?
    private var timerInterval: TimeInterval?

    public init(service: any MonitorService, bundle: Bundle = .main,
                registrationStatus: @escaping @MainActor () -> String,
                registerAgent: @escaping @MainActor () throws -> Void,
                unregisterAgent: @escaping @MainActor () async throws -> Void,
                openLoginItems: @escaping @MainActor () -> Void,
                agentStatus: @escaping @MainActor () -> AgentRegistration.Status = { AgentRegistration().status }) throws
    {
        self.bundle = bundle
        let arguments = ProcessInfo.processInfo.arguments
        let fixture = try arguments.contains("--ui-testing") ? UITestingFixture(unregistered: arguments.contains("--ui-testing-unregistered"), requiresApproval: arguments.contains("--ui-testing-requires-approval")) : nil
        uiTestingFixture = fixture
        let status: @MainActor () -> String
        let register: @MainActor () throws -> Void
        let registration: @MainActor () -> AgentRegistration.Status
        if fixture == nil {
            self.unregisterAgent = unregisterAgent
            self.openLoginItems = openLoginItems
            status = registrationStatus
            register = registerAgent
            registration = agentStatus
        } else {
            self.unregisterAgent = { fixture?.agentRegistered = false }
            // The fixture simulates returning from Login Items after approval; it never opens System Settings.
            self.openLoginItems = { fixture?.agentRegistrationStatus = .enabled }
            status = { AgentSetup(status: fixture?.agentRegistrationStatus ?? .notRegistered, reachable: fixture?.agentRegistered == true).title }
            register = { fixture?.registerAgent() }
            registration = { fixture?.agentRegistrationStatus ?? .notRegistered }
        }
        let preferences = try fixture?.preferences() ?? AppPreferences()
        let monitor: any MonitorService = fixture.map { $0 as any MonitorService } ?? service
        model = try MonitorViewModel(service: monitor, preferences: preferences,
                                     registrationStatus: registration)
        settingsModel = try SettingsViewModel(
            service: monitor, preferences: preferences,
            helperURL: MCPConfiguration.helperURL(in: bundle),
            registrationStatus: status, registerAgent: register,
            loginItem: fixture?.loginItem ?? .mainApp, agentStatus: registration
        )
        super.init()
        if fixture != nil, let search = ProcessInfo.processInfo.environment["PROCGLINT_UI_TEST_SEARCH"] {
            model.setSearch(search)
        }
        model.onChange = { [weak self] in self?.render() }
        settingsModel.onPolicyChanged = { [weak self] policy in
            guard let self else { return }
            model.setPolicy(policy)
            Task { await self.model.tick() }
        }
        settingsModel.onPermissionsChanged = { [weak self] in self?.model.permissionsChanged() }
        settingsModel.onRegistrationChanged = { [weak self] in
            guard let self else { return }
            render()
            await model.tick()
        }
    }

    public func agentDidReconnect() async {
        await model.agentDidReconnect()
    }

    public func applicationDidFinishLaunching(_: Notification) {
        buildMenu()
        let main = MainWindowController(model: model, register: { [weak self] in
            Task { await self?.settingsModel.register() }
        }, openLoginItems: openLoginItems, registrationError: { [weak self] in self?.settingsModel.registrationError ?? "" })
        mainWindow = main
        if uiTestingFixture != nil, let appearance = ProcessInfo.processInfo.environment["PROCGLINT_UI_TEST_APPEARANCE"] {
            NSApp.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
        }
        if uiTestingFixture != nil, ProcessInfo.processInfo.arguments.contains("--ui-testing-selected") {
            main.window?.setContentSize(NSSize(width: 1360, height: 1100))
            main.window?.center()
        }
        if uiTestingFixture != nil, let search = ProcessInfo.processInfo.environment["PROCGLINT_UI_TEST_SEARCH"] {
            model.setSearch(search)
            main.search.stringValue = search
        }
        main.visibilityChanged = { [weak self] in self?.updateVisibility() }
        main.focusChanged = { [weak self] in self?.updateFocus() }
        syncMenuBar()
        render()
        openMainWindow()
        if uiTestingFixture != nil, ProcessInfo.processInfo.arguments.contains("--ui-testing-settings") {
            openSettings()
        }
    }

    public func applicationWillTerminate(_: Notification) {
        uiTestingFixture?.cleanUp()
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        false
    }

    public func applicationShouldHandleReopen(_: NSApplication, hasVisibleWindows _: Bool) -> Bool {
        openMainWindow()
        return true
    }

    public func applicationDidBecomeActive(_: Notification) {
        updateFocus()
        render()
        settingsWindow?.render()
        Task {
            await model.tick()
            if settingsWindow?.window?.isVisible == true {
                await settingsModel.refresh()
            }
        }
    }

    public func applicationDidResignActive(_: Notification) {
        updateFocus()
    }

    public func applicationDidHide(_: Notification) {
        updateVisibility()
    }

    public func applicationDidUnhide(_: Notification) {
        updateVisibility()
    }

    public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        timer?.invalidate()
        Task {
            await model.setVisibility(window: false, menuBar: false)
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    @objc private func openMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        mainWindow?.showWindow(nil)
        mainWindow?.window?.makeKeyAndOrderFront(nil)
        updateVisibility()
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            let settings = SettingsWindowController(model: settingsModel, unregisterAgent: unregisterAgent, openLoginItems: openLoginItems)
            settings.menuBarChanged = { [weak self] in self?.syncMenuBar() }
            settings.adaptiveRefreshChanged = { [weak self] in
                guard let self else { return }
                Task { await self.model.tick() }
            }
            settingsWindow = settings
        }
        settingsWindow?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        Task { await settingsModel.refresh() }
    }

    @objc private func showAbout() {
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "procglint",
            .applicationVersion: AppVersion.description(info: bundle.infoDictionary),
            .version: "",
        ])
    }

    private func buildMenu() {
        let menu = NSMenu()
        let app = NSMenuItem(title: "procglint", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "procglint")
        let about = NSMenuItem(title: "About procglint", action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        submenu.addItem(about)
        submenu.addItem(.separator())
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        submenu.addItem(settings)
        submenu.addItem(.separator())
        submenu.addItem(withTitle: "Quit procglint", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        app.submenu = submenu
        menu.addItem(app)
        let windowItem = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
        let windowMenu = NSMenu(title: "Window")
        let open = NSMenuItem(title: "Open procglint", action: #selector(openMainWindow), keyEquivalent: "0")
        open.target = self
        windowMenu.addItem(open)
        windowItem.submenu = windowMenu
        menu.addItem(windowItem)
        NSApp.mainMenu = menu
        NSApp.windowsMenu = windowMenu
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        let edit = NSMenu(title: "Edit")
        for (title, action, key) in [("Cut", #selector(NSText.cut(_:)), "x"), ("Copy", #selector(NSText.copy(_:)), "c"), ("Paste", #selector(NSText.paste(_:)), "v"), ("Select All", #selector(NSText.selectAll(_:)), "a")] {
            edit.addItem(withTitle: title, action: action, keyEquivalent: key)
        }
        editItem.submenu = edit
        menu.insertItem(editItem, at: 1)
    }

    private func syncMenuBar() {
        if model.preferences.menuBar, statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            let menu = NSMenu()
            let status = NSMenuItem(title: "unavailable", action: nil, keyEquivalent: "")
            menu.addItem(status)
            statusText = status
            let open = NSMenuItem(title: "Open procglint", action: #selector(openMainWindow), keyEquivalent: "")
            open.target = self
            menu.addItem(open)
            let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: "")
            settings.target = self
            menu.addItem(settings)
            menu.addItem(.separator())
            menu.addItem(withTitle: "Quit procglint", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            item.menu = menu
            item.button?.setAccessibilityLabel("procglint CPU, memory, and monitoring status")
            item.button?.setAccessibilityIdentifier("monitorStatusItem")
            statusItem = item
        } else if !model.preferences.menuBar, let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
            self.statusItem = nil
            statusText = nil
        }
        updateVisibility()
    }

    private func updateFocus() {
        model.setFocus(appActive: NSApp.isActive, keyWindow: mainWindow?.window?.isKeyWindow == true)
    }

    private func updateVisibility() {
        updateFocus()
        let visible = !NSApp.isHidden && mainWindow?.monitoringVisible == true
        let menuVisible = statusItem != nil
        Task { await model.setVisibility(window: visible, menuBar: menuVisible) }
    }

    private func render() {
        if uiTestingFixture != nil, ProcessInfo.processInfo.arguments.contains("--ui-testing-selected"), model.selectedKey == nil,
           let process = model.rows.first(where: { $0.pid == 4100 })
        {
            model.select(process.processKey)
            Task { await model.refreshInspector() }
        }
        if uiTestingFixture != nil, ProcessInfo.processInfo.arguments.contains("--ui-testing-selected"),
           model.history != nil, model.chartSelection.time == nil, let time = model.header?.sampledAt
        {
            model.chartSelection.move(to: time.addingTimeInterval(-100), from: .systemCPU)
        }
        mainWindow?.render()
        statusText?.title = model.header?.status.rawValue ?? "unavailable"
        if let header = model.header, header.status != .unavailable {
            statusItem?.button?.title = "CPU \(Display.metric(header.system.cpuPercent, format: Display.percent).text) · \(Display.bytes(Double(header.system.memoryUsedBytes))) · \(header.status.rawValue)"
        } else {
            statusItem?.button?.title = "CPU — · Memory — · unavailable"
        }
        statusItem?.button?.toolTip = model.summary + (model.message.isEmpty ? "" : "\n" + model.message)
        scheduleTimer()
    }

    private func scheduleTimer() {
        let interval = model.pollingInterval
        guard interval != timerInterval else { return }
        timer?.invalidate()
        timer = nil
        timerInterval = interval
        guard let interval else { return }
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                await self.model.tick()
            }
        }
        timer.tolerance = interval * 0.1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
}
