import ServiceManagement

@MainActor
public struct AgentRegistration {
    public enum Status: Sendable, Equatable {
        case notRegistered, enabled, requiresApproval, notFound

        public init(_ status: SMAppService.Status) {
            switch status {
            case .notRegistered: self = .notRegistered
            case .enabled: self = .enabled
            case .requiresApproval: self = .requiresApproval
            case .notFound: self = .notFound
            @unknown default: self = .notFound
            }
        }
    }

    private let service: SMAppService

    public init() {
        service = .agent(plistName: "io.github.mkusaka.procglint.agent.plist")
    }

    public var status: Status {
        Status(service.status)
    }

    public func register() throws {
        try service.register()
    }

    public func unregister() async throws {
        try await service.unregister()
    }

    public func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
