import Foundation
@testable import ProcglintAgentKit
import ProcglintCore
import ProcglintIPC
@testable import ProcglintMCPKit
import Testing

@Suite(.timeLimit(.minutes(1)))
struct AgentBoundaryTests {
    @Test(arguments: ["prepare-terminate", "prepare-force-kill", "prepare-parent", "prepare-cycle",
                      "terminate-permission", "terminate-force-kill", "terminate-parent", "terminate-unknown"])
    func terminationPreflightDenialsAreAudited(scenario: String) async throws {
        let h = try AgentHarness()
        let client = h.client(flags: .all)
        let key = try h.key()
        let executing = scenario.hasPrefix("terminate-")
        let kill = scenario.contains("force-kill")
        let ticket = executing && scenario != "terminate-unknown" ? try await client.prepareTermination(key: key, signal: kill ? .kill : .term) : nil
        if scenario.contains("parent") {
            h.source.update { $0.processes[getpid()]?.bsdInfo.ppid = 999 }
        } else if scenario.contains("cycle") {
            h.source.update { $0.processes[getpid()]?.bsdInfo.ppid = getpid() }
        } else {
            var allowed = PermissionSet.all
            allowed.remove(kill ? .forceKill : .terminate)
            h.settings.setAllowedPermissions(allowed)
        }
        let expectedCode: AgentError.Code = scenario.contains("parent") || scenario.contains("cycle") ? .terminationRejected : .permissionDenied
        await integrationError(expectedCode) {
            if executing {
                _ = try await client.terminate(token: ticket?.token ?? "unknown")
            } else {
                _ = try await client.prepareTermination(key: key, signal: kill ? .kill : .term)
            }
        }
        let url = h.directory.appendingPathComponent("audit.jsonl")
        let data = try Data(contentsOf: url)
        let entries = try data.split(separator: 10).map { try JSONValue.parse(Data($0)) }
        #expect(entries.count == (ticket == nil ? 1 : 2))
        let last = try #require(entries.last)
        #expect(last["outcome"] == "rejected")
        #expect(last["rejection"] == "permission_denied")
        #expect(last["client_kind"] == "mcp")
        #expect(try last["client_pid"]?.decode(Int32.self) == getpid())
        if scenario == "terminate-unknown" {
            #expect(last["process_key"] == .null)
        } else {
            #expect(last["process_key"] == .string(key.rawValue))
            #expect(last["signal"] == .string(kill ? "kill" : "term"))
        }
        #expect(h.signals.pids.withLock { $0.isEmpty })
        await client.invalidate()
        await h.close()
    }

    @Test func terminationAdmissionRateLimitDenialsAreAuditedWithoutInventingARejection() async throws {
        let h = try AgentHarness()
        let client = h.client()
        for _ in 0 ..< 20 {
            await integrationError(.permissionDenied) { _ = try await client.prepareTermination(key: h.key(), signal: .term) }
        }
        await integrationError(.rateLimited) { _ = try await client.prepareTermination(key: h.key(), signal: .term) }
        await integrationError(.rateLimited) { _ = try await client.terminate(token: "unknown") }
        let data = try Data(contentsOf: h.directory.appendingPathComponent("audit.jsonl"))
        let entries = try data.split(separator: 10).map { try JSONValue.parse(Data($0)) }
        #expect(entries.count == 22)
        #expect(entries.allSatisfy { $0["outcome"] == "rejected" })
        #expect(entries.prefix(20).allSatisfy { $0["rejection"] == "permission_denied" })
        #expect(entries.suffix(2).allSatisfy { $0["rejection"] == nil || $0["rejection"] == .null })
        #expect(entries.last?["process_key"] == .null)
        await client.invalidate()
        await h.close()
    }

    @Test func malformedProcessKeyPreservesInvalidProcessKeyAcrossXPC() async throws {
        let h = try AgentHarness()
        let connection = NSXPCConnection(listenerEndpoint: h.listener.endpoint)
        connection.remoteObjectInterface = NSXPCInterface(with: ProcglintAgentXPC.self)
        connection.activate()
        defer { connection.invalidate() }
        let hello = AgentRequest.hello(ClientHello(clientKind: .gui, version: "test"))
        guard case .hello = try await integrationSend(ProcglintJSON.encoder().encode(hello), connection: connection) else {
            Issue.record("hello failed"); await h.close(); return
        }
        let payloads = [
            #"{"method":"process","key":"not-a-key"}"#,
            #"{"method":"prepare_termination","key":"p1.boot-a.-1.100","signal":"term"}"#,
            #"{"method":"pin","key":"p1.boot-a.42.bad","pinned":true}"#,
            #"{"method":"start_observation","request":{"interval_ms":1000,"duration_ms":1000,"process_keys":["bad"]}}"#,
        ]
        for payload in payloads {
            let response = try await integrationSend(Data(payload.utf8), connection: connection)
            guard case let .error(error) = response else { Issue.record("Expected malformed key error"); continue }
            #expect(error.code == .invalidProcessKey)
        }
        let malformed = try await integrationSend(Data(#"{"method":"process","key":42}"#.utf8), connection: connection)
        guard case let .error(error) = malformed else { Issue.record("Expected invalid argument"); await h.close(); return }
        #expect(error.code == .invalidArgument)
        let policy = try await integrationSend(ProcglintJSON.encoder().encode(AgentRequest.policy), connection: connection)
        #expect(try policy == .policy(SamplingPolicy()))
        await h.close()
    }
}
