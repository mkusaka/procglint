import Darwin
import Foundation
import ProcglintCore
import ProcglintIPC
import Testing

struct AgentProcessDetailTests {
    @Test(arguments: ClientKind.allCases, [(false, false), (false, true), (true, false), (true, true)])
    func lazyDetailRequiresBothSettingsAndRequestedScope(kind: ClientKind, toggles: (Bool, Bool)) async throws {
        let (setting, flag) = toggles
        let fixture = try ServiceFixture(permissions: setting ? [.includeCommandLines] : [])
        fixture.source.addProcess(pid: 1, process: .init(rusage: RawRusage(startTimeUS: 100),
                                                         bsdInfo: RawBSDInfo(name: "launchd", uid: 0, ppid: 0, startTimeUS: 100)))
        fixture.source.update {
            $0.processes[42]?.bsdInfo.ppid = 700
            for pid in [Int32(42), 700, 701, 1] {
                $0.commandLines[pid] = ProcessCommandLine(arguments: ["worker", "--token", "test-secret"])
            }
            $0.workingDirectories[42] = WorkingDirectory(value: "/private/project")
        }
        let client = fixture.client(kind, flags: flag ? [.includeCommandLines] : [])
        let page = try await client.listProcesses(ProcessQuery(filter: .all))
        #expect(page.items.allSatisfy { $0.commandLine == nil && $0.cwd == nil && $0.ancestors == nil })
        #expect(fixture.source.state.commandLineReads.isEmpty && fixture.source.state.cwdReads.isEmpty)
        let detail = try await client.process(key: fixture.key())
        let enabled = setting && (kind == .gui || flag)
        #expect(detail.ancestors?.map(\.pid) == [700, 701, 1])
        #expect(detail.ancestorsIncomplete == false)
        #expect(detail.childrenCount == 0)
        if enabled {
            #expect(detail.commandLine?.value == ["worker", "--token", "<redacted>"])
            #expect(detail.cwd?.value == "/private/project")
            #expect(detail.ancestors?.first?.commandLine?.value == detail.commandLine?.value)
            #expect(detail.ancestors?.last?.commandLine?.status == .permissionDenied)
            #expect(fixture.source.state.commandLineReads == [42, 700, 701])
            #expect(fixture.source.state.cwdReads == [42])
        } else {
            #expect(detail.commandLine == nil && detail.cwd == nil)
            #expect(detail.ancestors?.allSatisfy { $0.commandLine == nil } == true)
            #expect(fixture.source.state.commandLineReads.isEmpty && fixture.source.state.cwdReads.isEmpty)
        }
        let json = try #require(String(bytes: ProcglintJSON.encoder().encode(detail), encoding: .utf8))
        #expect(!json.contains("test-secret"))
        fixture.settings.setAllowedPermissions([])
        let revoked = try await client.process(key: fixture.key())
        #expect(revoked.commandLine == nil && revoked.cwd == nil)
        #expect(revoked.ancestors?.allSatisfy { $0.commandLine == nil } == true)
        #expect(await fixture.scheduler.diagnostics().collectionsTotal == 1)
        await client.invalidate()
        await fixture.close()
    }

    @Test func otherUsersNeverHaveArgumentsOrCwdRead() async throws {
        let fixture = try ServiceFixture()
        let client = fixture.client(flags: [.includeSystem, .includeCommandLines])
        let detail = try await client.process(key: fixture.key(84))
        #expect(detail.commandLine?.status == .permissionDenied && detail.commandLine?.value == nil)
        #expect(detail.cwd?.status == .permissionDenied && detail.cwd?.value == nil)
        #expect(fixture.source.state.commandLineReads.isEmpty && fixture.source.state.cwdReads.isEmpty)
        await client.invalidate()
        await fixture.close()
    }

    @Test func reusedAncestorPIDIsNotReadUsingAnOldCensusIdentity() async throws {
        let fixture = try ServiceFixture()
        fixture.source.update { $0.processes[42]?.bsdInfo.ppid = 700 }
        let client = fixture.client(flags: [.includeCommandLines])
        _ = try await client.snapshot(top: 200, sort: .pid)
        fixture.source.update {
            $0.processes[700]?.bsdInfo.startTimeUS = 200
            $0.processes[700]?.rusage.startTimeUS = 200
            $0.commandLines[700] = ProcessCommandLine(arguments: ["replacement", "--token=test-secret"])
        }
        let detail = try await client.process(key: fixture.key())
        #expect(detail.ancestors?.first?.commandLine?.status == .exited)
        #expect(!fixture.source.state.commandLineReads.contains(700))
        let oldKey = try fixture.key(700)
        #expect(detail.ancestors?.first?.processKey == oldKey)
        await client.invalidate()
        await fixture.close()
    }

    @Test(arguments: [(ProcessSourceError.permissionDenied, MetricStatus.permissionDenied), (.exited, .exited), (.unavailable("malformed"), .unsupported)])
    func launchFailuresKeepStatuses(error: ProcessSourceError, status: MetricStatus) async throws {
        let fixture = try ServiceFixture()
        fixture.source.update { $0.launchErrors[42] = error }
        let client = fixture.client(flags: [.includeCommandLines])
        let detail = try await client.process(key: fixture.key())
        #expect(detail.commandLine?.status == status && detail.commandLine?.value == nil)
        #expect(detail.cwd?.status == status && detail.cwd?.value == nil)
        await client.invalidate()
        await fixture.close()
    }
}
