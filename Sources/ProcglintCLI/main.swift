import Darwin
import Foundation
import ProcglintCore
import ProcglintIPC

let command: CLICommand
do {
    command = try CLICommand.parse(Array(CommandLine.arguments.dropFirst()))
} catch {
    let message = (error as? CLIUsageError)?.message ?? error.localizedDescription
    try? FileHandle.standardError.write(contentsOf: Data((message + "\n" + CLICommand.usage + "\n").utf8))
    exit(64)
}

if command == .version {
    let executable = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
    try? FileHandle.standardOutput.write(contentsOf: Data(versionOutput(executable: executable).utf8))
    exit(0)
}

if command == .help {
    try? FileHandle.standardOutput.write(contentsOf: Data((CLICommand.usage + "\n").utf8))
    exit(0)
}

signal(SIGPIPE, SIG_IGN)
let client = AgentClient(clientKind: .cli, mcpFlags: command.requestedPermissions)
var exitCode: Int32 = 0
do {
    let output: String
    switch command {
    case .help: output = CLICommand.usage + "\n"
    case .version: output = versionOutput(executable: Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]))
    case let .status(json):
        let status = try await client.status()
        let system = try? await client.snapshot(top: 1, sort: .cpu).system
        output = try json ? jsonOutput(CLIStatus(status: status, system: system)) : statusSummary(status, system: system)
    case .doctor:
        let executable = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        let bundle = containingApp(executable: executable)
        let registration = bundle == nil ? nil : AgentRegistration().status
        let reachability: Result<MonitorStatus, any Error>
        do { reachability = try await .success(client.status()) }
        catch { reachability = .failure(error) }
        let report = doctorReport(bundle: bundle, registration: registration, agent: reachability)
        output = report.text
        exitCode = report.healthy ? 0 : 1
    case let .show(pid, json, _):
        let process = try await showProcess(service: client, pid: pid)
        output = try json ? jsonOutput(process) : processSummary(process)
    case let .snapshot(format, all, sort):
        let snapshot = try await exportSnapshot(service: client, all: all, sort: sort)
        output = try format == .json ? jsonOutput(snapshot) : snapshotCSV(snapshot)
    case let .history(format, series):
        let history = try await client.history(HistoryRequest(series: series))
        output = try format == .json ? jsonOutput(history) : historyCSV(history)
    }
    try FileHandle.standardOutput.write(contentsOf: Data(output.utf8))
} catch {
    let message = (error as? AgentError).map { "\($0.code.rawValue): \($0.message)" } ?? error.localizedDescription
    try? FileHandle.standardError.write(contentsOf: Data(("procglint: " + message + "\n").utf8))
    exitCode = 1
}

await client.invalidate()
exit(exitCode)
