import Darwin
import Foundation
import ProcglintCore
import Testing

private func procargs(_ argv: [String], executable: String = "/bin/worker", padding: Int = 3, environment: [String] = ["PRIVATE=do-not-leak"]) -> Data {
    var argc = Int32(argv.count)
    var data = withUnsafeBytes(of: &argc) { Data($0) }
    data.append(contentsOf: executable.utf8)
    data.append(contentsOf: Array(repeating: 0, count: padding + 1))
    for argument in argv + environment {
        data.append(contentsOf: argument.utf8); data.append(0)
    }
    return data
}

struct ProcessDetailTests {
    @Test func procargsReadsOnlyArgcStringsIncludingEmptyArguments() {
        let data = procargs(["worker", "", "server.js", "--token", "test-secret"])
        let parsed = data.withUnsafeBytes { ProcessArguments.parse($0) }
        #expect(parsed.value == ["worker", "", "server.js", "--token", "<redacted>"])
        #expect(parsed.status == .ok)
        #expect(!parsed.truncated)
        #expect(!parsed.displayText.contains("PRIVATE"))
        #expect(ProcessArguments.parse(procargs(["worker"], padding: 0)).value == ["worker"])
    }

    @Test func capsArgumentsBytesAndTotalAfterRedaction() throws {
        let many = ProcessArguments.parse(procargs(["worker"] + Array(repeating: "arg", count: 70)))
        #expect(many.value?.count == 64)
        #expect(many.truncated)
        let long = String(repeating: "日", count: 2000)
        let parsed = ProcessArguments.parse(procargs(["worker"] + Array(repeating: long, count: 10)))
        let values = try #require(parsed.value)
        #expect(values.allSatisfy { $0.utf8.count <= 4096 && !$0.contains("�") })
        #expect(values.reduce(0) { $0 + $1.utf8.count } <= 16384)
        #expect(parsed.truncated)
        #expect(parsed.displayText.hasSuffix("[truncated]"))
        let secret = ProcessArguments.parse(procargs(["--token=" + String(repeating: "s", count: 20000)]))
        #expect(secret.value == ["--token=<redacted>"])
        #expect(!secret.truncated)
        let exact = ProcessCommandLine(arguments: Array(repeating: String(repeating: "x", count: 4096), count: 4))
        #expect(exact.value?.count == 4)
        #expect(!exact.truncated)
    }

    @Test func malformedBuffersFailClosed() {
        var missingTerminator = procargs(["worker"], environment: [])
        missingTerminator.removeLast()
        var missingArg = procargs(["worker"], environment: [])
        missingArg[0] = 2
        var negative = procargs(["worker"])
        negative.replaceSubrange(0 ..< 4, with: [255, 255, 255, 255])
        var invalidUTF8 = procargs(["worker"], environment: [])
        invalidUTF8[invalidUTF8.count - 2] = 255
        for data in [Data(), Data([1, 0]), procargs([]), procargs(["worker"], executable: ""),
                     missingTerminator, missingArg, negative, invalidUTF8]
        {
            let value = ProcessArguments.parse(data)
            #expect(value.status == .unsupported)
            #expect(value.value == nil)
        }
    }

    @Test(arguments: [
        (["--token=short"], ["--token=<redacted>"]),
        (["--AccessToken", "short", "visible"], ["--AccessToken", "<redacted>", "visible"]),
        (["-password", "short"], ["-password", "<redacted>"]),
        (["--API_KEY", "short"], ["--API_KEY", "<redacted>"]),
        (["--api-key=short", "PASSWORD=short"], ["--api-key=<redacted>", "PASSWORD=<redacted>"]),
        (["--privateKey", "short", "KEY=short"], ["--privateKey", "<redacted>", "KEY=<redacted>"]),
        (["--signingkey=short", "MYKEY=short"], ["--signingkey=<redacted>", "MYKEY=<redacted>"]),
        (["--passwd", "short", "--pwd=short"], ["--passwd", "<redacted>", "--pwd=<redacted>"]),
        (["--client-secret", "short", "--credential=short"], ["--client-secret", "<redacted>", "--credential=<redacted>"]),
        (["https://user:pass@host/path?q=1"], ["https://user:<redacted>@host/path?q=1"]),
        (["--url=https://user:pass@host"], ["--url=https://user:<redacted>@host"]),
        (["https://short@host"], ["https://<redacted>@host"]),
        (["Authorization: Bearer short", "bEaReR short"], ["Authorization: Bearer <redacted>", "bEaReR <redacted>"]),
        (["Authorization:", "Bearer", "short"], ["Authorization:", "Bearer", "<redacted>"]),
        (["--auth", "Bearer short"], ["--auth", "<redacted>"]),
        (["--auth", "Bearer", "short"], ["--auth", "<redacted>", "<redacted>"]),
        (["--token", "--password", "short"], ["--token", "<redacted>", "<redacted>"]),
        (["--auth=Bearer", "short"], ["--auth=<redacted>", "<redacted>"]),
        (["Authorization:Bearer", "short"], ["Authorization:Bearer", "<redacted>"]),
        (["--keyboard", "US", "--monkey", "banana", "--keymap=default"], ["--keyboard", "US", "--monkey", "banana", "--keymap=default"]),
        (["node", "server.js", "--port=8080", "https://host/path", "NAME=value"], ["node", "server.js", "--port=8080", "https://host/path", "NAME=value"]),
        (["--output=key.csv", "visible", "notbearer", "visible"], ["--output=key.csv", "visible", "notbearer", "visible"]),
    ])
    func redactionTable(input: [String], expected: [String]) {
        #expect(CommandLineRedactor.redact(input) == expected)
        #expect(CommandLineRedactor.redact(expected) == expected)
    }

    @Test func censusLineageAndDirectChildren() async throws {
        let source = FakeProcessSource()
        for (pid, parent) in [(Int32(1), Int32(0)), (2, 1), (3, 2), (4, 3), (5, 3)] {
            source.addProcess(pid: pid, process: .init(rusage: RawRusage(startTimeUS: 10),
                                                       bsdInfo: RawBSDInfo(name: "worker-\(pid)", uid: getuid(), ppid: parent, startTimeUS: 10)))
        }
        let sampler = try Sampler(source: source, clock: FakeClock())
        let census = try await sampler.sample().processes
        var sample = try #require(census.first { $0.pid == 3 })
        sample.addLineage(from: census)
        #expect(sample.ancestors?.map(\.pid) == [2, 1])
        #expect(sample.ancestors?.allSatisfy { $0.processKey != nil && $0.commandLine == nil } == true)
        #expect(sample.ancestorsIncomplete == false)
        #expect(sample.childrenCount == 2)
        #expect(source.state.commandLineReads.isEmpty)
        var root = try #require(census.first { $0.pid == 1 })
        root.addLineage(from: census)
        #expect(root.ancestors == [])
        #expect(root.ancestorsIncomplete == false)
    }

    @Test func missingParentCyclesAndDepthAreIncomplete() throws {
        var selected = try storeProcess(pid: 100)
        selected.ppid = 99
        selected.addLineage(from: [selected])
        #expect(selected.ancestors == [])
        #expect(selected.ancestorsIncomplete == true)
        var parent = try storeProcess(pid: 99)
        parent.ppid = 100
        selected.addLineage(from: [selected, parent])
        #expect(selected.ancestors?.map(\.pid) == [99])
        #expect(selected.ancestorsIncomplete == true)
        let deep = try (1 ... 100).map { pid -> ProcessSample in
            var row = try storeProcess(pid: Int32(pid))
            row.ppid = Int32(pid - 1)
            return row
        }
        selected.addLineage(from: deep)
        #expect(selected.ancestors?.count == 64)
        #expect(selected.ancestors?.last?.pid == 36)
        #expect(selected.ancestorsIncomplete == true)
        selected.pid = 65
        selected.ppid = 64
        selected.addLineage(from: deep)
        #expect(selected.ancestors?.count == 64)
        #expect(selected.ancestors?.last?.pid == 1)
        #expect(selected.ancestorsIncomplete == false)
    }

    @Test func detailJSONIsOptionalAndLegacyScopeDefaultsOff() throws {
        let old = try storeProcess()
        let oldData = try ProcglintJSON.encoder().encode(old)
        let legacy = try ProcglintJSON.decoder().decode(ProcessSample.self, from: oldData)
        #expect(legacy.commandLine == nil && legacy.cwd == nil && legacy.ancestors == nil && legacy.childrenCount == nil)
        var detail = old
        detail.commandLine = ProcessCommandLine(arguments: ["worker", "--secret=test-secret"])
        detail.cwd = WorkingDirectory(unavailable: .permissionDenied)
        detail.ancestors = [ProcessAncestor(pid: 1, name: "launchd", commandLine: ProcessCommandLine(unavailable: .permissionDenied))]
        detail.ancestorsIncomplete = false
        detail.childrenCount = 2
        let data = try ProcglintJSON.encoder().encode(detail)
        let text = try #require(String(bytes: data, encoding: .utf8))
        #expect(text.contains("command_line") && text.contains("ancestors_incomplete") && text.contains("children_count"))
        #expect(text.contains(#""value":null"#))
        #expect(!text.contains("test-secret"))
        #expect(try ProcglintJSON.decoder().decode(ProcessSample.self, from: data) == detail)
        let scope = try ProcglintJSON.decoder().decode(AccessScope.self, from: Data(#"{"include_system":false,"include_paths":false}"#.utf8))
        #expect(scope == AccessScope())
        #expect(AccessScope(permissions: [.includeCommandLines]).includeCommandLines)
        var store = SnapshotStore(clock: FakeClock())
        store.insert(storeSnapshot(processes: [detail]))
        let bulk = try #require(store.listProcesses(ProcessQuery(), scope: AccessScope(includeCommandLines: true)).items.first)
        #expect(bulk.commandLine == nil && bulk.cwd == nil && bulk.ancestors == nil && bulk.childrenCount == nil)
    }

    @Test func realOSLaunchReadsOnlyAssertInvariants() throws {
        let source = try DarwinProcessSource()
        let command = try source.commandLine(pid: getpid())
        #expect(command.status == .ok || command.status == .permissionDenied || command.status == .unsupported)
        if let argv = command.value {
            #expect(!argv.isEmpty && argv.count <= 64)
            #expect(argv.allSatisfy { $0.utf8.count <= 4096 })
        }
        let cwd = try source.workingDirectory(pid: getpid())
        #expect(cwd.status == .ok || cwd.status == .permissionDenied || cwd.status == .unsupported)
        if let value = cwd.value {
            #expect(value.hasPrefix("/"))
        }
        #expect(try source.commandLine(pid: Int32.max).status == .exited)
        #expect(try source.workingDirectory(pid: Int32.max).status == .exited)
    }
}
