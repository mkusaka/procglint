import Darwin
import Foundation
import ProcglintCore
@testable import ProcglintMCPKit
import Testing

private final class TestBundleMarker {}

private struct ChildResult {
    let status: Int32
    let stdout: String
    let stderr: String
}

private final class ChildProcess {
    let process = Process()
    let input = Pipe()
    let output = Pipe()
    let errors = Pipe()
    private let exited = DispatchSemaphore(value: 0)

    init(_ binary: String, _ arguments: [String] = [], executableURL: URL? = nil) throws {
        let directory = Bundle(for: TestBundleMarker.self).bundleURL.deletingLastPathComponent()
        let executable = executableURL ?? directory.appendingPathComponent(binary)
        _ = try #require(FileManager.default.isExecutableFile(atPath: executable.path), "Build \(binary) next to the test bundle: \(directory.path)")
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        process.terminationHandler = { [exited] _ in exited.signal() }
        try process.run()
        try input.fileHandleForReading.close()
        try output.fileHandleForWriting.close()
        try errors.fileHandleForWriting.close()
    }

    deinit {
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
        }
        try? input.fileHandleForWriting.close()
        try? output.fileHandleForReading.close()
        try? errors.fileHandleForReading.close()
    }

    func send(_ line: String) throws {
        try input.fileHandleForWriting.write(contentsOf: Data((line + "\n").utf8))
    }

    func response(timeout: Int = 5) throws -> JSONValue {
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(timeout) * 1_000_000_000
        var line = Data()
        while line.count <= MCPServer.maximumResponseBytes {
            let now = DispatchTime.now().uptimeNanoseconds
            _ = try #require(now < deadline, "Timed out reading a JSON-RPC line")
            let milliseconds = Int32(min((deadline - now) / 1_000_000 + 1, UInt64(Int32.max)))
            var descriptor = pollfd(fd: output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, milliseconds)
            if ready < 0, errno == EINTR {
                continue
            }
            _ = try #require(ready > 0, "Timed out or failed reading MCP stdout")
            var byte: UInt8 = 0
            let count = Darwin.read(descriptor.fd, &byte, 1)
            if count < 0, errno == EINTR {
                continue
            }
            _ = try #require(count == 1, "MCP stdout closed before a complete response")
            if byte == 10 {
                let value = try ProcglintJSON.decoder().decode(JSONValue.self, from: line)
                #expect(value["jsonrpc"] == "2.0")
                #expect(value["id"] != nil)
                #expect(value["result"] != nil || value["error"] != nil)
                return value
            }
            line.append(byte)
        }
        throw AgentError.internalError("MCP response exceeded the framing limit")
    }

    func finish(timeout: Int = 5) throws -> ChildResult {
        try input.fileHandleForWriting.close()
        _ = try #require(exited.wait(timeout: .now() + .seconds(timeout)) == .success, "Child did not exit after EOF")
        process.waitUntilExit()
        let stdout = output.fileHandleForReading.readDataToEndOfFile()
        let stderr = errors.fileHandleForReading.readDataToEndOfFile()
        return try ChildResult(status: process.terminationStatus, stdout: #require(String(bytes: stdout, encoding: .utf8)),
                               stderr: #require(String(bytes: stderr, encoding: .utf8)))
    }
}

struct MCPProcessTests {
    @Test func helpIsOnlyOnStderr() throws {
        let result = try ChildProcess("procglint-mcp", ["--help"]).finish()
        #expect(result.status == 0)
        #expect(result.stdout.isEmpty)
        #expect(result.stderr.contains("Usage: procglint-mcp"))
    }

    @Test func badFlagUsesExit64() throws {
        let result = try ChildProcess("procglint-mcp", ["--bogus"]).finish()
        #expect(result.status == 64)
        #expect(result.stdout.isEmpty)
        #expect(result.stderr.contains("--bogus"))
        #expect(result.stderr.contains("Usage:"))
    }

    @Test(arguments: [
        [String](), ["--allow-observe"], ["--allow-configure"], ["--allow-terminate"], ["--allow-force-kill"],
        ["--include-system", "--include-paths"],
        ["--allow-observe", "--allow-configure", "--allow-terminate", "--allow-force-kill", "--include-system", "--include-paths"],
    ])
    func legacyHandshakeAndToolsStayProtocolOnly(flags: [String]) throws {
        let child = try ChildProcess("procglint-mcp", flags)
        // Deliberately split a line: the reply must arrive while stdin is still open.
        let initialize = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"process-test","version":"1"}}}"#
        try child.input.fileHandleForWriting.write(contentsOf: Data(initialize.prefix(10).utf8))
        try child.send(String(initialize.dropFirst(10)))
        let initialized = try child.response()
        #expect(initialized["id"] == 1)
        #expect(initialized["result"]?["protocolVersion"] == "2025-11-25")
        try child.send(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        try child.send(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)
        let response = try child.response()
        #expect(response["id"] == 2)
        let tools = try #require(response["result"]?["tools"])
        let definitions = try tools.decode([JSONValue].self)
        let names = definitions.compactMap { $0["name"]?.string }
        var expected = ["get_snapshot", "list_processes", "get_process", "get_history", "get_monitor_status"]
        if flags.contains("--allow-observe") {
            expected += ["start_observation", "stop_observation"]
        }
        if flags.contains("--allow-configure") {
            expected += ["set_sampling_policy"]
        }
        if flags.contains("--allow-terminate") {
            expected += ["prepare_termination", "terminate_process"]
        }
        #expect(names == expected)

        try child.send(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"get_snapshot","arguments":{"top":1}}}"#)
        let snapshot = try child.response(timeout: 15)
        #expect(snapshot["id"] == 3)
        #expect(snapshot["error"] == nil)
        let result = try #require(snapshot["result"])
        let content = try #require(result["structuredContent"])
        if result["isError"] == true {
            #expect(content["error"]?["code"] == "agent_unavailable")
            #expect(content["error"]?["message"]?.string?.contains("procglint doctor") == true)
        } else {
            #expect(result["isError"] == false)
            #expect(content["snapshot_id"]?.string != nil)
        }
        let finished = try child.finish()
        #expect(finished.status == 0)
        #expect(finished.stdout.isEmpty, "No non-protocol output may follow the responses")
    }

    @Test func idleEOFExitsCleanly() throws {
        let result = try ChildProcess("procglint-mcp").finish()
        #expect(result.status == 0)
        #expect(result.stdout.isEmpty)
    }
}

struct CLIProcessTests {
    @Test func helpNeedsNoAgent() throws {
        let result = try ChildProcess("procglint", ["--help"]).finish()
        #expect(result.status == 0)
        #expect(result.stdout.contains("Usage: procglint"))
        #expect(result.stdout.contains("export history"))
        #expect(result.stderr.isEmpty)
    }

    @Test(arguments: [
        [String](), ["unknown"], ["status", "--csv"], ["doctor", "--json"], ["export"],
        ["export", "snapshot", "--csv", "--json"], ["export", "snapshot", "--series", "system"],
        ["export", "history", "--all"], ["export", "history", "--series"], ["export", "snapshot", "--bogus"],
    ])
    func invalidCommandsUseExit64(arguments: [String]) throws {
        let result = try ChildProcess("procglint", arguments).finish()
        #expect(result.status == 64)
        #expect(result.stdout.isEmpty)
        #expect(result.stderr.contains("Usage: procglint"))
    }

    @Test func doctorFindsContainingAppForBundledHelper() throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("procglint-doctor-\(ProcessInfo.processInfo.globallyUniqueString)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let app = temporary.appendingPathComponent("Procglint.app")
        let helpers = app.appendingPathComponent("Contents/Helpers")
        let macOS = app.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: helpers, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        let builtCLI = Bundle(for: TestBundleMarker.self).bundleURL.deletingLastPathComponent().appendingPathComponent("procglint")
        let helper = helpers.appendingPathComponent("procglint")
        try FileManager.default.copyItem(at: builtCLI, to: helper)
        try FileManager.default.copyItem(at: builtCLI, to: macOS.appendingPathComponent("procglint-gui"))
        let info = ["CFBundleExecutable": "procglint-gui", "CFBundleIdentifier": "io.github.mkusaka.procglint.doctor-test", "CFBundlePackageType": "APPL"]
        let plist = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try plist.write(to: app.appendingPathComponent("Contents/Info.plist"))
        let result = try ChildProcess("procglint", ["doctor"], executableURL: helper).finish(timeout: 15)
        #expect(result.status == 1, "The fixture app has no registered LaunchAgent")
        #expect(result.stderr.isEmpty)
        #expect(result.stdout.contains("App bundle: \(app.resolvingSymlinksInPath().path)"))
        #expect(result.stdout.contains("Agent registration:"))
        #expect(!result.stdout.contains("not applicable"))
        #expect(result.stdout.contains("Settings → Register"))
    }

    @Test func doctorReportsReachabilityAndRecovery() throws {
        let result = try ChildProcess("procglint", ["doctor"]).finish(timeout: 15)
        #expect(result.stderr.isEmpty)
        #expect(result.stdout.contains("outside an app bundle"))
        if result.status == 0 {
            #expect(result.stdout.contains("Agent: reachable"))
        } else {
            #expect(result.status == 1)
            #expect(result.stdout.contains("agent_unavailable"))
            #expect(result.stdout.contains("Settings → Register"))
            #expect(result.stdout.contains("Login Items"))
            #expect(result.stdout.contains("scripts/dev-agent.sh start"))
        }
    }
}
