import AppKit
import ProcglintApp
import ProcglintCore

func makeMonitorService() -> any MonitorService {
    // swiftlint:disable:next todo
    UnavailableMonitorService() // TODO: Return ProcglintIPC.AgentClient once the XPC client is merged.
}

private struct UnavailableMonitorService: MonitorService {
    private var unavailable: AgentError {
        .agentUnavailable("The XPC client is not linked yet. Register/enable the agent in Settings after integration.")
    }

    func snapshot(top _: Int, sort _: ProcessSort) async throws -> Snapshot {
        throw unavailable
    }

    func listProcesses(_: ProcessQuery) async throws -> ProcessPage {
        throw unavailable
    }

    func process(key _: ProcessKey) async throws -> ProcessSample {
        throw unavailable
    }

    func history(_: HistoryRequest) async throws -> [HistorySeries] {
        throw unavailable
    }

    func status() async throws -> MonitorStatus {
        throw unavailable
    }

    func setLease(_: LeaseRequest) async throws -> SamplingLease {
        throw unavailable
    }

    func releaseLease(id _: String) async throws {
        throw unavailable
    }

    func startObservation(_: ObservationRequest) async throws -> Observation {
        throw unavailable
    }

    func stopObservation(id _: String) async throws {
        throw unavailable
    }

    func pin(key _: ProcessKey, pinned _: Bool) async throws {
        throw unavailable
    }

    func policy() async throws -> SamplingPolicy {
        throw unavailable
    }

    func setPolicy(_: SamplingPolicy, expectedRevision _: Int) async throws -> SamplingPolicy {
        throw unavailable
    }

    func prepareTermination(key _: ProcessKey, signal _: TerminationSignal) async throws -> TerminationTicket {
        throw unavailable
    }

    func terminate(token _: String) async throws -> TerminationResult {
        throw unavailable
    }
}

let application = NSApplication.shared
application.setActivationPolicy(.regular)
do {
    let delegate = try ProcglintApplication(
        service: makeMonitorService(),
        registrationStatus: { "Not connected to the ServiceManagement wrapper yet" },
        registerAgent: { throw AgentError.agentUnavailable("TODO: Wire the app-main registration closure to the ServiceManagement wrapper.") }
    )
    application.delegate = delegate
    withExtendedLifetime(delegate) { application.run() }
} catch {
    let alert = NSAlert()
    alert.messageText = "procglint could not open its settings"
    alert.informativeText = String(describing: error)
    alert.runModal()
}
