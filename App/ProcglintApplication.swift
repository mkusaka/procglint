import AppKit
import ProcglintCore

@MainActor
public final class ProcglintApplication: NSObject, NSApplicationDelegate {
    private let model: MonitorViewModel
    private let settingsModel: SettingsViewModel
    private var mainWindow: MainWindowController?
    private var settingsWindow: SettingsWindowController?
    private var statusItem: NSStatusItem?
    private var statusText: NSMenuItem?
    private var timer: Timer?
    private var timerInterval: TimeInterval?

    public init(service: any MonitorService, bundle: Bundle = .main,
                registrationStatus: @escaping @MainActor () -> String,
                registerAgent: @escaping @MainActor () throws -> Void) throws
    {
        let preferences = AppPreferences()
        model = try MonitorViewModel(service: service, preferences: preferences)
        settingsModel = try SettingsViewModel(
            service: service, preferences: preferences,
            helperURL: MCPConfiguration.helperURL(in: bundle),
            registrationStatus: registrationStatus, registerAgent: registerAgent
        )
        super.init()
        model.onChange = { [weak self] in self?.render() }
        settingsModel.onPolicyChanged = { [weak self] policy in
            guard let self else { return }
            model.setPolicy(policy)
            Task { await self.model.tick() }
        }
        settingsModel.onPermissionsChanged = { [weak self] in self?.model.permissionsChanged() }
    }

    public func applicationDidFinishLaunching(_: Notification) {
        buildMenu()
        let main = MainWindowController(model: model)
        mainWindow = main
        main.visibilityChanged = { [weak self] in self?.updateVisibility() }
        syncMenuBar()
        openMainWindow()
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        false
    }

    public func applicationShouldHandleReopen(_: NSApplication, hasVisibleWindows _: Bool) -> Bool {
        openMainWindow()
        return true
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
            let settings = SettingsWindowController(model: settingsModel)
            settings.menuBarChanged = { [weak self] in self?.syncMenuBar() }
            settingsWindow = settings
        }
        settingsWindow?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        Task { await settingsModel.refresh() }
    }

    private func buildMenu() {
        let menu = NSMenu()
        let app = NSMenuItem()
        let submenu = NSMenu()
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
            statusItem = item
        } else if !model.preferences.menuBar, let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
            self.statusItem = nil
            statusText = nil
        }
        updateVisibility()
    }

    private func updateVisibility() {
        let visible = !NSApp.isHidden && mainWindow?.monitoringVisible == true
        let menuVisible = statusItem != nil
        Task { await model.setVisibility(window: visible, menuBar: menuVisible) }
    }

    private func render() {
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
