import AppKit
import ProcglintApp
import ProcglintCore
import ProcglintIPC

func makeMonitorService() -> any MonitorService {
    AgentClient(clientKind: .gui, onReconnect: {
        Task { @MainActor in
            await (NSApp.delegate as? ProcglintApplication)?.agentDidReconnect()
        }
    })
}

let application = NSApplication.shared
application.setActivationPolicy(.regular)
do {
    let registration = AgentRegistration()
    let delegate = try ProcglintApplication(
        service: makeMonitorService(),
        registrationStatus: {
            switch registration.status {
            case .notRegistered: "Not registered"
            case .enabled: "Enabled"
            case .requiresApproval: "Requires approval in System Settings → General → Login Items"
            case .notFound: "Not found — reinstall the complete Procglint.app"
            }
        },
        registerAgent: { try registration.register() },
        unregisterAgent: { try await registration.unregister() },
        openLoginItems: { registration.openLoginItemsSettings() }
    )
    application.delegate = delegate
    withExtendedLifetime(delegate) { application.run() }
} catch {
    let alert = NSAlert()
    alert.messageText = "procglint could not open its settings"
    alert.informativeText = String(describing: error)
    alert.runModal()
}
