import AppKit
@testable import ProcglintApp
import ProcglintCore
import ProcglintIPC
import Testing

@MainActor
private final class RegistrationSpy {
    var status = AgentRegistration.Status.notRegistered
    var registrations = 0
    var removals = 0
    var fail = false
}

@MainActor
@Test func bannerTracksRegistrationReachabilityAndRecovery() async throws {
    _ = NSApplication.shared
    let prefs = preferences()
    defer { prefs.defaults.removePersistentDomain(forName: prefs.store.suiteName ?? "") }
    let service = try FakeMonitorService(rows: [sample()])
    let spy = RegistrationSpy()
    let model = try MonitorViewModel(service: service, preferences: prefs, registrationStatus: { spy.status })
    let controller = MainWindowController(model: model, register: { spy.registrations += 1 })
    defer { controller.window?.close() }
    controller.render()
    #expect(!controller.agentBanner.isHidden)
    #expect(controller.table.isHidden)
    #expect(controller.dataSource.numberOfRows(in: controller.table) == 0)
    #expect(spy.registrations == 0)

    await model.setVisibility(window: true, menuBar: false)
    for state in [AgentRegistration.Status.notRegistered, .notFound, .requiresApproval, .enabled] {
        spy.status = state
        controller.render()
        #expect(!model.showsAgentBanner)
        #expect(controller.agentBanner.isHidden)
        #expect(controller.loginItems.isHidden == (state != .requiresApproval))
    }
    #expect(spy.registrations == 0)
    service.snapshotError = .agentUnavailable("disconnected")
    await model.tick()
    controller.render()
    #expect(!controller.agentBanner.isHidden)
    #expect(controller.table.isHidden)
    #expect(model.rows.count == 1) // A connection failure must not invent process exits.
    #expect(controller.registerAgent.title == "Retry connection")
    controller.registerAgent.performClick(nil)
    #expect(spy.registrations == 0)
    spy.status = .notRegistered
    controller.render()
    controller.registerAgent.performClick(nil)
    #expect(spy.registrations == 1)
    spy.status = .enabled
    service.snapshotError = nil
    await model.tick()
    controller.render()
    #expect(controller.agentBanner.isHidden)
    #expect(!controller.table.isHidden)
}

@MainActor
@Test func registrationActionRechecksEvenAfterFailure() async throws {
    let prefs = preferences()
    defer { prefs.defaults.removePersistentDomain(forName: prefs.store.suiteName ?? "") }
    var attempts = 0
    var rechecks = 0
    let settings = try SettingsViewModel(service: FakeMonitorService(), preferences: prefs, helperURL: nil,
                                         registrationStatus: { "Requires approval" }, registerAgent: {
                                             attempts += 1
                                             throw AgentError.permissionDenied("Registration denied")
                                         })
    settings.onRegistrationChanged = { rechecks += 1 }
    #expect(attempts == 0)
    await settings.register()
    #expect(attempts == 1)
    #expect(rechecks == 1)
    #expect(settings.message.contains("Registration denied"))
}

@MainActor
@Test func launchAtLoginIsClickOnlyAndReflectsApprovalAndFailures() async throws {
    let prefs = preferences()
    defer { prefs.defaults.removePersistentDomain(forName: prefs.store.suiteName ?? "") }
    let spy = RegistrationSpy()
    let loginItem = LoginItemService(status: { spy.status }, register: {
        spy.registrations += 1
        if spy.fail {
            throw AgentError.permissionDenied("Cannot register login item")
        }
        spy.status = .requiresApproval
    }, unregister: {
        spy.removals += 1
        if spy.fail {
            throw AgentError.permissionDenied("Cannot unregister login item")
        }
        spy.status = .notRegistered
    })
    let settings = try SettingsViewModel(service: FakeMonitorService(), preferences: prefs, helperURL: nil,
                                         registrationStatus: { "Enabled" }, registerAgent: {}, loginItem: loginItem)
    #expect(!settings.opensAtLogin)
    #expect(settings.loginItemHint.isEmpty)
    await settings.refresh()
    #expect(spy.registrations == 0 && spy.removals == 0)
    await settings.setOpensAtLogin(true)
    #expect(spy.registrations == 1)
    #expect(settings.opensAtLogin)
    #expect(settings.loginItemHint.contains("Approve procglint"))
    spy.status = .enabled
    #expect(settings.opensAtLogin)
    #expect(settings.loginItemHint.isEmpty)
    spy.fail = true
    await settings.setOpensAtLogin(false)
    #expect(settings.opensAtLogin)
    #expect(settings.message.contains("Cannot unregister"))
    #expect(!settings.changingLoginItem)
    spy.fail = false
    await settings.setOpensAtLogin(false)
    #expect(!settings.opensAtLogin)
    #expect(spy.removals == 2)
    spy.fail = true
    await settings.setOpensAtLogin(true)
    #expect(!settings.opensAtLogin)
    #expect(settings.message.contains("Cannot register"))
    spy.status = .notFound
    #expect(settings.loginItemHint.isEmpty)
}

@MainActor
@Test func launchAtLoginSerializesChangesAndShowsApprovalControls() async throws {
    _ = NSApplication.shared
    let prefs = preferences()
    defer { prefs.defaults.removePersistentDomain(forName: prefs.store.suiteName ?? "") }
    let spy = RegistrationSpy()
    spy.status = .requiresApproval
    let gate = RequestGate()
    let loginItem = LoginItemService(status: { spy.status }, register: { spy.registrations += 1 }, unregister: {
        await gate.suspend()
        spy.status = .notRegistered
    })
    let settings = try SettingsViewModel(service: FakeMonitorService(), preferences: prefs, helperURL: nil,
                                         registrationStatus: { "Enabled" }, registerAgent: {}, loginItem: loginItem)
    let controller = SettingsWindowController(model: settings, unregisterAgent: {}, openLoginItems: {})
    defer { controller.window?.close() }
    #expect(settings.opensAtLogin)
    #expect(!settings.loginItemHint.isEmpty)
    #expect(settings.loginItem.status() == .requiresApproval)
    let removal = Task { await settings.setOpensAtLogin(false) }
    await gate.waitUntilEntered()
    #expect(settings.changingLoginItem)
    await settings.setOpensAtLogin(true)
    #expect(spy.registrations == 0)
    gate.resume()
    await removal.value
    #expect(!settings.changingLoginItem)
    #expect(!settings.opensAtLogin)
    #expect(settings.loginItemHint.isEmpty)
    #expect(settings.loginItem.status() != .requiresApproval)
}

@MainActor
@Test func unregisteredUIFixtureRecoversWithoutRealServices() async throws {
    let fixture = try UITestingFixture(unregistered: true)
    let prefs = try fixture.preferences()
    defer { fixture.cleanUp() }
    let model = try MonitorViewModel(service: fixture, preferences: prefs,
                                     registrationStatus: { fixture.agentRegistered ? .enabled : .notRegistered })
    await model.setVisibility(window: true, menuBar: false)
    #expect(model.showsAgentBanner)
    #expect(!model.agentReachable)
    #expect(model.rows.isEmpty)
    fixture.agentRegistered = true
    await model.tick()
    #expect(!model.showsAgentBanner)
    #expect(model.rows.count == 20)
    #expect(fixture.loginItem.status() == .notRegistered)
    try fixture.loginItem.register()
    #expect(fixture.loginItem.status() == .enabled)
    try await fixture.loginItem.unregister()
    #expect(fixture.loginItem.status() == .notRegistered)
}

@Test func aboutVersionUsesMarketingVersionAndCommitWithSafeFallbacks() {
    #expect(AppVersion.description(info: ["CFBundleShortVersionString": "1.0.0", "ProcglintGitCommit": "abc1234"]) == "1.0.0 (abc1234)")
    #expect(AppVersion.description(info: ["CFBundleShortVersionString": "1.0.0", "ProcglintGitCommit": "abc1234-dirty"]) == "1.0.0 (abc1234-dirty)")
    #expect(AppVersion.description(info: ["CFBundleShortVersionString": "1.0.0"]) == "1.0.0 (unknown)")
    #expect(AppVersion.description(info: ["CFBundleShortVersionString": "$(MARKETING_VERSION)", "ProcglintGitCommit": " "]) == "unknown (unknown)")
    #expect(AppVersion.description(info: nil) == "unknown (unknown)")
}
