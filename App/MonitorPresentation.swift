import Foundation
import ProcglintCore

/// Swap/compressed history is presentation-only: the wire history has neither field, so never backfill it.
struct MemorySummaryPoint: Equatable {
    var time: Date
    var swap: Metric
    var compressed: Metric
    var startsSegment: Bool
}

enum SummaryCard: String, CaseIterable, Identifiable {
    case cpu, memory, pressure, swap, compressed, network, battery

    static func visible(in header: SnapshotHeader?) -> [Self] {
        allCases.filter { $0 != .battery || header?.system.battery != nil }
    }

    var id: Self {
        self
    }

    var title: String {
        switch self {
        case .cpu: "CPU"
        case .memory: "Memory used / physical"
        case .pressure: "Memory pressure"
        case .swap: "Swap"
        case .compressed: "Compressed"
        case .network: "Network"
        case .battery: "Battery"
        }
    }

    func symbol(_ header: SnapshotHeader?) -> String {
        switch self {
        case .cpu: "cpu"
        case .memory: "memorychip"
        case .pressure: "gauge.with.dots.needle.50percent"
        case .swap: "arrow.left.arrow.right"
        case .compressed: "arrow.down.right.and.arrow.up.left"
        case .network: "network"
        case .battery: header?.system.battery.map { BatteryDisplay(battery: $0).symbol } ?? "battery.0"
        }
    }

    func value(_ header: SnapshotHeader?) -> String {
        guard let header, header.status != .unavailable else { return "—" }
        let system = header.system
        switch self {
        case .cpu: return Display.metric(system.cpuPercent, format: Display.percent).text
        case .memory: return Display.memoryBytes(Double(system.memoryUsedBytes))
        case .pressure: return Display.metric(system.memoryPressurePercent, format: { String(format: "%.0f%%", $0) }).text
        case .swap: return Display.metric(system.swapUsedBytes, format: Display.memoryBytes).text
        case .compressed: return Display.memoryBytes(Double(system.compressedBytes))
        case .network: return "↓ " + Display.metric(system.networkReceiveBps, format: Display.networkRate).text
        case .battery: return system.battery.map { Display.metric($0.percent, format: { String(format: "%.0f%%", $0) }).text } ?? "—"
        }
    }

    func caption(_ header: SnapshotHeader?) -> String {
        guard let header, header.status != .unavailable else { return "Unavailable" }
        switch self {
        case .cpu: return Display.metric(header.system.cpuPercent, format: Display.percent).reason ?? "Across all cores"
        case .memory: return "of \(Display.memoryBytes(Double(header.system.physicalMemoryBytes)))"
        case .pressure: return header.system.memoryPressure.value?.rawValue.capitalized ?? "Unavailable"
        case .swap: return Display.metric(header.system.swapUsedBytes, format: Display.memoryBytes).reason ?? "On disk"
        case .compressed: return "In memory"
        case .network: return "↑ " + Display.metric(header.system.networkSendBps, format: Display.networkRate).text
        case .battery: return header.system.battery.map { BatteryDisplay(battery: $0).caption } ?? "Unavailable"
        }
    }

    var chart: HistoryChartKind {
        switch self {
        case .cpu: .systemCPU
        case .memory: .systemMemory
        case .pressure: .pressure
        case .swap: .swap
        case .compressed: .compressed
        case .network: .systemNetwork
        case .battery: .systemPower
        }
    }
}

extension Display {
    static func identity(_ detail: ProcessSample) -> String {
        "\(detail.name)\nPID \(detail.pid) · \(detail.user) (uid \(detail.uid))\nKey: \(detail.processKey.rawValue)\nStarted: \(detail.startTime.formatted(date: .abbreviated, time: .standard))\nStatus: \(detail.status.rawValue)"
    }

    static func path(_ detail: ProcessSample, permissions: PermissionSet) -> String {
        permissions.contains(.includePaths) ? "Path: \(detail.path ?? "— (not available)")" : "Path: — (permission_denied; enable include_paths in Settings)"
    }

    static func commandLine(_ detail: ProcessSample, permissions: PermissionSet) -> String {
        permissions.contains(.includeCommandLines) ? "Command: \(detail.commandLine?.displayText ?? "— (unsupported)")" : "Command lines hidden — enable in Settings"
    }

    static func cwd(_ detail: ProcessSample, permissions: PermissionSet) -> String {
        guard permissions.contains(.includeCommandLines) else { return "" }
        return "Working directory: \(detail.cwd?.value ?? "— (\(detail.cwd?.status.rawValue ?? "unsupported"))")"
    }

    static func lineageStatus(_ detail: ProcessSample) -> String {
        let incomplete = detail.ancestorsIncomplete == true ? " · Parent chain incomplete" : ""
        return "Direct children: \(detail.childrenCount.map(String.init) ?? "—")\(incomplete)"
    }
}

extension MonitorViewModel {
    var identityText: String {
        detail.map(Display.identity) ?? "Select a process"
    }

    var pathText: String {
        detail.map { Display.path($0, permissions: permissions) } ?? ""
    }

    var commandLineText: String {
        detail.map { Display.commandLine($0, permissions: permissions) } ?? ""
    }

    var cwdText: String {
        detail.map { Display.cwd($0, permissions: permissions) } ?? ""
    }

    var rootAncestors: [ProcessAncestor] {
        Array((detail?.ancestors ?? []).reversed())
    }

    var lineageStatusText: String {
        detail.map(Display.lineageStatus) ?? ""
    }

    func canSelectAncestor(_ ancestor: ProcessAncestor) -> Bool {
        ancestor.processKey.map { key in rows.contains { $0.processKey == key } } ?? false
    }

    func selectAncestor(_ ancestor: ProcessAncestor) async {
        guard canSelectAncestor(ancestor) else { return }
        select(ancestor.processKey)
        await refreshInspector()
    }

    var canQuit: Bool {
        detail?.isOwn == true && detail?.status == .ok && header != nil && header?.status != .unavailable && permissions.contains(.terminate) && !terminating
    }

    var canForceQuit: Bool {
        canQuit && permissions.contains(.forceKill)
    }
}
