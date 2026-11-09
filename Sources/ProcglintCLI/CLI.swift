import Foundation
import ProcglintCore
import ProcglintIPC

enum ExportFormat: Equatable {
    case json, csv
}

enum CLICommand: Equatable {
    case help
    case version
    case status(json: Bool)
    case doctor
    case show(pid: Int32, json: Bool, includeCommandLines: Bool)
    case snapshot(format: ExportFormat, all: Bool)
    case history(format: ExportFormat, series: [String])

    static let usage = """
    Usage: procglint status [--json]
           procglint doctor
           procglint show <pid> [--json] [--include-command-lines]
           procglint export snapshot [--json|--csv] [--all]
           procglint export history [--series system|<process_key> ...] [--json|--csv]
           procglint --help
           procglint --version
    Exports default to JSON. Snapshot defaults to the top 50 own processes by CPU;
    --all exports every permitted process, paging within one snapshot.
    History defaults to system. Missing CSV metrics are empty, not zero.
    """

    static func parse(_ arguments: [String]) throws -> Self {
        if arguments == ["--version"] {
            return .version
        }
        let helpPrefixes = [[], ["status"], ["doctor"], ["show"], ["export"], ["export", "snapshot"], ["export", "history"]]
        if arguments.last == "--help", helpPrefixes.contains(Array(arguments.dropLast())) {
            return .help
        }
        if arguments == ["status"] {
            return .status(json: false)
        }
        if arguments == ["status", "--json"] {
            return .status(json: true)
        }
        if arguments == ["doctor"] {
            return .doctor
        }
        if arguments.first == "show" {
            guard arguments.count >= 2, let pid = Int32(arguments[1]), pid > 0 else {
                throw CLIUsageError(message: "show needs a positive PID")
            }
            let flags = Array(arguments.dropFirst(2))
            guard Set(flags).count == flags.count, flags.allSatisfy({ ["--json", "--include-command-lines"].contains($0) }) else {
                throw CLIUsageError(message: "Unexpected or repeated show flag")
            }
            return .show(pid: pid, json: flags.contains("--json"), includeCommandLines: flags.contains("--include-command-lines"))
        }
        guard arguments.count >= 2, arguments[0] == "export",
              ["snapshot", "history"].contains(arguments[1])
        else {
            throw CLIUsageError(message: "Unknown or incomplete command")
        }
        let snapshot = arguments[1] == "snapshot"
        var format = ExportFormat.json
        var hasFormat = false
        var all = false
        var series: [String]?
        var index = 2
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--json", "--csv":
                guard !hasFormat else { throw CLIUsageError(message: "Choose only one output format") }
                hasFormat = true
                format = argument == "--json" ? .json : .csv
            case "--all" where snapshot && !all:
                all = true
            case "--series" where !snapshot && series == nil:
                index += 1
                var selectors: [String] = []
                while index < arguments.count, !arguments[index].hasPrefix("-") {
                    guard !arguments[index].isEmpty else { throw CLIUsageError(message: "History series cannot be empty") }
                    selectors.append(arguments[index])
                    index += 1
                }
                guard !selectors.isEmpty else { throw CLIUsageError(message: "--series needs system or process keys") }
                series = selectors
                continue
            default:
                throw CLIUsageError(message: "Unexpected argument: \(argument)")
            }
            index += 1
        }
        return snapshot ? .snapshot(format: format, all: all) : .history(format: format, series: series ?? ["system"])
    }
}

extension CLICommand {
    var requestedPermissions: PermissionSet {
        if case .show(_, _, true) = self {
            return [.includeCommandLines]
        }
        return []
    }
}

func showProcess(service: any MonitorService, pid: Int32) async throws -> ProcessSample {
    let page = try await service.listProcesses(ProcessQuery(search: String(pid), filter: .all, limit: 1))
    guard let sample = page.items.first(where: { $0.pid == pid }) else { throw AgentError.notFound("Process is not visible or has exited") }
    return try await service.process(key: sample.processKey)
}

func processSummary(_ sample: ProcessSample) -> String {
    var lines = ["\(sample.name) (\(sample.pid))", "Path: \(sample.path ?? "—")", "Launched by (root first):"]
    for (index, ancestor) in (sample.ancestors ?? []).reversed().enumerated() {
        lines.append(String(repeating: "  ", count: index + 1) + "\(ancestor.name) (\(ancestor.pid))")
        if let command = ancestor.commandLine {
            lines.append(String(repeating: "  ", count: index + 2) + command.displayText)
        }
    }
    if sample.ancestorsIncomplete == true {
        lines.append("Parent chain incomplete")
    }
    lines.append("Direct children: \(sample.childrenCount.map(String.init) ?? "—")")
    if let command = sample.commandLine {
        lines.append("Command: \(command.displayText)")
        lines.append("Working directory: \(sample.cwd?.value ?? "— (\(sample.cwd?.status.rawValue ?? "unsupported"))")")
    } else {
        lines.append("Command lines hidden — enable include_command_lines in Settings and pass --include-command-lines")
    }
    return lines.joined(separator: "\n") + "\n"
}

struct CLIUsageError: Error {
    let message: String
}

func exportSnapshot(service: any MonitorService, all: Bool) async throws -> Snapshot {
    var query = try ProcessQuery(filter: all ? .all : .mine, limit: all ? 200 : 50)
    let first = try await service.listProcesses(query)
    var items = first.items
    var cursor = first.nextCursor
    var seen: Set<String> = []
    while all, let next = cursor {
        guard seen.insert(next).inserted else { throw AgentError.invalidCursor("Agent repeated a snapshot cursor") }
        query.cursor = next
        let page = try await service.listProcesses(query)
        guard page.snapshot.agentInstanceID == first.snapshot.agentInstanceID,
              page.snapshot.snapshotID == first.snapshot.snapshotID
        else {
            throw AgentError.invalidCursor("Snapshot changed during export; retry the export")
        }
        items += page.items
        cursor = page.nextCursor
    }
    return Snapshot(header: first.snapshot, processes: items)
}

func jsonOutput(_ value: some Encodable) throws -> String {
    let data = try ProcglintJSON.encoder().encode(value)
    guard let text = String(bytes: data, encoding: .utf8) else { throw AgentError.internalError("Invalid JSON output encoding") }
    return text + "\n"
}

struct CLIStatus: Encodable {
    var status: MonitorStatus
    var system: SystemMetrics?

    func encode(to encoder: any Encoder) throws {
        try status.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(system, forKey: .system)
    }

    enum CodingKeys: String, CodingKey { case system }
}

func statusSummary(_ status: MonitorStatus, system: SystemMetrics? = nil) -> String {
    let interval = status.effectiveIntervalMS.map { "\($0.milliseconds) ms" } ?? "none"
    let cpu = status.agentCPUPercent.value.map { "\($0)%" } ?? status.agentCPUPercent.status.rawValue
    let coverage = status.lastCoverage
    let failures = status.failures.keys.sorted().map { "\($0)=\(status.failures[$0]!)" }.joined(separator: ", ")
    let clients = status.clients.map { "\($0.kind.rawValue) pid \($0.pid)" }.joined(separator: ", ")
    return """
    Agent: pid \(status.agentPID), instance \(status.agentInstanceID)
    Overhead: CPU \(cpu), footprint \(status.agentFootprintBytes) bytes
    \(memorySummary(system))
    Sampling: \(status.samplingActive ? "active" : "idle"), effective interval \(interval)
    Collections: \(status.collectionsTotal), last \(status.lastCollectionMS) ms, p95 \(status.collectionP95MS) ms
    Coverage: \(coverage.sampled)/\(coverage.enumerated) sampled, \(coverage.permissionDenied) denied, \(coverage.exitedDuringSample) exited
    Failures: \(failures.isEmpty ? "none" : failures)
    Leases: \(status.leases.count); clients: \(clients.isEmpty ? "none" : clients)
    History: \(status.historyBytes) bytes
    Policy: revision \(status.policy.revision), GUI \(status.policy.guiIntervalMS.milliseconds) ms, menu bar \(status.policy.menuBarIntervalMS.milliseconds) ms, history \(status.policy.historyMinutes) min, max process series \(status.policy.maxProcessSeries)
    """ + "\n"
}

private func memorySummary(_ system: SystemMetrics?) -> String {
    var pressure = system?.memoryPressure.value?.rawValue.capitalized ?? "Unavailable"
    if let metric = system?.memoryPressurePercent {
        if let value = metric.value {
            pressure += String(format: " (%.0f%%)", locale: Locale(identifier: "en_US_POSIX"), value)
        } else {
            pressure += " (\(metric.status.rawValue))"
        }
    }
    func bytes(_ metric: Metric?) -> String {
        guard let metric, let value = metric.value else { return "unavailable (\(metric?.status.rawValue ?? "unsupported"))" }
        return String(format: "%.0f bytes", locale: Locale(identifier: "en_US_POSIX"), value)
    }
    return "Memory pressure: \(pressure); Swap: \(bytes(system?.swapUsedBytes)) used of \(bytes(system?.swapTotalBytes))"
}

func containingApp(executable: URL) -> URL? {
    let helper = executable.resolvingSymlinksInPath().deletingLastPathComponent()
    let contents = helper.deletingLastPathComponent()
    let app = contents.deletingLastPathComponent()
    guard helper.lastPathComponent == "Helpers", contents.lastPathComponent == "Contents",
          app.pathExtension.lowercased() == "app" else { return nil }
    return app
}

func versionOutput(executable: URL) -> String {
    let info = containingApp(executable: executable).flatMap { Bundle(url: $0)?.infoDictionary }
    let parts = ["CFBundleShortVersionString", "ProcglintGitCommit"].map { key in
        let value = (info?[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty || value.hasPrefix("$(") ? "unknown" : value
    }
    return "procglint \(parts[0]) (\(parts[1]))\n"
}

func doctorReport(bundle: URL?, registration: AgentRegistration.Status?, agent: Result<MonitorStatus, any Error>) -> (text: String, healthy: Bool) {
    var lines: [String] = []
    var healthy = true
    if let bundle {
        lines.append("App bundle: \(bundle.path)")
        switch registration {
        case .enabled: lines.append("Agent registration: enabled")
        case .requiresApproval:
            lines.append("Agent registration: requires approval")
            healthy = false
        case .notRegistered, .notFound:
            // The CLI runs as a bundle helper, where SMAppService cannot see the app's registration;
            // a reachable agent is the stronger signal. Unreachable: .notFound means never registered.
            if case .success = agent {
                lines.append("Agent registration: registered (agent is running)")
            } else {
                lines.append("Agent registration: not registered")
                healthy = false
            }
        case nil:
            lines.append("Agent registration: unknown")
            healthy = false
        }
    } else {
        lines.append("Agent registration: not applicable (executable is outside an app bundle; development build)")
    }
    switch agent {
    case let .success(status): lines.append("Agent: reachable (pid \(status.agentPID), instance \(status.agentInstanceID))")
    case let .failure(error):
        let detail = (error as? AgentError).map { "\($0.code.rawValue): \($0.message)" } ?? error.localizedDescription
        lines.append("Agent: unreachable — \(detail)")
        healthy = false
    }
    if !healthy {
        lines.append("Recovery: open Procglint.app → Settings → Register.")
        lines.append("Approve Procglint in System Settings › General › Login Items (Allow in the Background).")
        lines.append("For development builds, run `scripts/dev-agent.sh start` from the repository.")
    }
    return (lines.joined(separator: "\n") + "\n", healthy)
}

func csvRow(_ cells: [String]) -> String {
    cells.map { cell in
        if cell.contains(where: { $0 == "," || $0 == "\"" || $0 == "\r" || $0 == "\n" }) {
            return "\"" + cell.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return cell
    }.joined(separator: ",") + "\r\n"
}

private func dateCell(_ date: Date) -> String {
    date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true, timeZone: .gmt))
}

private func metricCells(_ metric: Metric?) -> [String] {
    [metric?.value.map { String($0) } ?? "", metric?.status.rawValue ?? ""]
}

private func metricHeaders(_ names: [String]) -> [String] {
    names.flatMap { [$0, $0 + "_status"] }
}

func snapshotCSV(_ snapshot: Snapshot) -> String {
    let system = snapshot.system
    let coverage = snapshot.coverage
    let snapshotHeaders = ["agent_instance_id", "snapshot_id", "sampled_at", "interval_ms", "age_ms", "snapshot_status",
                           "coverage_enumerated", "coverage_sampled", "coverage_permission_denied", "coverage_exited_during_sample"]
    let systemHeaders = metricHeaders(["system_cpu_percent"]) + ["physical_memory_bytes", "page_size", "memory_used_bytes", "wired_bytes",
                                                                 "compressed_bytes", "active_bytes", "inactive_bytes", "free_bytes"]
        + ["memory_pressure", "memory_pressure_status"] + metricHeaders(["swap_used_bytes", "swap_total_bytes"])
    let processHeaders = ["process_key", "pid", "ppid", "name", "uid", "user", "is_own", "process_status", "cpu_time_ns", "start_time", "path"]
    let metrics = ["cpu_percent", "footprint_bytes", "rss_bytes", "disk_read_bytes", "disk_written_bytes", "disk_read_bps", "disk_write_bps"]
    let common = [snapshot.agentInstanceID, snapshot.snapshotID, dateCell(snapshot.sampledAt), snapshot.intervalMS.map(String.init) ?? "",
                  String(snapshot.ageMS), snapshot.status.rawValue, String(coverage.enumerated), String(coverage.sampled),
                  String(coverage.permissionDenied), String(coverage.exitedDuringSample)]
    let memory = [system.physicalMemoryBytes, system.pageSize, system.memoryUsedBytes, system.wiredBytes, system.compressedBytes,
                  system.activeBytes, system.inactiveBytes, system.freeBytes].map(String.init)
    let pressure = [system.memoryPressure.value?.rawValue ?? "", system.memoryPressure.status.rawValue]
    let prefix = common + metricCells(system.cpuPercent) + memory + pressure + metricCells(system.swapUsedBytes) + metricCells(system.swapTotalBytes)
    var output = csvRow(snapshotHeaders + systemHeaders + processHeaders + metricHeaders(metrics))
    for process in snapshot.processes {
        let identity = [process.processKey.rawValue, String(process.pid), process.ppid.map(String.init) ?? "", process.name,
                        String(process.uid), process.user, String(process.isOwn), process.status.rawValue,
                        process.cpuTimeNS.map(String.init) ?? "", dateCell(process.startTime), process.path ?? ""]
        let processMetrics: [Metric?] = [process.cpuPercent, process.footprintBytes, process.rssBytes, process.diskReadBytes,
                                         process.diskWrittenBytes, process.diskReadBps, process.diskWriteBps]
        let values: [String] = processMetrics.flatMap { metricCells($0) }
        output += csvRow(prefix + identity + values)
    }
    if snapshot.processes.isEmpty {
        output += csvRow(prefix + Array(repeating: "", count: processHeaders.count + metrics.count * 2))
    }
    return output
}

func historyCSV(_ history: [HistorySeries]) -> String {
    let names = ["cpu_percent", "footprint_bytes", "disk_read_bps", "disk_write_bps", "memory_used_bytes"]
    var output = csvRow(["series", "record_type", "t"] + metricHeaders(names) + ["gap_from", "gap_to"])
    for series in history {
        for point in series.points {
            let pointMetrics: [Metric?] = [point.cpuPercent, point.footprintBytes, point.diskReadBps, point.diskWriteBps, point.memoryUsedBytes]
            let values: [String] = pointMetrics.flatMap { metricCells($0) }
            output += csvRow([series.series, "point", dateCell(point.t)] + values + ["", ""])
        }
        for gap in series.gaps {
            let emptyMetrics = Array(repeating: "", count: names.count * 2)
            output += csvRow([series.series, "gap", ""] + emptyMetrics + [dateCell(gap.from), dateCell(gap.to)])
        }
        if series.points.isEmpty, series.gaps.isEmpty {
            output += csvRow([series.series, "series", ""] + Array(repeating: "", count: names.count * 2 + 2))
        }
    }
    return output
}
