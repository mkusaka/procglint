import ProcglintIPC
import ServiceManagement
import Testing

@Test func registrationStatusesMapWithoutServiceManagementCalls() throws {
    #expect(AgentRegistration.Status(.notRegistered) == .notRegistered)
    #expect(AgentRegistration.Status(.enabled) == .enabled)
    #expect(AgentRegistration.Status(.requiresApproval) == .requiresApproval)
    #expect(AgentRegistration.Status(.notFound) == .notFound)
    #expect(try AgentRegistration.Status(#require(SMAppService.Status(rawValue: 99))) == .notFound)
}
