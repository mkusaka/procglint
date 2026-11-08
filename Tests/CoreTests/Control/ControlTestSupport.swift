import Foundation
import ProcglintCore
import Synchronization
import Testing

struct ControlSignalCall: Sendable, Equatable {
    let pid: Int32
    let signal: Int32
}

final class ControlSignalRecorder: Sendable {
    let storage = Mutex<[ControlSignalCall]>([])
}

final class ControlFixture: Sendable {
    let directory: URL
    let url: URL
    let source = FakeProcessSource()
    let clock = FakeClock()
    let calls = ControlSignalRecorder()
    let controller: TerminationController
    let client = TerminationController.Client(clientID: "client-a", kind: .mcp, pid: 900,
                                              protectedPIDs: [900, 901, 902, 903])
    let key: ProcessKey

    init(sendSignal: @escaping @Sendable (Int32, Int32) -> Int32 = { _, _ in 0 }) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("procglint-control-\(UInt64.random(in: .min ... .max))")
        url = directory.appendingPathComponent("audit.jsonl")
        key = try ProcessKey("p1.fake-boot.42.10")
        source.addProcess(pid: 42, process: controlProcess())
        let calls = calls
        controller = TerminationController(source: source, clock: clock, auditLog: AuditLog(url: url), ownUID: 501) { pid, signal in
            calls.storage.withLock { $0.append(ControlSignalCall(pid: pid, signal: signal)) }
            return sendSignal(pid, signal)
        }
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    var signals: [ControlSignalCall] {
        calls.storage.withLock { $0 }
    }

    func entries() throws -> [AuditEntry] {
        try Data(contentsOf: url).split(separator: 0x0A).map {
            try ProcglintJSON.decoder().decode(AuditEntry.self, from: Data($0))
        }
    }

    func prepare(signal: TerminationSignal = .term, permissions: PermissionSet = [.terminate]) async throws -> TerminationTicket {
        try await controller.prepare(key: key, signal: signal, client: client, permissions: permissions)
    }

    func finish(_ ticket: TerminationTicket, afterSignal: () -> Void = {}) async throws -> TerminationResult {
        let task = Task { try await controller.terminate(token: ticket.token, client: client) }
        while clock.pendingSleepCount == 0 {
            await Task.yield()
        }
        afterSignal()
        clock.advance(by: 500_000_000)
        return try await task.value
    }
}

func controlProcess(start: UInt64 = 10, uid: UInt32 = 501, name: String = "worker", path: String? = "/bin/worker") -> FakeProcessSource.Process {
    FakeProcessSource.Process(rusage: RawRusage(startTimeUS: start),
                              bsdInfo: RawBSDInfo(name: name, uid: uid, ppid: 1, startTimeUS: start), path: path)
}

func expectControlRejection(_ rejection: TerminationRejection, operation: () async throws -> some Any) async {
    do {
        _ = try await operation()
        Issue.record("Expected termination_rejected: \(rejection)")
    } catch let error as AgentError {
        #expect(error.code == .terminationRejected)
        #expect(error.rejection == rejection)
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
}
