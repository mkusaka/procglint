import Foundation
import ProcglintCore

enum CopyText {
    static func list(rows: [ProcessSample], columns: [ProcessColumn], header: SnapshotHeader?, totalMatched: Int,
                     query: ProcessQuery, selectedRows: IndexSet? = nil) -> String
    {
        let rows = selectedRows.map { selection in rows.enumerated().filter { selection.contains($0.offset) }.map(\.element) } ?? rows
        let sort = ProcessColumn.allCases.first { $0.sort == query.sort }?.title ?? query.sort.rawValue
        let timestamp = header.map { date($0.sampledAt) } ?? "unavailable"
        let title = "procglint process list · \(timestamp) · \(rows.count) of \(totalMatched) processes · sorted by \(sort) \(query.order.rawValue)"
        let headings = tableRow(columns.map(\.title))
        let alignment = "|" + columns.map { $0.numeric ? "---:" : "---" }.joined(separator: "|") + "|"
        let body = rows.map { row in tableRow(columns.map { $0.text(for: row).text }) }
        return ([title, system(header), "", headings, alignment] + body).joined(separator: "\n")
    }

    static func details(process: ProcessSample, permissions: PermissionSet, history: HistorySeries?, window: ClosedRange<Date>) -> String {
        var sections = ["# procglint process details", "## Identity\n\n" + Display.identity(process),
                        "## Path\n\n" + fenced(Display.path(process, permissions: permissions))]
        let metrics = ProcessColumn.allCases.map { column in
            let value = column.text(for: process)
            return tableRow([column.title, value.text + (value.reason.map { " (\($0))" } ?? "")])
        }
        sections.append((["## Current metrics", "", "| Metric | Value |", "|---|---:|"] + metrics).joined(separator: "\n"))
        var lineage = ["## Launched by"]
        for ancestor in (process.ancestors ?? []).reversed() {
            lineage.append("- \(ancestor.name) (\(ancestor.pid))")
            if permissions.contains(.includeCommandLines), let command = ancestor.commandLine {
                lineage.append(fenced(command.displayText))
            }
        }
        lineage.append(Display.lineageStatus(process))
        sections.append(lineage.joined(separator: "\n\n"))
        if permissions.contains(.includeCommandLines) {
            sections.append("## Command line\n\n" + fenced(Display.commandLine(process, permissions: permissions)))
            sections.append("## Working directory\n\n" + fenced(Display.cwd(process, permissions: permissions)))
        }
        if var history, !history.points.isEmpty {
            history.points = history.points.filter { window.contains($0.t) }
            let summaries = [HistoryChartKind.cpu, .memory, .io, .power].map { kind in
                let fields = kind.fields.enumerated().map { index, field in
                    let values = ChartGeometry.segments(history, value: field).flatMap { $0.map(\.value) }
                    let minimum = values.min().map(kind.format) ?? "—"
                    let maximum = values.max().map(kind.format) ?? "—"
                    let latest = history.points.last.flatMap(field).map(kind.metricText) ?? "No history"
                    let prefix = kind == .io ? (index == 0 ? "Read: " : "Write: ") : ""
                    return "\(prefix)min \(minimum) · max \(maximum) · latest \(latest)"
                }
                return "- \(kind.label): " + fields.joined(separator: "; ")
            }
            sections.append((["## History (\(date(window.lowerBound)) – \(date(window.upperBound)))", ""] + summaries).joined(separator: "\n"))
        }
        return sections.joined(separator: "\n\n")
    }

    private static func system(_ header: SnapshotHeader?) -> String {
        var parts = ["CPU \(SummaryCard.cpu.value(header))", "Memory \(SummaryCard.memory.value(header)) \(SummaryCard.memory.caption(header))",
                     "Pressure \(SummaryCard.pressure.caption(header)) \(SummaryCard.pressure.value(header))",
                     "Swap \(SummaryCard.swap.value(header))", "Compressed \(SummaryCard.compressed.value(header))"]
        if header?.system.battery != nil {
            parts.append("Battery \(SummaryCard.battery.value(header)) \(SummaryCard.battery.caption(header))")
        }
        return "System: " + parts.joined(separator: " · ")
    }

    private static func tableRow(_ cells: [String]) -> String {
        "| " + cells.map {
            $0.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "|", with: "\\|")
                .replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\n", with: "<br>")
        }.joined(separator: " | ") + " |"
    }

    private static func fenced(_ text: String) -> String {
        var fence = "```"
        // Process-provided paths and arguments must not be able to close their own code block.
        while text.contains(fence) {
            fence += "`"
        }
        return "\(fence)\n\(text)\n\(fence)"
    }

    private static func date(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }
}
