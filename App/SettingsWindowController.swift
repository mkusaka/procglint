import AppKit
import ProcglintCore
import SwiftUI

@MainActor
final class SettingsWindowController: NSWindowController {
    let model: SettingsViewModel
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
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 940),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "procglint Settings"
        window.setAccessibilityIdentifier("settingsWindow")
        window.minSize = NSSize(width: 640, height: 700)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        let content = NSHostingView(rootView: SettingsView(
            model: model, setMenuBar: { [weak self] in self?.setMenuBar($0) },
            setAdaptiveRefresh: { [weak self] in self?.setAdaptiveRefresh($0) },
            unregister: { [weak self] in
                guard let self else { return }
                Task { await self.model.unregister(using: self.unregisterAgent) }
            }, openLoginItems: { [weak self] in self?.showLoginItems() },
            copyConfiguration: { [weak self] in self?.copyConfiguration() }
        ))
        content.sizingOptions = []
        window.contentView = content
        window.setContentSize(NSSize(width: 760, height: 940))
        window.center()
        model.onChange = { [weak self] in self?.render() }
        render()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Programmatic UI only")
    }

    func render() {
        model.reloadRegistrationStatus()
    }

    func setMenuBar(_ enabled: Bool) {
        model.objectWillChange.send()
        model.preferences.menuBar = enabled
        menuBarChanged?()
    }

    func setAdaptiveRefresh(_ enabled: Bool) {
        model.objectWillChange.send()
        model.preferences.adaptiveRefresh = enabled
        adaptiveRefreshChanged?()
    }

    private func showLoginItems() {
        openLoginItems()
        Task {
            await model.registrationChanged()
            await model.refresh()
        }
    }

    private func copyConfiguration() {
        do {
            let json = try model.configuration()
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(json, forType: .string)
            model.message = "MCP config copied"
        } catch { model.message = Display.error(error) }
    }
}
