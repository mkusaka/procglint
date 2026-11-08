import Darwin
import Foundation
import ProcglintCore
import Testing

private final class WorkloadBundleMarker {}

private let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()

private final class WorkloadChild {
    let process = Process()
    let output = Pipe()
    private let exited = DispatchSemaphore(value: 0)

    init(_ arguments: [String], executable: URL? = nil, environment: [String: String]? = nil) throws {
        let directory = Bundle(for: WorkloadBundleMarker.self).bundleURL.deletingLastPathComponent()
        process.executableURL = executable ?? directory.appendingPathComponent("procglint-workload")
        process.arguments = arguments
        process.environment = environment
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [exited] _ in exited.signal() }
        try process.run()
        try output.fileHandleForWriting.close()
    }

    deinit {
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
        }
    }

    func ready() throws -> String {
        var result: [UInt8] = []
        while result.count < 4096 {
            var descriptor = pollfd(fd: output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
            _ = try #require(poll(&descriptor, 1, 10000) > 0, "Workload failed to become ready")
            var byte: UInt8 = 0
            _ = try #require(Darwin.read(descriptor.fd, &byte, 1) == 1)
            if byte == 10 {
                return try #require(String(bytes: result, encoding: .utf8))
            }
            result.append(byte)
        }
        throw AgentError.internalError("Oversized workload output")
    }

    func finish() throws -> Int32 {
        _ = try #require(exited.wait(timeout: .now() + .seconds(15)) == .success, "Workload failed to exit")
        process.waitUntilExit()
        return process.terminationStatus
    }
}

struct WorkloadTests {
    @Test(arguments: [
        [String](), ["spawn", "--count", "0"], ["memory", "--mib", "-1"],
        ["cpu", "--threads", "257", "--seconds", "1"], ["disk", "--mib", "bad"],
        ["churn", "--rate", "1"], ["cpu", "--threads", "1", "--threads", "1"],
    ])
    func rejectsInvalidArguments(_ arguments: [String]) throws {
        #expect(try WorkloadChild(arguments).finish() == 64)
    }

    @Test(arguments: [
        ["cpu", "--threads", "2", "--seconds", "1"], ["disk", "--mib", "1"],
        ["churn", "--rate", "2", "--seconds", "1"],
    ])
    func finiteWorkloadsComplete(_ arguments: [String]) throws {
        #expect(try WorkloadChild(arguments).finish() == 0)
    }

    @Test func spawnReexecutesItselfWhenInvokedThroughPATH() throws {
        let directory = Bundle(for: WorkloadBundleMarker.self).bundleURL.deletingLastPathComponent()
        let child = try WorkloadChild(["procglint-workload", "spawn", "--count", "1"],
                                      executable: URL(fileURLWithPath: "/usr/bin/env"), environment: ["PATH": directory.path])
        #expect(try child.ready().contains("1 idle children"))
        #expect(kill(child.process.processIdentifier, SIGTERM) == 0)
        #expect(try child.finish() == 0)
    }

    @Test func memoryHoldsUntilTerminated() throws {
        let child = try WorkloadChild(["memory", "--mib", "1"])
        #expect(try child.ready().contains("1 MiB touched"))
        #expect(kill(child.process.processIdentifier, SIGTERM) == 0)
        #expect(try child.finish() == 0)
    }

    @Test(arguments: [SIGINT, SIGTERM, SIGKILL])
    func spawnChildrenExitEvenWhenParentIsKilled(_ signal: Int32) throws {
        let child = try WorkloadChild(["spawn", "--count", "2"])
        #expect(try child.ready().contains("2 idle children"))
        let source = try DarwinProcessSource()
        let children = try source.listPIDs().compactMap { pid -> (pid: Int32, start: UInt64)? in
            guard let info = try? source.bsdInfo(pid: pid), info.ppid == child.process.processIdentifier else { return nil }
            return (pid, info.startTimeUS)
        }
        #expect(children.count == 2)
        #expect(kill(child.process.processIdentifier, signal) == 0)
        _ = try child.finish()
        let deadline = DispatchTime.now().uptimeNanoseconds + 10_000_000_000
        var remaining = children
        repeat {
            remaining = remaining.filter { (try? source.bsdInfo(pid: $0.pid)?.startTimeUS) == $0.start }
            if remaining.isEmpty {
                break
            }
            usleep(10000)
        } while DispatchTime.now().uptimeNanoseconds < deadline
        defer {
            for process in remaining where (try? source.bsdInfo(pid: process.pid)?.startTimeUS) == process.start {
                kill(process.pid, SIGKILL)
            }
        }
        #expect(remaining.isEmpty, "Children must not survive their workload parent")
    }

    @Test func devAgentAcceptsAnExplicitBinaryWithoutBuilding() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("procglint-release-\(ProcessInfo.processInfo.globallyUniqueString)")
        let bin = home.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let launcher = "#!/bin/bash\n[[ $1 == print ]] && exit 1\n[[ $1 == bootstrap ]]\n"
        let binary = bin.appendingPathComponent("release & agent")
        for (url, script) in [(bin.appendingPathComponent("launchctl"), launcher),
                              (bin.appendingPathComponent("swift"), "#!/bin/bash\nexit 99\n"),
                              (binary, "#!/bin/bash\nexit 0\n")]
        {
            try script.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        }
        let environment = ["HOME": home.path, "PATH": "\(bin.path):/usr/bin:/bin:/usr/sbin:/sbin"]
        let script = repository.appendingPathComponent("scripts/dev-agent.sh").path
        let process = try WorkloadChild([script, "start", "--binary", binary.path], executable: URL(fileURLWithPath: "/bin/bash"), environment: environment)
        #expect(try process.finish() == 0)
        let plist = home.appendingPathComponent("Library/LaunchAgents/io.github.mkusaka.procglint.agent.dev.plist")
        let data = try Data(contentsOf: plist)
        let value = try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        #expect(value["Program"] as? String == binary.path)
        #expect(value["ProcessType"] as? String == "Adaptive")
        let invalid = try WorkloadChild([script, "start", "--binary", "relative"], executable: URL(fileURLWithPath: "/bin/bash"), environment: environment)
        #expect(try invalid.finish() == 2)
    }

    @Test func benchmarkDriverSelfChecks() throws {
        let driver = repository.appendingPathComponent("scripts/benchmark/driver.py")
        let child = try WorkloadChild(["python3", "-I", driver.path, "--self-test"], executable: URL(fileURLWithPath: "/usr/bin/env"))
        #expect(try child.finish() == 0)
    }
}
