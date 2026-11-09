import Foundation
@testable import ProcglintApp
import ProcglintCore
import ProcglintIPC
import Testing

@MainActor
struct SettingsPresentationTests {
    @Test(arguments: [AgentRegistration.Status.notRegistered, .notFound, .requiresApproval, .enabled])
    func registrationActionsReflectTypedStatus(status: AgentRegistration.Status) {
        for reachable in [false, true] {
            let setup = AgentSetup(status: status, reachable: reachable)
            #expect(setup.canRegister == (status == .notRegistered || status == .notFound))
            #expect(setup.canUnregister == (status == .enabled || status == .requiresApproval))
            #expect(setup.needsApproval == (status == .requiresApproval))
            #expect(setup.showsBanner == !reachable)
            #expect(!setup.explanation.isEmpty)
        }
        #expect(AgentSetup(status: .notFound, reachable: false).title == "Not registered")
    }

    @Test func registrationApprovalAndRemovalPublishNewSettingsState() async throws {
        let prefs = preferences()
        defer { prefs.defaults.removePersistentDomain(forName: prefs.store.suiteName ?? "") }
        var status = AgentRegistration.Status.notFound
        var registrations = 0
        var removals = 0
        let model = try SettingsViewModel(service: FakeMonitorService(), preferences: prefs, helperURL: nil,
                                          registrationStatus: { "test" }, registerAgent: {
                                              registrations += 1
                                              status = .requiresApproval
                                          }, agentStatus: { status })
        await model.register()
        #expect(registrations == 1)
        #expect(model.agentSetup.needsApproval)
        #expect(!model.changingRegistration)
        await model.register()
        #expect(registrations == 1)
        status = .enabled
        await model.refresh()
        #expect(model.agentSetup.title == "Registered · Connected")
        let gate = RequestGate()
        let removal = Task {
            await model.unregister {
                removals += 1
                await gate.suspend()
                status = .notRegistered
            }
        }
        await gate.waitUntilEntered()
        #expect(model.changingRegistration)
        await model.unregister { removals += 1 }
        #expect(removals == 1)
        gate.resume()
        await removal.value
        #expect(!model.changingRegistration)
        #expect(model.agentSetup.canRegister)
        #expect(!model.agentSetup.canUnregister)
    }

    @Test func registrationFailureKeepsRecoveryActionAndPrivacyBindingsPersistEveryPermission() async throws {
        let prefs = preferences()
        defer { prefs.defaults.removePersistentDomain(forName: prefs.store.suiteName ?? "") }
        let model = try SettingsViewModel(service: FakeMonitorService(), preferences: prefs, helperURL: nil,
                                          registrationStatus: { "not found" }, registerAgent: {
                                              throw AgentError.permissionDenied("Fixture registration failed")
                                          }, agentStatus: { .notFound })
        await model.register()
        #expect(model.agentSetup.canRegister)
        #expect(model.message.contains("Fixture registration failed"))
        #expect(model.registrationError.contains("Fixture registration failed"))
        for permission in Permission.allCases {
            model.setPermission(permission, allowed: true)
            #expect(model.permissions.contains(permission))
            #expect(try prefs.store.allowedPermissions().contains(permission))
            model.setPermission(permission, allowed: false)
            #expect(!model.permissions.contains(permission))
            #expect(try !prefs.store.allowedPermissions().contains(permission))
        }
    }
}
