import Foundation
import ProcglintCore
import ProcglintIPC

/// A lease holder, not a GUI: build separately so no shipping target needs a debug command.
@main struct BenchmarkLeaseClient {
    static func main() async throws {
        let client = AgentClient(clientKind: .gui)
        let request = try LeaseRequest(kind: .guiWindow, intervalMS: .fiveSeconds)
        _ = try await client.setLease(request)
        FileHandle.standardOutput.write(Data("lease ready\n".utf8))
        while true {
            try await Task.sleep(nanoseconds: 10_000_000_000)
            _ = try await client.setLease(request)
        }
    }
}
