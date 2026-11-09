import Foundation
import ProcglintCore

struct MetricText: Equatable {
    var text: String
    var reason: String?
}

enum Display {
    static func bytes(_ value: Double) -> String {
        guard value.isFinite, value >= 0 else { return "—" }
        let units = ["B", "KiB", "MiB", "GiB", "TiB", "PiB", "EiB"]
        var scaled = value
        var unit = 0
        while scaled >= 1024, unit < units.count - 1 {
            scaled /= 1024
            unit += 1
        }
        return String(format: unit == 0 ? "%.0f %@" : "%.1f %@", locale: Locale(identifier: "en_US_POSIX"), scaled, units[unit])
    }

    static func metric(_ metric: Metric, format: (Double) -> String) -> MetricText {
        guard metric.status == .ok, let value = metric.value, value.isFinite else {
            return MetricText(text: "—", reason: metric.status == .ok ? "invalid value" : metric.status.rawValue)
        }
        return MetricText(text: format(value), reason: nil)
    }

    static func percent(_ value: Double) -> String {
        String(format: "%.1f%%", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    static func error(_ error: any Error) -> String {
        if let error = error as? AgentError {
            return "\(error.code.rawValue): \(error.message)"
        }
        return error.localizedDescription
    }

    static func memoryBytes(_ value: Double) -> String {
        guard value.isFinite, value >= 0 else { return "—" }
        // Match installed RAM capacities and Activity Monitor's memory-style GB labels.
        let units = ["B", "KB", "MB", "GB", "TB", "PB", "EB"]
        var scaled = value
        var unit = 0
        while scaled >= 1024, unit < units.count - 1 {
            scaled /= 1024
            unit += 1
        }
        return String(format: scaled.rounded() == scaled ? "%.0f %@" : "%.1f %@",
                      locale: Locale(identifier: "en_US_POSIX"), scaled, units[unit])
    }

    static func pressure(_ header: SnapshotHeader?) -> String {
        guard let header, header.status != .unavailable, let pressure = header.system.memoryPressure.value else {
            return "Memory pressure: Unavailable"
        }
        let percent = metric(header.system.memoryPressurePercent, format: { String(format: "%.0f%%", $0) })
        let suffix = percent.reason.map { " · — (\($0))" } ?? " · \(percent.text)"
        return "Memory pressure: \(pressure.rawValue.capitalized)\(suffix)"
    }

    static func summary(_ header: SnapshotHeader?) -> String {
        guard let header, header.status != .unavailable else {
            return "\(pressure(nil))\nUsed — of — · Swap — · Compressed —\nCPU — · unavailable"
        }
        let system = header.system
        let cpu = metric(system.cpuPercent, format: percent)
        let swap = metric(system.swapUsedBytes, format: memoryBytes)
        let swapText = swap.text + (swap.reason.map { " (\($0))" } ?? "")
        return "\(pressure(header))\nUsed \(memoryBytes(Double(system.memoryUsedBytes))) of \(memoryBytes(Double(system.physicalMemoryBytes))) · Swap \(swapText) · Compressed \(memoryBytes(Double(system.compressedBytes)))\nCPU \(cpu.text)\(cpu.reason.map { " (\($0))" } ?? "") · \(header.status.rawValue)"
    }

    static func summaryTooltip(_ header: SnapshotHeader?) -> String {
        guard let header, header.status != .unavailable else { return "System memory unavailable" }
        return "Wired: \(memoryBytes(Double(header.system.wiredBytes)))\nMemory pressure status: \(header.system.memoryPressure.status.rawValue)\nSwap total: \(metric(header.system.swapTotalBytes, format: memoryBytes).text)"
    }
}

enum ProcessColumn: String, CaseIterable {
    case name, cpu, footprint, readRate, writeRate, pid, user, cpuTime, rss, readBytes, writtenBytes

    var title: String {
        switch self {
        case .name: "Name"
        case .cpu: "CPU"
        case .footprint: "Memory"
        case .readRate: "Read/s"
        case .writeRate: "Write/s"
        case .pid: "PID"
        case .user: "User"
        case .cpuTime: "CPU time"
        case .rss: "RSS"
        case .readBytes: "Read total"
        case .writtenBytes: "Written total"
        }
    }

    var tooltip: String? {
        self == .footprint ? "Same as Activity Monitor's Memory column (phys_footprint): memory this process is charged for, including compressed and swapped pages. RSS (optional column) counts shared pages and is usually misleading." : nil
    }

    var numeric: Bool {
        self != .name && self != .user
    }

    var optional: Bool {
        [.cpuTime, .rss, .readBytes, .writtenBytes].contains(self)
    }

    var sort: ProcessSort? {
        switch self {
        case .name: .name
        case .cpu: .cpu
        case .footprint: .footprint
        case .readRate: .diskReadBps
        case .writeRate: .diskWriteBps
        case .pid: .pid
        case .cpuTime: .cpuTime
        case .rss: .rss
        case .user, .readBytes, .writtenBytes: nil
        }
    }

    func text(for process: ProcessSample) -> MetricText {
        switch self {
        case .name: MetricText(text: process.name, reason: process.status == .ok ? nil : process.status.rawValue)
        case .pid: MetricText(text: String(process.pid), reason: nil)
        case .user: MetricText(text: process.user, reason: nil)
        case .cpu: Display.metric(process.cpuPercent, format: Display.percent)
        case .footprint: Display.metric(process.footprintBytes, format: Display.bytes)
        case .rss: Display.metric(process.rssBytes, format: Display.bytes)
        case .readRate: Display.metric(process.diskReadBps) { Display.bytes($0) + "/s" }
        case .writeRate: Display.metric(process.diskWriteBps) { Display.bytes($0) + "/s" }
        case .readBytes: Display.metric(process.diskReadBytes, format: Display.bytes)
        case .writtenBytes: Display.metric(process.diskWrittenBytes, format: Display.bytes)
        case .cpuTime:
            if let time = process.cpuTimeNS {
                MetricText(text: String(format: "%.1f s", Double(time) / 1_000_000_000), reason: nil)
            } else {
                MetricText(text: "—", reason: process.status == .ok ? "not readable" : process.status.rawValue)
            }
        }
    }
}
