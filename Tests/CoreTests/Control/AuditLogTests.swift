import Darwin
import Foundation
import ProcglintCore
import Testing

@Suite(.timeLimit(.minutes(1)))
struct AuditLogTests {
    private let cap = 1024 * 1024

    private func entry(key: ProcessKey, name: String = "worker", outcome: String = "issued") -> AuditEntry {
        AuditEntry(timestamp: Date(timeIntervalSince1970: 100), clientKind: .mcp, clientPID: 900,
                   processKey: key, pid: 42, name: name, signal: .term, outcome: outcome)
    }

    private func permissions(at url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try #require(attributes[.posixPermissions] as? NSNumber).intValue
    }

    @Test func jsonLinesUseContractEncoder() throws {
        let fixture = try ControlFixture()
        let log = AuditLog(url: fixture.url)
        let first = entry(key: fixture.key, name: "worker\n\"quoted\"")
        var second = entry(key: fixture.key, outcome: "rejected")
        second.rejection = .permissionDenied
        try log.append(first)
        try log.append(second)
        #expect(try fixture.entries() == [first, second])
        let data = try Data(contentsOf: fixture.url)
        #expect(data.last == 0x0A)
        let lines = data.split(separator: 0x0A)
        #expect(lines.count == 2)
        let object = try #require(JSONSerialization.jsonObject(with: Data(lines[0])) as? [String: Any])
        #expect(object["client_pid"] as? Int == 900)
        #expect(object["client_kind"] as? String == "mcp")
        #expect(object["process_key"] as? String == fixture.key.rawValue)
        #expect(object["timestamp"] as? String == "1970-01-01T00:01:40.000Z")
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(!text.contains("token"))
    }

    @Test func permissionsArePrivateIncludingExistingFiles() throws {
        let fixture = try ControlFixture()
        let log = AuditLog(url: fixture.url)
        try log.append(entry(key: fixture.key))
        #expect(try permissions(at: fixture.directory) == 0o700)
        #expect(try permissions(at: fixture.url) == 0o600)
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: fixture.directory.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: fixture.url.path)
        try log.append(entry(key: fixture.key))
        #expect(try permissions(at: fixture.directory) == 0o700)
        #expect(try permissions(at: fixture.url) == 0o600)
        #expect(try fixture.entries().count == 2)
    }

    @Test func rotationAtExactByteCapKeepsOneGeneration() throws {
        let fixture = try ControlFixture()
        let log = AuditLog(url: fixture.url)
        var full = entry(key: fixture.key, name: "")
        let overhead = try ProcglintJSON.encoder().encode(full).count + 1
        full.name = String(repeating: "x", count: cap - overhead)
        try log.append(full)
        let rotated = fixture.directory.appendingPathComponent("audit.1.jsonl")
        #expect(try Data(contentsOf: fixture.url).count == cap)
        #expect(!FileManager.default.fileExists(atPath: rotated.path))
        let small = entry(key: fixture.key, outcome: "signal_sent")
        try log.append(small)
        #expect(try fixture.entries() == [small])
        #expect(try Data(contentsOf: rotated).count == cap)
        #expect(try permissions(at: fixture.url) == 0o600)
        #expect(try permissions(at: rotated) == 0o600)
        try log.append(full)
        #expect(try fixture.entries() == [full])
        let previous = try Data(contentsOf: rotated).split(separator: 0x0A).map {
            try ProcglintJSON.decoder().decode(AuditEntry.self, from: Data($0))
        }
        #expect(previous == [small])
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path).sorted() == ["audit.1.jsonl", "audit.jsonl"])
    }

    @Test func oversizedEntryFailsWithoutLosingExistingLog() throws {
        let fixture = try ControlFixture()
        let log = AuditLog(url: fixture.url)
        try log.append(entry(key: fixture.key))
        let before = try Data(contentsOf: fixture.url)
        #expect(throws: AgentError.invalidArgument("Audit entry exceeds 1 MiB")) {
            try log.append(entry(key: fixture.key, name: String(repeating: "x", count: cap)))
        }
        #expect(try Data(contentsOf: fixture.url) == before)
    }

    @Test func directoryAndRotationFailuresSurfaceWithoutTruncation() throws {
        let fixture = try ControlFixture()
        let log = AuditLog(url: fixture.url)
        try log.append(entry(key: fixture.key))
        #expect(throws: (any Error).self) {
            try AuditLog(url: fixture.url.appendingPathComponent("audit.jsonl")).append(entry(key: fixture.key))
        }
        var full = entry(key: fixture.key, name: "")
        full.name = try String(repeating: "x", count: cap - (ProcglintJSON.encoder().encode(full).count + 1))
        try log.append(full)
        let rotated = fixture.directory.appendingPathComponent("audit.1.jsonl")
        try FileManager.default.removeItem(at: rotated)
        try FileManager.default.createDirectory(at: rotated, withIntermediateDirectories: false)
        let before = try Data(contentsOf: fixture.url)
        #expect(throws: (any Error).self) { try log.append(entry(key: fixture.key)) }
        #expect(try Data(contentsOf: fixture.url) == before)
    }

    @Test func refusesSymlinksAndNonregularFiles() throws {
        let fixture = try ControlFixture()
        try FileManager.default.createDirectory(at: fixture.directory, withIntermediateDirectories: true)
        let victim = fixture.directory.appendingPathComponent("victim")
        let contents = Data("do not overwrite".utf8)
        try contents.write(to: victim)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: victim.path)
        try FileManager.default.createSymbolicLink(at: fixture.url, withDestinationURL: victim)
        let log = AuditLog(url: fixture.url)
        #expect(throws: POSIXError.self) { try log.append(entry(key: fixture.key)) }
        #expect(try Data(contentsOf: victim) == contents)
        #expect(try permissions(at: victim) == 0o644)
        try FileManager.default.removeItem(at: fixture.url)
        try FileManager.default.createDirectory(at: fixture.url, withIntermediateDirectories: false)
        #expect(throws: POSIXError.self) { try log.append(entry(key: fixture.key)) }
        try FileManager.default.removeItem(at: fixture.url)
        #expect(mkfifo(fixture.url.path, 0o600) == 0)
        #expect(throws: POSIXError.self) { try log.append(entry(key: fixture.key)) }
    }

    @Test func refusesSymlinkDirectory() throws {
        let fixture = try ControlFixture()
        try FileManager.default.createDirectory(at: fixture.directory, withIntermediateDirectories: true)
        let real = fixture.directory.appendingPathComponent("real")
        let link = fixture.directory.appendingPathComponent("link")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        #expect(throws: (any Error).self) {
            try AuditLog(url: link.appendingPathComponent("audit.jsonl")).append(entry(key: fixture.key))
        }
        #expect(try permissions(at: real) == 0o755)
        #expect(try FileManager.default.contentsOfDirectory(atPath: real.path).isEmpty)
    }

    @Test func rejectsNonFileURL() throws {
        let fixture = try ControlFixture()
        let url = try #require(URL(string: "https://example.invalid/audit.jsonl"))
        #expect(throws: AgentError.invalidArgument("Audit log requires a file URL")) {
            try AuditLog(url: url).append(entry(key: fixture.key))
        }
    }

    @Test func concurrentAppendsRemainWholeLines() async throws {
        let fixture = try ControlFixture()
        let log = AuditLog(url: fixture.url)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for number in 0 ..< 32 {
                group.addTask {
                    try log.append(entry(key: fixture.key, name: "worker-\(number)"))
                }
            }
            try await group.waitForAll()
        }
        let entries = try fixture.entries()
        #expect(entries.count == 32)
        #expect(Set(entries.map(\.name)).count == 32)
    }

    @Test func failedPrepareAuditDoesNotIssueToken() async throws {
        let fixture = try ControlFixture()
        try FileManager.default.createDirectory(at: fixture.url, withIntermediateDirectories: true)
        await #expect(throws: (any Error).self) { try await fixture.prepare() }
        #expect(fixture.signals.isEmpty)
        try FileManager.default.removeItem(at: fixture.url)
        let ticket = try await fixture.prepare()
        #expect(try await fixture.finish(ticket).outcome == .signalSent)
    }

    @Test func failedPostSignalAuditReportsThatSignalWasSent() async throws {
        let fixture = try ControlFixture()
        let ticket = try await fixture.prepare()
        try FileManager.default.removeItem(at: fixture.url)
        try FileManager.default.createDirectory(at: fixture.url, withIntermediateDirectories: false)
        do {
            _ = try await fixture.controller.terminate(token: ticket.token, client: fixture.client)
            Issue.record("Expected audit failure")
        } catch let error as AgentError {
            #expect(error.code == .internalError)
            #expect(error.message.contains("Signal sent"))
            #expect(error.message.contains("audit write failed"))
        }
        #expect(fixture.signals.count == 1)
        try FileManager.default.removeItem(at: fixture.url)
        #expect(try await fixture.controller.terminate(token: ticket.token, client: fixture.client).rejection == .tokenUsed)
        #expect(fixture.signals.count == 1)
    }

    @Test func failedRejectionAuditSurfaces() async throws {
        let fixture = try ControlFixture()
        let ticket = try await fixture.prepare()
        try FileManager.default.removeItem(at: fixture.url)
        try FileManager.default.createDirectory(at: fixture.url, withIntermediateDirectories: false)
        fixture.clock.advance(by: 30_000_000_000)
        await #expect(throws: (any Error).self) {
            try await fixture.controller.terminate(token: ticket.token, client: fixture.client)
        }
        await #expect(throws: (any Error).self) {
            try await fixture.controller.terminate(token: "tok-unknown", client: fixture.client)
        }
        #expect(fixture.signals.isEmpty)
    }
}
