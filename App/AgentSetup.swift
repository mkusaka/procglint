import ProcglintIPC

struct AgentSetup {
    let status: AgentRegistration.Status
    let reachable: Bool

    var canRegister: Bool {
        status == .notRegistered || status == .notFound
    }

    var canUnregister: Bool {
        status == .enabled || status == .requiresApproval
    }

    var needsApproval: Bool {
        status == .requiresApproval
    }

    var showsBanner: Bool {
        !reachable
    }

    var title: String {
        if reachable, status == .notFound || status == .notRegistered {
            return "Connected"
        }
        return switch status {
        case .notRegistered, .notFound: "Not registered"
        case .requiresApproval: "Approval required"
        case .enabled: reachable ? "Registered · Connected" : "Registered · Not responding"
        }
    }

    var explanation: String {
        if reachable, status == .notFound || status == .notRegistered {
            return "The agent is responding. Registration may be managed by another installed copy or a development agent."
        }
        return switch status {
        case .notRegistered: "Register the background agent to start monitoring. Registration only happens when you choose Register agent."
        // SMAppService also returns notFound before the first registration, not just for a missing bundle.
        case .notFound: "No registered background service was found. Choose Register agent; if that fails, reinstall the complete Procglint.app."
        case .requiresApproval: "Allow procglint in System Settings → General → Login Items & Extensions, then return here to re-check."
        case .enabled: reachable ? "The background agent is enabled and responding." : "The agent is registered but not responding. Retry the connection, or check Login Items and diagnostics in Settings."
        }
    }
}
