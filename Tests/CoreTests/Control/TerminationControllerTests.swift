import Darwin
import Foundation
import ProcglintCore
import Testing

@Suite(.timeLimit(.minutes(1)))
struct TerminationControllerTests {
    @Test(arguments: [Int32(0), 1, 900, 901, 902, 903, getpid()])
    func protectedTargets(pid: Int32) async throws {
        let fixture = try ControlFixture()
        let key = try ProcessKey(identity: ProcessIdentity(bootSessionID: "fake-boot", pid: pid, startTimeUS: 10))
        let expected: TerminationRejection = pid <= 1 ? .protectedPID : .self
        await expectControlRejection(expected) {
            try await fixture.controller.prepare(key: key, signal: .term, client: fixture.client, permissions: [.terminate])
        }
        #expect(fixture.signals.isEmpty)
        #expect(try fixture.entries().map(\.outcome) == ["rejected"])
        #expect(try fixture.entries().first?.rejection == expected)
    }

    @Test func permissions() async throws {
        let fixture = try ControlFixture()
        for signal in TerminationSignal.allCases {
            await expectControlRejection(.permissionDenied) { try await fixture.prepare(signal: signal, permissions: []) }
        }
        await expectControlRejection(.permissionDenied) { try await fixture.prepare(signal: .kill) }
        await expectControlRejection(.permissionDenied) { try await fixture.prepare(signal: .kill, permissions: [.forceKill]) }
        #expect(try fixture.entries().count == 4)
        #expect(try fixture.entries().allSatisfy { $0.outcome == "rejected" && $0.rejection == .permissionDenied })
        #expect(fixture.signals.isEmpty)
    }

    @Test func notOwnProcess() async throws {
        let fixture = try ControlFixture()
        fixture.source.addProcess(pid: 42, process: controlProcess(uid: 502))
        await expectControlRejection(.notOwnProcess) { try await fixture.prepare() }
        let entry = try #require(fixture.entries().first)
        #expect(entry.name == "worker")
        #expect(entry.rejection == .notOwnProcess)
        #expect(fixture.signals.isEmpty)
    }

    @Test(arguments: ["start", "boot", "inconsistent_start"])
    func staleKeyAtPrepare(change: String) async throws {
        let fixture = try ControlFixture()
        switch change {
        case "start": fixture.source.addProcess(pid: 42, process: controlProcess(start: 11))
        case "boot": fixture.source.update { $0.bootSessionID = "other-boot" }
        default: fixture.source.setRusage(pid: 42, rusage: RawRusage(startTimeUS: 11))
        }
        await expectControlRejection(.processChanged) { try await fixture.prepare() }
        #expect(try fixture.entries().first?.rejection == .processChanged)
        #expect(fixture.signals.isEmpty)
    }

    @Test(arguments: ["missing", "exited", "permission", "sampling_exit"])
    func sourceRejectionsAtPrepare(failure: String) async throws {
        let fixture = try ControlFixture()
        var rejection = TerminationRejection.exited
        switch failure {
        case "missing": fixture.source.removeProcess(pid: 42)
        case "exited": fixture.source.update { $0.processErrors[42] = .exited }
        case "permission":
            fixture.source.update { $0.processErrors[42] = .permissionDenied }
            rejection = .permissionDenied
        default: fixture.source.update { $0.exitDuringSample.insert(42) }
        }
        await expectControlRejection(rejection) { try await fixture.prepare() }
        #expect(try fixture.entries().first?.rejection == rejection)
        #expect(fixture.signals.isEmpty)
    }

    @Test func ticketAndPrepareAudit() async throws {
        let fixture = try ControlFixture()
        let before = Date()
        let ticket = try await fixture.prepare()
        let after = Date()
        #expect(ticket.token.utf8.count == 32)
        #expect(ticket.token.utf8.allSatisfy { (48 ... 57).contains($0) || (97 ... 102).contains($0) })
        #expect(ticket.processKey == fixture.key)
        #expect(ticket.pid == 42)
        #expect(ticket.name == "worker")
        #expect(ticket.signal == .term)
        #expect(ticket.expiresAt >= before.addingTimeInterval(30))
        #expect(ticket.expiresAt <= after.addingTimeInterval(30))
        let entry = try #require(fixture.entries().first)
        #expect(entry.clientKind == .mcp)
        #expect(entry.clientPID == fixture.client.pid)
        #expect(entry.processKey == ticket.processKey)
        #expect(entry.pid == ticket.pid)
        #expect(entry.name == ticket.name)
        #expect(entry.signal == ticket.signal)
        #expect(entry.outcome == "issued")
        #expect(entry.rejection == nil)
        #expect(fixture.signals.isEmpty)
    }

    @Test(arguments: ["start", "uid", "name", "path", "missing_path", "boot", "uuid", "inconsistent_start"])
    func revalidatesBeforeSignal(change: String) async throws {
        let fixture = try ControlFixture()
        let ticket = try await fixture.prepare()
        fixture.source.removeProcess(pid: 42)
        fixture.source.addProcess(pid: 42, process: controlProcess())
        fixture.source.update { state in
            switch change {
            case "start": state.processes[42] = controlProcess(start: 11)
            case "uid": state.processes[42]?.bsdInfo.uid = 502
            case "name": state.processes[42]?.bsdInfo.name = "replacement"
            case "path": state.processes[42]?.path = "/bin/replacement"
            case "missing_path": state.processes[42]?.path = nil
            case "boot": state.bootSessionID = "other-boot"
            case "uuid": state.processes[42]?.rusage.executableUUID = UUID()
            default: state.processes[42]?.rusage.startTimeUS = 11
            }
        }
        let result = try await fixture.controller.terminate(token: ticket.token, client: fixture.client)
        #expect(result.outcome == .rejected)
        #expect(result.rejection == .processChanged)
        #expect(!result.exitedConfirmed)
        #expect(fixture.signals.isEmpty)
        #expect(try fixture.entries().map(\.outcome) == ["issued", "rejected"])
        #expect(try fixture.entries().last?.rejection == .processChanged)
        let retry = try await fixture.controller.terminate(token: ticket.token, client: fixture.client)
        #expect(retry.rejection == .tokenUsed)
    }

    @Test(arguments: ["missing", "exited", "permission", "sampling_exit"])
    func sourceRejectionsAtTerminate(failure: String) async throws {
        let fixture = try ControlFixture()
        let ticket = try await fixture.prepare()
        var rejection = TerminationRejection.exited
        switch failure {
        case "missing": fixture.source.removeProcess(pid: 42)
        case "exited": fixture.source.update { $0.processErrors[42] = .exited }
        case "permission":
            fixture.source.update { $0.processErrors[42] = .permissionDenied }
            rejection = .permissionDenied
        default: fixture.source.update { $0.exitDuringSample.insert(42) }
        }
        let result = try await fixture.controller.terminate(token: ticket.token, client: fixture.client)
        #expect(result.rejection == rejection)
        #expect(result.outcome == .rejected)
        #expect(fixture.signals.isEmpty)
        #expect(try fixture.entries().last?.rejection == rejection)
    }

    @Test(arguments: ["id", "pid", "kind"])
    func foreignClientDoesNotConsumeTicket(change: String) async throws {
        let fixture = try ControlFixture()
        let ticket = try await fixture.prepare()
        let foreign = TerminationController.Client(clientID: change == "id" ? "client-b" : fixture.client.clientID,
                                                   kind: change == "kind" ? .gui : fixture.client.kind,
                                                   pid: change == "pid" ? 904 : fixture.client.pid,
                                                   protectedPIDs: [])
        let result = try await fixture.controller.terminate(token: ticket.token, client: foreign)
        #expect(result.rejection == .tokenForeign)
        #expect(fixture.signals.isEmpty)
        #expect(try fixture.entries().last?.rejection == .tokenForeign)
        #expect(try await fixture.finish(ticket).outcome == .signalSent)
        #expect(fixture.signals.count == 1)
    }

    @Test func expiryUsesMonotonicTime() async throws {
        let fixture = try ControlFixture()
        let ticket = try await fixture.prepare()
        fixture.clock.advance(by: 30_000_000_000)
        let result = try await fixture.controller.terminate(token: ticket.token, client: fixture.client)
        #expect(result.rejection == .tokenExpired)
        #expect(fixture.signals.isEmpty)
        #expect(try fixture.entries().last?.rejection == .tokenExpired)
    }

    @Test func usableImmediatelyBeforeExpiry() async throws {
        let fixture = try ControlFixture()
        let ticket = try await fixture.prepare()
        fixture.clock.advance(by: 29_999_999_999)
        #expect(try await fixture.finish(ticket).outcome == .signalSent)
        #expect(fixture.signals.count == 1)
    }

    @Test func singleUseWhileAwaitingConfirmation() async throws {
        let fixture = try ControlFixture()
        let ticket = try await fixture.prepare()
        let first = Task { try await fixture.controller.terminate(token: ticket.token, client: fixture.client) }
        while fixture.clock.pendingSleepCount == 0 {
            await Task.yield()
        }
        let retry = try await fixture.controller.terminate(token: ticket.token, client: fixture.client)
        #expect(retry.rejection == .tokenUsed)
        #expect(fixture.signals.count == 1)
        fixture.clock.advance(by: 500_000_000)
        #expect(try await first.value.outcome == .signalSent)
        #expect(try fixture.entries().map(\.outcome) == ["issued", "signal_sent", "rejected"])
        #expect(try fixture.entries().last?.rejection == .tokenUsed)
    }

    @Test func protectionIsRefreshedPerRequest() async throws {
        let fixture = try ControlFixture()
        let ticket = try await fixture.prepare()
        let updated = TerminationController.Client(clientID: fixture.client.clientID, kind: fixture.client.kind,
                                                   pid: fixture.client.pid, protectedPIDs: [42])
        let result = try await fixture.controller.terminate(token: ticket.token, client: updated)
        #expect(result.rejection == .self)
        #expect(fixture.signals.isEmpty)
        #expect(try fixture.entries().last?.rejection == .self)
    }

    @Test func requestingPIDIsProtectedEvenWithoutProviderEntries() async throws {
        let fixture = try ControlFixture()
        let client = TerminationController.Client(clientID: "client-a", kind: .cli, pid: 42, protectedPIDs: [])
        await expectControlRejection(.self) {
            try await fixture.controller.prepare(key: fixture.key, signal: .term, client: client, permissions: [.terminate])
        }
        #expect(fixture.signals.isEmpty)
        #expect(try fixture.entries().first?.rejection == .self)
    }

    @Test func confirmationWaits500Milliseconds() async throws {
        let fixture = try ControlFixture()
        let ticket = try await fixture.prepare()
        let task = Task { try await fixture.controller.terminate(token: ticket.token, client: fixture.client) }
        while fixture.clock.pendingSleepCount == 0 {
            await Task.yield()
        }
        fixture.source.removeProcess(pid: 42)
        fixture.clock.advance(by: 499_999_999)
        #expect(fixture.clock.pendingSleepCount == 1)
        fixture.clock.advance(by: 1)
        #expect(try await task.value.exitedConfirmed)
        #expect(fixture.clock.pendingSleepCount == 0)
        #expect(fixture.signals.count == 1)
    }

    @Test(arguments: [TerminationSignal.term, .kill])
    func signalNumbersAndNoEscalation(signal: TerminationSignal) async throws {
        let fixture = try ControlFixture()
        let ticket = try await fixture.prepare(signal: signal, permissions: [.terminate, .forceKill])
        let result = try await fixture.finish(ticket)
        #expect(result.outcome == .signalSent)
        #expect(result.rejection == nil)
        #expect(!result.exitedConfirmed)
        fixture.clock.advance(by: 60_000_000_000)
        #expect(fixture.signals == [ControlSignalCall(pid: 42, signal: signal == .term ? SIGTERM : SIGKILL)])
        let entries = try fixture.entries()
        #expect(entries.map(\.outcome) == ["issued", "signal_sent"])
        #expect(entries.last?.signal == signal)
        #expect(entries.last?.rejection == nil)
    }

    @Test(arguments: ["gone", "reused", "unreadable", "exited_error", "exec"])
    func confirmationChecksOriginalIdentity(change: String) async throws {
        let fixture = try ControlFixture()
        let ticket = try await fixture.prepare()
        let result = try await fixture.finish(ticket) {
            switch change {
            case "gone": fixture.source.removeProcess(pid: 42)
            case "reused": fixture.source.addProcess(pid: 42, process: controlProcess(start: 11))
            case "unreadable": fixture.source.update { $0.processErrors[42] = .permissionDenied }
            case "exited_error": fixture.source.update { $0.processErrors[42] = .exited }
            default: fixture.source.addProcess(pid: 42, process: controlProcess(name: "other", path: "/bin/other"))
            }
        }
        #expect(result.outcome == .signalSent)
        #expect(result.exitedConfirmed == ["gone", "reused", "exited_error"].contains(change))
        #expect(fixture.signals == [ControlSignalCall(pid: 42, signal: SIGTERM)])
    }

    @Test(arguments: [ESRCH, EPERM, EACCES])
    func signalErrors(error: Int32) async throws {
        let fixture = try ControlFixture { _, _ in error }
        let ticket = try await fixture.prepare()
        let result = try await fixture.controller.terminate(token: ticket.token, client: fixture.client)
        #expect(result.outcome == .rejected)
        #expect(result.rejection == (error == ESRCH ? .exited : .permissionDenied))
        #expect(!result.exitedConfirmed)
        #expect(fixture.signals == [ControlSignalCall(pid: 42, signal: SIGTERM)])
        #expect(try fixture.entries().last?.rejection == result.rejection)
        #expect(try await fixture.controller.terminate(token: ticket.token, client: fixture.client).rejection == .tokenUsed)
    }

    @Test func unexpectedSignalErrorSurfaces() async throws {
        let fixture = try ControlFixture { _, _ in EINVAL }
        let ticket = try await fixture.prepare()
        do {
            _ = try await fixture.controller.terminate(token: ticket.token, client: fixture.client)
            Issue.record("Expected kill failure")
        } catch let error as AgentError {
            #expect(error.code == .internalError)
            #expect(error.message.contains("errno"))
        }
        #expect(try fixture.entries().last?.outcome == "rejected")
        #expect(fixture.signals.count == 1)
    }

    @Test func unexpectedSourceErrorsSurfaceAndAreAudited() async throws {
        let fixture = try ControlFixture()
        fixture.source.update { $0.processErrors[42] = .unavailable("test failure") }
        do {
            _ = try await fixture.prepare()
            Issue.record("Expected source failure")
        } catch let error as AgentError {
            #expect(error.code == .internalError)
        }
        fixture.source.update { $0.processErrors[42] = nil }
        let ticket = try await fixture.prepare()
        fixture.source.update { $0.processErrors[42] = .unavailable("test failure") }
        do {
            _ = try await fixture.controller.terminate(token: ticket.token, client: fixture.client)
            Issue.record("Expected source failure")
        } catch let error as AgentError {
            #expect(error.code == .internalError)
        }
        #expect(try fixture.entries().map(\.outcome) == ["rejected", "issued", "rejected"])
        #expect(fixture.signals.isEmpty)
    }

    @Test func cancellationBeforeSignalConsumesAndAuditsToken() async throws {
        let fixture = try ControlFixture()
        let ticket = try await fixture.prepare()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await fixture.controller.terminate(token: ticket.token, client: fixture.client)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(fixture.signals.isEmpty)
        #expect(try fixture.entries().map(\.outcome) == ["issued", "rejected"])
        #expect(try await fixture.controller.terminate(token: ticket.token, client: fixture.client).rejection == .tokenUsed)
    }

    @Test func cancelledConfirmationDoesNotResend() async throws {
        let fixture = try ControlFixture()
        let ticket = try await fixture.prepare()
        let task = Task { try await fixture.controller.terminate(token: ticket.token, client: fixture.client) }
        while fixture.clock.pendingSleepCount == 0 {
            await Task.yield()
        }
        task.cancel()
        let result = try await task.value
        #expect(result.outcome == .signalSent)
        #expect(!result.exitedConfirmed)
        #expect(fixture.signals.count == 1)
        #expect(try fixture.entries().map(\.outcome) == ["issued", "signal_sent"])
    }

    @Test func unknownAndInvalidatedTokensHaveNoInventedAuditTarget() async throws {
        let fixture = try ControlFixture()
        let ticket = try await fixture.prepare()
        await fixture.controller.invalidateAll()
        for token in ["tok-unknown", ticket.token] {
            let result = try await fixture.controller.terminate(token: token, client: fixture.client)
            #expect(result.rejection == .tokenUsed)
        }
        let lines = try Data(contentsOf: fixture.url).split(separator: 0x0A)
        #expect(lines.count == 3)
        for line in lines.dropFirst() {
            let object = try #require(JSONSerialization.jsonObject(with: Data(line)) as? [String: Any])
            #expect(object["process_key"] is NSNull)
            #expect(object["pid"] is NSNull)
            #expect(object["name"] is NSNull)
            #expect(object["signal"] is NSNull)
            #expect(object["outcome"] as? String == "rejected")
            #expect(object["rejection"] as? String == "token_used")
            #expect(object["client_pid"] as? Int == 900)
        }
        #expect(fixture.signals.isEmpty)
    }

    @Test func boundedTokenTableAndExpiredEviction() async throws {
        let fixture = try ControlFixture()
        var tickets: [TerminationTicket] = []
        for _ in 0 ..< 65 {
            try await tickets.append(fixture.prepare())
            fixture.clock.advance(by: 1)
        }
        #expect(Set(tickets.map(\.token)).count == 65)
        let first = try #require(tickets.first)
        let last = try #require(tickets.last)
        #expect(try await fixture.controller.terminate(token: first.token, client: fixture.client).rejection == .tokenUsed)
        #expect(try await fixture.finish(last).outcome == .signalSent)
        fixture.clock.advance(by: 30_000_000_000)
        let fresh = try await fixture.prepare()
        #expect(try await fixture.controller.terminate(token: tickets[1].token, client: fixture.client).rejection == .tokenUsed)
        #expect(try await fixture.finish(fresh).outcome == .signalSent)
        #expect(fixture.signals.count == 2)
    }
}
