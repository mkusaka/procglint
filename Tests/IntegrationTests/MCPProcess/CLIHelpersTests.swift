import Foundation
import ProcglintCore
import ProcglintIPC
import Testing

private func fixtureSnapshot() throws -> Snapshot {
    let date = Date(timeIntervalSince1970: 1000)
    let system = SystemMetrics(cpuPercent: .warmingUp, physicalMemoryBytes: 4096, pageSize: 16384, memoryUsedBytes: 1024,
                               wiredBytes: 128, compressedBytes: 128, activeBytes: 768, inactiveBytes: 512, freeBytes: 2560,
                               memoryPressure: .ok(.critical), memoryPressurePercent: .ok(39), swapUsedBytes: .ok(10_400_000_000), swapTotalBytes: .ok(12_000_000_000))
    let process = try ProcessSample(processKey: ProcessKey("p1.boot-a.42.1"), pid: 42, name: "worker", uid: 501, user: "tester",
                                    isOwn: true, status: .ok, cpuPercent: .warmingUp, cpuTimeNS: 9_007_199_254_740_993,
                                    footprintBytes: .ok(1024), rssBytes: .permissionDenied, diskReadBytes: .ok(0),
                                    diskWrittenBytes: .exited, diskReadBps: .stale, diskWriteBps: .unsupported, startTime: date)
    return Snapshot(agentInstanceID: "agent-a", snapshotID: "agent-a-1", sampledAt: date, intervalMS: nil, ageMS: 0,
                    status: .warmingUp, coverage: Coverage(enumerated: 1, sampled: 1), system: system, processes: [process])
}

private func fixtureStatus() throws -> MonitorStatus {
    try MonitorStatus(agentInstanceID: "agent-a", agentPID: 100, agentCPUPercent: .warmingUp, agentFootprintBytes: 4096,
                      samplingActive: false, effectiveIntervalMS: nil, collectionsTotal: 9_007_199_254_740_993,
                      lastCollectionMS: 2, collectionP95MS: 3, lastCoverage: Coverage(enumerated: 1, sampled: 1), failures: ["denied": 1],
                      leases: [], clients: [], historyBytes: 0, policy: SamplingPolicy())
}

struct CLIHelpersTests {
    @Test func parsesCommandsAndExportDefaults() throws {
        #expect(try CLICommand.parse(["--help"]) == .help)
        #expect(try CLICommand.parse(["export", "history", "--help"]) == .help)
        #expect(try CLICommand.parse(["status"]) == .status(json: false))
        #expect(try CLICommand.parse(["status", "--json"]) == .status(json: true))
        #expect(try CLICommand.parse(["doctor"]) == .doctor)
        #expect(try CLICommand.parse(["export", "snapshot"]) == .snapshot(format: .json, all: false))
        #expect(try CLICommand.parse(["export", "snapshot", "--csv", "--all"]) == .snapshot(format: .csv, all: true))
        #expect(try CLICommand.parse(["export", "snapshot", "--all", "--json"]) == .snapshot(format: .json, all: true))
        #expect(try CLICommand.parse(["export", "history"]) == .history(format: .json, series: ["system"]))
        let selectors = ["system", "p1.boot-a.42.1", "p1.boot-a.43.2"]
        #expect(try CLICommand.parse(["export", "history", "--series"] + selectors + ["--csv"]) == .history(format: .csv, series: selectors))
        #expect(try CLICommand.parse(["export", "history", "--json", "--series", "system"]) == .history(format: .json, series: ["system"]))
    }

    @Test(arguments: [
        ["unknown", "--help"], ["export", "snapshot", "--all", "--all"], ["export", "history", "--series", ""],
        ["export", "history", "--series", "--json"], ["export", "history", "--series", "system", "--series", "system"],
        ["export", "history", "system"], ["status", "--json", "extra"],
    ])
    func rejectsAmbiguousArguments(arguments: [String]) {
        #expect(throws: CLIUsageError.self) { try CLICommand.parse(arguments) }
    }

    @Test func showParsesOptInAndRendersLazyDetail() async throws {
        #expect(try CLICommand.parse(["show", "--help"]) == .help)
        #expect(try CLICommand.parse(["show", "42"]) == .show(pid: 42, json: false, includeCommandLines: false))
        let command = try CLICommand.parse(["show", "42", "--include-command-lines", "--json"])
        #expect(command == .show(pid: 42, json: true, includeCommandLines: true))
        #expect(command.requestedPermissions == [.includeCommandLines])
        #expect(try CLICommand.parse(["show", "42"]).requestedPermissions.isEmpty)
        for arguments in [["show"], ["show", "0"], ["show", "-1"], ["show", "big"],
                          ["show", "42", "--include-command-lines", "--include-command-lines"], ["show", "42", "--csv"]]
        {
            #expect(throws: CLIUsageError.self) { try CLICommand.parse(arguments) }
        }
        let harness = try AgentHarness()
        harness.source.update {
            $0.processes[42]?.bsdInfo.ppid = 43
            $0.commandLines[42] = ProcessCommandLine(arguments: ["node", "server.js", "--token=test-secret"])
            $0.commandLines[43] = ProcessCommandLine(arguments: ["zsh", "-l"])
            $0.workingDirectories[42] = WorkingDirectory(value: "/private/project")
        }
        let plain = harness.client(.cli)
        let hidden = try await showProcess(service: plain, pid: 42)
        #expect(hidden.ancestors?.map(\.pid) == [43])
        #expect(processSummary(hidden).contains("Command lines hidden"))
        let enabled = harness.client(.cli, flags: command.requestedPermissions)
        let detail = try await showProcess(service: enabled, pid: 42)
        let text = processSummary(detail)
        #expect(text.contains("Launched by (root first):\n  worker-43 (43)\n    zsh -l"))
        #expect(text.contains("Parent chain incomplete"))
        #expect(text.contains("Command: node server.js --token=<redacted>"))
        #expect(text.contains("Working directory: /private/project"))
        #expect(!text.contains("test-secret"))
        #expect(try !jsonOutput(detail).contains("test-secret"))
        await plain.invalidate()
        await enabled.invalidate()
        await harness.close()
    }

    @Test func csvUsesRFC4180QuotingAndCRLF() {
        #expect(csvRow(["plain", "", "a,b", "say \"hi\"", "a\rb", "a\nb", "日本語"]) ==
            "plain,,\"a,b\",\"say \"\"hi\"\"\",\"a\rb\",\"a\nb\",日本語\r\n")
    }

    @Test func snapshotCSVPreservesMissingMetricsAndPrecision() throws {
        let snapshot = try fixtureSnapshot()
        let rows = snapshotCSV(snapshot).components(separatedBy: "\r\n")
        let headers = rows[0].components(separatedBy: ",")
        let cells = rows[1].components(separatedBy: ",")
        #expect(headers.count == cells.count)
        let row = Dictionary(uniqueKeysWithValues: zip(headers, cells))
        #expect(row["cpu_percent"] == "")
        #expect(row["cpu_percent_status"] == "warming_up")
        #expect(row["rss_bytes"] == "")
        #expect(row["rss_bytes_status"] == "permission_denied")
        #expect(row["disk_written_bytes"] == "")
        #expect(row["disk_written_bytes_status"] == "exited")
        #expect(row["disk_read_bps"] == "")
        #expect(row["disk_read_bps_status"] == "stale")
        #expect(row["disk_write_bps"] == "")
        #expect(row["disk_write_bps_status"] == "unsupported")
        #expect(row["disk_read_bytes"] == "0.0")
        #expect(row["system_cpu_percent"] == "")
        #expect(row["memory_pressure"] == "critical")
        #expect(row["memory_pressure_status"] == "ok")
        #expect(row["swap_used_bytes"] == "10400000000.0")
        #expect(row["swap_total_bytes_status"] == "ok")
        #expect(row["interval_ms"] == "")
        #expect(row["cpu_time_ns"] == "9007199254740993")
        #expect(row["sampled_at"] == "1970-01-01T00:16:40.000Z")
        var named = snapshot
        named.processes[0].name = "worker, \"test\"\nline"
        #expect(snapshotCSV(named).contains("\"worker, \"\"test\"\"\nline\""))
        named.processes = []
        let emptyRows = snapshotCSV(named).components(separatedBy: "\r\n")
        #expect(emptyRows.count == 3)
        #expect(emptyRows[1].components(separatedBy: ",").count == headers.count)
    }

    @Test func historyCSVIncludesGapsAndEmptySeries() {
        let date = Date(timeIntervalSince1970: 1000)
        let series = HistorySeries(series: "system", points: [HistoryPoint(t: date, cpuPercent: .warmingUp, memoryUsedBytes: .ok(1024))],
                                   gaps: [HistoryGap(from: date, to: date.addingTimeInterval(10))])
        let rows = historyCSV([series, HistorySeries(series: "untracked", points: [])]).components(separatedBy: "\r\n")
        let headers = rows[0].components(separatedBy: ",")
        let point = Dictionary(uniqueKeysWithValues: zip(headers, rows[1].components(separatedBy: ",")))
        #expect(point["cpu_percent"] == "")
        #expect(point["cpu_percent_status"] == "warming_up")
        #expect(point["footprint_bytes"] == "")
        #expect(point["memory_used_bytes"] == "1024.0")
        let gap = Dictionary(uniqueKeysWithValues: zip(headers, rows[2].components(separatedBy: ",")))
        #expect(gap["record_type"] == "gap")
        #expect(gap["gap_from"] == "1970-01-01T00:16:40.000Z")
        #expect(gap["gap_to"] == "1970-01-01T00:16:50.000Z")
        #expect(rows[3].hasPrefix("untracked,series,"))
        #expect(rows.dropLast().allSatisfy { $0.components(separatedBy: ",").count == headers.count })
    }

    @Test func JSONExportsUseContractEncoding() throws {
        let snapshot = try fixtureSnapshot()
        let json = try jsonOutput(snapshot)
        #expect(json.contains("\"cpu_time_ns\":\"9007199254740993\""))
        #expect(json.contains("\"interval_ms\":null"))
        #expect(try ProcglintJSON.decoder().decode(Snapshot.self, from: Data(json.utf8)) == snapshot)
        let status = try fixtureStatus()
        #expect(try jsonOutput(status).contains("\"collections_total\":\"9007199254740993\""))
        let summary = statusSummary(status)
        #expect(summary.contains("CPU warming_up"))
        #expect(summary.contains("Sampling: idle, effective interval none"))
        #expect(summary.contains("denied=1"))
    }

    @Test func batteryStatusAndPowerColumns() throws {
        let battery = BatteryMetrics(percent: .ok(69), isCharging: true, externalPower: true,
                                     timeRemainingMinutes: .ok(113), cycleCount: .ok(5), healthPercent: .ok(100), systemPowerMW: .ok(33100))
        var snapshot = try fixtureSnapshot()
        snapshot.system.battery = battery
        snapshot.processes[0].powerMW = .ok(3000)
        let summary = try statusSummary(fixtureStatus(), system: snapshot.system)
        #expect(summary.contains("Battery: 69% charging · 33.1 W system · health 100% · 5 cycles · 1:53 to full"))
        #expect(processSummary(snapshot.processes[0]).contains("Power: 3.0 W"))
        let rows = snapshotCSV(snapshot).components(separatedBy: "\r\n")
        let cells = Dictionary(uniqueKeysWithValues: zip(rows[0].components(separatedBy: ","), rows[1].components(separatedBy: ",")))
        #expect(cells["power_mw"] == "3000.0")
        #expect(cells["power_mw_status"] == "ok")
        let point = HistoryPoint(t: snapshot.sampledAt, cpuPercent: .warmingUp, systemPowerMW: .ok(33100), batteryPercent: .ok(69), powerMW: .unsupported)
        let historyRows = historyCSV([HistorySeries(series: "system", points: [point])]).components(separatedBy: "\r\n")
        let history = Dictionary(uniqueKeysWithValues: zip(historyRows[0].components(separatedBy: ","), historyRows[1].components(separatedBy: ",")))
        #expect(history["system_power_mw"] == "33100.0")
        #expect(history["battery_percent"] == "69.0")
        #expect(history["power_mw"] == "")
        #expect(history["power_mw_status"] == "unsupported")
        var discharging = battery
        discharging.isCharging = false
        discharging.externalPower = false
        #expect(batterySummary(discharging).contains("69% discharging"))
        #expect(batterySummary(discharging).contains("1:53 remaining"))
        discharging.externalPower = true
        #expect(batterySummary(discharging).contains("on external power"))
        #expect(batterySummary(BatteryMetrics()).contains("time unavailable (unsupported)"))
        #expect(batterySummary(nil) == "Battery: unavailable (no battery reported)")
    }

    @Test func snapshotSortFlagIsValidatedAndForwarded() async throws {
        #expect(try CLICommand.parse(["export", "snapshot", "--sort", "power", "--csv"]) == .snapshot(format: .csv, all: false, sort: .power))
        for arguments in [["export", "snapshot", "--sort"], ["export", "snapshot", "--sort", "watts"],
                          ["export", "snapshot", "--sort", "power", "--sort", "cpu"], ["export", "history", "--sort", "power"]]
        {
            #expect(throws: CLIUsageError.self) { try CLICommand.parse(arguments) }
        }
        let snapshot = try fixtureSnapshot()
        let service = ExportMonitor(pages: [ProcessPage(snapshot: snapshot.header, items: snapshot.processes, totalMatched: 1)])
        _ = try await exportSnapshot(service: service, all: false, sort: .power)
        #expect(await service.queries.first?.sort == .power)
    }

    @Test func statusIncludesPressureSwapAndExistingDiagnostics() throws {
        let status = try fixtureStatus()
        var system = try fixtureSnapshot().system
        let text = statusSummary(status, system: system)
        #expect(text.contains("Memory pressure: Critical (39%); Swap: 10400000000 bytes used of 12000000000 bytes"))
        #expect(text.contains("Sampling: idle, effective interval none"))
        let json = try jsonOutput(CLIStatus(status: status, system: system))
        #expect(json.contains("\"collections_total\":\"9007199254740993\""))
        #expect(json.contains("\"memory_pressure\":{\"status\":\"ok\",\"value\":\"critical\"}"))
        #expect(json.contains("\"swap_used_bytes\":{\"status\":\"ok\",\"value\":10400000000}"))
        #expect(json.contains("\"memory_pressure_percent\":{\"status\":\"ok\",\"value\":39}"))
        #expect(statusSummary(status).contains("Memory pressure: Unavailable; Swap: unavailable (unsupported)"))
        #expect(try jsonOutput(CLIStatus(status: status, system: nil)).contains("\"system\":null"))
        system.memoryPressure = .unsupported
        system.memoryPressurePercent = .unsupported
        system.swapUsedBytes = .permissionDenied
        #expect(statusSummary(status, system: system).contains("Memory pressure: Unavailable (unsupported); Swap: unavailable (permission_denied)"))
        system.memoryPressure = .ok(.normal)
        system.memoryPressurePercent = .ok(39)
        system.swapUsedBytes = .ok(0)
        #expect(statusSummary(status, system: system).contains("Memory pressure: Normal (39%); Swap: 0 bytes"))
    }

    @Test func findsAppFromHelperPathNotMainBundle() {
        let bundle = URL(fileURLWithPath: "/Applications/Procglint.app")
        #expect(containingApp(executable: bundle.appendingPathComponent("Contents/Helpers/procglint"))?.path == bundle.path)
        #expect(containingApp(executable: URL(fileURLWithPath: "/tmp/debug/procglint")) == nil)
        #expect(containingApp(executable: bundle.appendingPathComponent("Contents/MacOS/procglint")) == nil)
        #expect(containingApp(executable: URL(fileURLWithPath: "/tmp/not-app/Contents/Helpers/procglint")) == nil)
    }

    @Test(arguments: [AgentRegistration.Status.enabled, .notRegistered, .requiresApproval, .notFound])
    func doctorChecksRegistrationEvenWhenAgentIsReachable(registration: AgentRegistration.Status) throws {
        let report = try doctorReport(bundle: URL(fileURLWithPath: "/Applications/Procglint.app"), registration: registration,
                                      agent: .success(fixtureStatus()))
        // From the CLI helper SMAppService cannot see the app's registration, so a reachable agent wins
        // except when approval is still pending.
        #expect(report.healthy == (registration != .requiresApproval))
        #expect(report.text.contains("Agent registration:"))
        if registration == .notRegistered || registration == .notFound {
            #expect(report.text.contains("registered (agent is running)"))
        }
        #expect(report.text.contains("Agent: reachable"))
        if !report.healthy {
            #expect(report.text.contains("Settings → Register"))
            #expect(report.text.contains("Login Items"))
        }
    }

    @Test func doctorDevBuildNeedsReachabilityNotRegistration() throws {
        let healthy = try doctorReport(bundle: nil, registration: nil, agent: .success(fixtureStatus()))
        #expect(healthy.healthy)
        let failed = doctorReport(bundle: nil, registration: nil, agent: .failure(AgentError.agentUnavailable("offline")))
        #expect(!failed.healthy)
        #expect(failed.text.contains("agent_unavailable: offline"))
        #expect(failed.text.contains("scripts/dev-agent.sh start"))
    }

    @Test func snapshotAllPagesWithoutMixingSnapshots() async throws {
        let snapshot = try fixtureSnapshot()
        let first = ProcessPage(snapshot: snapshot.header, items: snapshot.processes, nextCursor: "page-2", totalMatched: 2)
        let last = ProcessPage(snapshot: snapshot.header, items: snapshot.processes, totalMatched: 2)
        let all = ExportMonitor(pages: [first, last])
        #expect(try await exportSnapshot(service: all, all: true).processes.count == 2)
        let queries = await all.queries
        #expect(queries.map(\.filter) == [.all, .all])
        #expect(queries.map(\.limit) == [200, 200])
        #expect(queries.map(\.cursor) == [nil, "page-2"])
        let mine = ExportMonitor(pages: [first])
        #expect(try await exportSnapshot(service: mine, all: false).processes.count == 1)
        #expect(await mine.queries.map(\.filter) == [.mine])
        #expect(await mine.queries.map(\.limit) == [50])
    }

    @Test(arguments: [false, true])
    func snapshotRejectsChangedOrRepeatingPages(repeated: Bool) async throws {
        let snapshot = try fixtureSnapshot()
        let first = ProcessPage(snapshot: snapshot.header, items: [], nextCursor: "page-2", totalMatched: 2)
        var second = first
        if !repeated {
            second.snapshot.snapshotID = "agent-a-2"
        }
        let service = ExportMonitor(pages: [first, second])
        await #expect(throws: AgentError.self) { try await exportSnapshot(service: service, all: true) }
    }
}

private actor ExportMonitor: MonitorService {
    let pages: [ProcessPage]
    var queries: [ProcessQuery] = []
    init(pages: [ProcessPage]) {
        self.pages = pages
    }

    func listProcesses(_ query: ProcessQuery) throws -> ProcessPage {
        let index = queries.count
        queries.append(query)
        guard index < pages.count else { throw AgentError.internalError("Unexpected page request") }
        return pages[index]
    }

    func snapshot(top _: Int, sort _: ProcessSort) throws -> Snapshot {
        throw unused
    }

    func process(key _: ProcessKey) throws -> ProcessSample {
        throw unused
    }

    func history(_: HistoryRequest) throws -> [HistorySeries] {
        throw unused
    }

    func status() throws -> MonitorStatus {
        throw unused
    }

    func setLease(_: LeaseRequest) throws -> SamplingLease {
        throw unused
    }

    func releaseLease(id _: String) throws {
        throw unused
    }

    func startObservation(_: ObservationRequest) throws -> Observation {
        throw unused
    }

    func stopObservation(id _: String) throws {
        throw unused
    }

    func pin(key _: ProcessKey, pinned _: Bool) throws {
        throw unused
    }

    func policy() throws -> SamplingPolicy {
        throw unused
    }

    func setPolicy(_: SamplingPolicy, expectedRevision _: Int) throws -> SamplingPolicy {
        throw unused
    }

    func prepareTermination(key _: ProcessKey, signal _: TerminationSignal) throws -> TerminationTicket {
        throw unused
    }

    func terminate(token _: String) throws -> TerminationResult {
        throw unused
    }

    private var unused: AgentError {
        .internalError("Unused export test method")
    }
}
