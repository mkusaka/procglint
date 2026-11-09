import ProcglintIPC
import ServiceManagement

@MainActor
struct LoginItemService {
    var status: @MainActor () -> AgentRegistration.Status
    var register: @MainActor () throws -> Void
    var unregister: @MainActor () async throws -> Void

    static var mainApp: Self {
        Self(status: { AgentRegistration.Status(SMAppService.mainApp.status) },
             register: { try SMAppService.mainApp.register() },
             unregister: {
                 // The completion API keeps the non-Sendable service on the main actor.
                 try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                     SMAppService.mainApp.unregister { error in
                         if let error {
                             continuation.resume(throwing: error)
                         } else {
                             continuation.resume()
                         }
                     }
                 }
             })
    }
}
