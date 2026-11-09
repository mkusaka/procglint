import AppKit
import ProcglintCore

@MainActor
final class SettingsWindowController: NSWindowController {
    let model: SettingsViewModel
    let interval = NSPopUpButton()
    let history = NSPopUpButton()
    let menuBar = NSButton(checkboxWithTitle: "Show CPU and memory in the menu bar", target: nil, action: nil)
    let adaptiveRefresh = NSButton(checkboxWithTitle: "Slow refresh when the main window is not focused", target: nil, action: nil)
    let registration = NSTextField(wrappingLabelWithString: "")
    let launchAtLogin = NSButton(checkboxWithTitle: "Open procglint at login", target: nil, action: nil)
    let loginItemHint = NSTextField(wrappingLabelWithString: "")
    let loginItemApproval = NSButton(title: "Open Login Items…", target: nil, action: nil)
    let diagnostics = NSTextView()
    let feedback = NSTextField(wrappingLabelWithString: "")
    private var permissionButtons: [Permission: NSButton] = [:]
    private let unregisterAgent: @MainActor () async throws -> Void
    private let openLoginItems: @MainActor () -> Void
    var menuBarChanged: (@MainActor () -> Void)?
    var adaptiveRefreshChanged: (@MainActor () -> Void)?

    init(model: SettingsViewModel, unregisterAgent: @escaping @MainActor () async throws -> Void,
         openLoginItems: @escaping @MainActor () -> Void)
    {
        self.model = model
        self.unregisterAgent = unregisterAgent
        self.openLoginItems = openLoginItems
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 760),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "procglint Settings"
        window.setAccessibilityIdentifier("settingsWindow")
        window.minSize = NSSize(width: 640, height: 700)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.center()
        interval.addItems(withTitles: SamplingInterval.allCases.map { "\($0.rawValue / 1000) s" })
        interval.setAccessibilityLabel("GUI update interval")
        history.addItems(withTitles: (1 ... 10).map { "\($0) min" })
        history.setAccessibilityLabel("History retention")
        let apply = NSButton(title: "Apply sampling policy", target: self, action: #selector(savePolicy))
        let register = NSButton(title: "Register agent…", target: self, action: #selector(registerAgent))
        let unregister = NSButton(title: "Unregister agent", target: self, action: #selector(unregisterAgentService))
        let loginItems = NSButton(title: "Open Login Items…", target: self, action: #selector(showLoginItems))
        let copy = NSButton(title: "Copy MCP config", target: self, action: #selector(copyConfiguration))
        copy.setAccessibilityIdentifier("copyMCPConfig")
        menuBar.setAccessibilityIdentifier("menuBarToggle")
        launchAtLogin.setAccessibilityIdentifier("launchAtLoginToggle")
        launchAtLogin.target = self
        launchAtLogin.action = #selector(toggleLaunchAtLogin)
        loginItemHint.setAccessibilityIdentifier("launchAtLoginHint")
        loginItemApproval.target = self
        loginItemApproval.action = #selector(showLoginItems)
        adaptiveRefresh.setAccessibilityIdentifier("adaptiveRefreshToggle")
        adaptiveRefresh.toolTip = "Uses the next slower update interval, up to 10 seconds, while the visible main window is not active and key. Hidden windows stop their lease."
        adaptiveRefresh.target = self
        adaptiveRefresh.action = #selector(toggleAdaptiveRefresh)
        feedback.setAccessibilityIdentifier("settingsFeedback")
        let refresh = NSButton(title: "Refresh diagnostics", target: self, action: #selector(refreshDiagnostics))
        menuBar.target = self
        menuBar.action = #selector(toggleMenuBar)
        let permissionViews: [NSView] = Permission.allCases.map { permission in
            let button = NSButton(checkboxWithTitle: permission.rawValue, target: self, action: #selector(togglePermission(_:)))
            button.identifier = NSUserInterfaceItemIdentifier(permission.rawValue)
            permissionButtons[permission] = button
            return button
        }
        let note = NSTextField(wrappingLabelWithString: "Permissions cap GUI and MCP access. MCP launch flags further restrict access. The MCP host may send process results to external models. Never enable permissions you do not want to share.")
        diagnostics.isEditable = false
        diagnostics.isSelectable = true
        diagnostics.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        diagnostics.isVerticallyResizable = true
        diagnostics.isHorizontallyResizable = false
        diagnostics.autoresizingMask = [.width]
        diagnostics.textContainer?.widthTracksTextView = true
        diagnostics.setAccessibilityLabel("Agent and clients diagnostics")
        let diagnosticScroll = NSScrollView()
        diagnosticScroll.hasVerticalScroller = true
        diagnosticScroll.documentView = diagnostics
        diagnosticScroll.heightAnchor.constraint(equalToConstant: 180).isActive = true
        let stack = verticalStack([
            NSStackView(views: [NSTextField(labelWithString: "Update interval"), interval, NSTextField(labelWithString: "History"), history, apply]),
            menuBar, adaptiveRefresh, launchAtLogin, loginItemHint, loginItemApproval,
            registration, NSStackView(views: [register, unregister, loginItems]), NSTextField(labelWithString: "MCP permissions"),
        ] + permissionViews + [note, copy, refresh, diagnosticScroll, feedback])
        for view in [registration, loginItemHint, note, diagnosticScroll, feedback] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        window.contentView = scrollingContent(stack)
        model.onChange = { [weak self] in self?.render() }
        render()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Programmatic UI only")
    }

    func render() {
        interval.selectItem(at: SamplingInterval.allCases.firstIndex(of: model.policy.guiIntervalMS) ?? 2)
        history.selectItem(at: model.policy.historyMinutes - 1)
        menuBar.state = model.preferences.menuBar ? .on : .off
        adaptiveRefresh.state = model.preferences.adaptiveRefresh ? .on : .off
        registration.stringValue = "Agent registration: \(model.registrationStatus())"
        launchAtLogin.state = model.opensAtLogin ? .on : .off
        launchAtLogin.isEnabled = !model.changingLoginItem
        loginItemHint.stringValue = model.loginItemHint
        loginItemHint.isHidden = model.loginItemHint.isEmpty
        loginItemApproval.isHidden = model.loginItem.status() != .requiresApproval
        for (permission, button) in permissionButtons {
            button.state = model.permissions.contains(permission) ? .on : .off
        }
        diagnostics.string = model.diagnostics
        feedback.stringValue = model.message
    }

    @objc private func savePolicy() {
        let selectedInterval = SamplingInterval.allCases[interval.indexOfSelectedItem]
        let minutes = history.indexOfSelectedItem + 1
        Task { await model.savePolicy(interval: selectedInterval, historyMinutes: minutes) }
    }

    @objc private func toggleMenuBar() {
        model.preferences.menuBar = menuBar.state == .on
        menuBarChanged?()
    }

    @objc private func toggleAdaptiveRefresh() {
        model.preferences.adaptiveRefresh = adaptiveRefresh.state == .on
        adaptiveRefreshChanged?()
    }

    @objc private func toggleLaunchAtLogin() {
        let enabled = launchAtLogin.state == .on
        Task { await model.setOpensAtLogin(enabled) }
    }

    @objc private func togglePermission(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, let permission = Permission(rawValue: raw) else { return }
        model.setPermission(permission, allowed: sender.state == .on)
    }

    @objc private func registerAgent() {
        Task { await model.register(); await model.refresh() }
    }

    @objc private func unregisterAgentService() {
        Task {
            do {
                try await unregisterAgent()
                model.message = model.registrationStatus()
            } catch { model.message = Display.error(error) }
            await model.registrationChanged()
            await model.refresh()
        }
    }

    @objc private func showLoginItems() {
        openLoginItems()
    }

    @objc private func refreshDiagnostics() {
        Task { await model.refresh() }
    }

    @objc private func copyConfiguration() {
        do {
            let json = try model.configuration()
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(json, forType: .string)
            model.message = "MCP config copied"
        } catch { model.message = Display.error(error) }
        render()
    }
}
