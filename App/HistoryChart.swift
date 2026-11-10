import AppKit
import Charts
import Observation
import struct ProcglintCore.HistoryGap
import struct ProcglintCore.HistoryPoint
import struct ProcglintCore.HistorySeries
import enum ProcglintCore.MemoryPressure
import struct ProcglintCore.Metric
import SwiftUI

struct ChartPoint: Equatable {
    var time: Date
    var value: Double
    var pressure: MemoryPressure?
}

enum ChartGeometry {
    static func historyWindow(endingAt time: Date?, minutes: Int) -> ClosedRange<Date> {
        let end = time ?? Date(timeIntervalSince1970: 0)
        return end.addingTimeInterval(-Double(minutes * 60)) ... end
    }

    static func timeRange(_ series: HistorySeries) -> ClosedRange<Date>? {
        let times = series.points.map(\.t)
        guard let first = times.min(), let last = times.max() else { return nil }
        return first ... last
    }

    static func nearestPoint(in series: HistorySeries, to time: Date) -> HistoryPoint? {
        guard let range = timeRange(series), range.contains(time),
              !series.gaps.contains(where: { $0.from <= time && time < $0.to }) else { return nil }
        return series.points.filter { point in
            !series.gaps.contains { $0.from <= point.t && point.t < $0.to }
        }.min { abs($0.t.timeIntervalSince(time)) < abs($1.t.timeIntervalSince(time)) }
    }

    static func segments(_ series: HistorySeries, value: (HistoryPoint) -> Metric?) -> [[ChartPoint]] {
        var result: [[ChartPoint]] = []
        var current: [ChartPoint] = []
        for point in series.points {
            let metric = value(point)
            guard let metric, metric.status == .ok, let number = metric.value, number.isFinite,
                  !series.gaps.contains(where: { $0.from <= point.t && point.t < $0.to })
            else {
                if !current.isEmpty {
                    result.append(current); current = []
                }
                continue
            }
            if let previous = current.last,
               point.t <= previous.time || series.gaps.contains(where: { $0.from < point.t && $0.to > previous.time })
            {
                result.append(current)
                current = []
            }
            current.append(ChartPoint(time: point.t, value: number, pressure: point.memoryPressure))
        }
        if !current.isEmpty {
            result.append(current)
        }
        return result
    }

    static func pressureSegments(_ series: HistorySeries) -> [[ChartPoint]] {
        var result: [[ChartPoint]] = []
        for segment in segments(series, value: { $0.memoryPressurePercent }) {
            var current: [ChartPoint] = []
            for point in segment {
                if let previous = current.last, previous.pressure != point.pressure {
                    // Each recorded sample retains its categorical colour; transitions meet halfway.
                    var boundary = ChartPoint(time: previous.time.addingTimeInterval(point.time.timeIntervalSince(previous.time) / 2),
                                              value: (previous.value + point.value) / 2, pressure: previous.pressure)
                    current.append(boundary)
                    result.append(current)
                    boundary.pressure = point.pressure
                    current = [boundary]
                }
                current.append(point)
            }
            result.append(current)
        }
        return result
    }

    static func memorySegments(_ samples: [MemorySummaryPoint], gaps: [HistoryGap] = [], value: (MemorySummaryPoint) -> Metric) -> [[ChartPoint]] {
        var result: [[ChartPoint]] = []
        var current: [ChartPoint] = []
        for sample in samples {
            let metric = value(sample)
            let insideGap = gaps.contains { $0.from <= sample.time && sample.time < $0.to }
            let crossesGap = current.last.map { previous in gaps.contains { $0.from < sample.time && $0.to > previous.time } } ?? false
            if sample.startsSegment || metric.value == nil || insideGap || crossesGap, !current.isEmpty {
                result.append(current); current = []
            }
            if !insideGap, let number = metric.value, number.isFinite {
                current.append(ChartPoint(time: sample.time, value: number))
            }
        }
        if !current.isEmpty {
            result.append(current)
        }
        return result
    }

    static func nearestMemoryPoint(in samples: [MemorySummaryPoint], to time: Date, gaps: [HistoryGap] = []) -> MemorySummaryPoint? {
        guard let first = samples.first, let last = samples.last, (first.time ... last.time).contains(time),
              !gaps.contains(where: { $0.from <= time && time < $0.to }),
              !zip(samples, samples.dropFirst()).contains(where: { previous, next in
                  next.startsSegment && previous.time < time && time < next.time
              }) else { return nil }
        return samples.filter { sample in
            !gaps.contains { $0.from <= sample.time && sample.time < $0.to }
        }.min { abs($0.time.timeIntervalSince(time)) < abs($1.time.timeIntervalSince(time)) }
    }

    static func pressureColor(_ pressure: MemoryPressure?) -> NSColor {
        switch pressure {
        case .normal: .systemGreen
        case .warning: .systemYellow
        case .critical: .systemRed
        case nil: .secondaryLabelColor
        }
    }
}

@MainActor
@Observable
final class ChartSelection {
    private(set) var time: Date?
    private(set) var hoveredChart: HistoryChartKind?

    func move(to time: Date, from chart: HistoryChartKind) {
        self.time = time
        hoveredChart = chart
    }

    func updateSelection(_ time: Date?, from chart: HistoryChartKind) {
        // Charts with a shorter domain must not clamp or clear another chart's cursor.
        guard hoveredChart == chart, let time else { return }
        self.time = time
    }

    func clear(from chart: HistoryChartKind? = nil) {
        guard chart == nil || hoveredChart == chart else { return }
        time = nil
        hoveredChart = nil
    }
}

enum HistoryChartKind: String, CaseIterable {
    case systemCPU, systemMemory, pressure, swap, compressed, systemPower, cpu, memory, io, power

    var identifier: String {
        switch self {
        case .systemCPU: "systemCPUChart"
        case .systemMemory: "systemMemoryChart"
        case .pressure: "systemPressureChart"
        case .swap: "systemSwapChart"
        case .compressed: "systemCompressedChart"
        case .systemPower: "systemPowerChart"
        case .power: "processPowerChart"
        case .cpu: "processCPUChart"
        case .memory: "processMemoryChart"
        case .io: "processIOChart"
        }
    }

    var label: String {
        switch self {
        case .systemCPU: "System CPU history, percent"
        case .systemMemory: "System memory used history, bytes"
        case .pressure: "Memory pressure history, percent"
        case .swap: "Swap history, bytes; since this window opened"
        case .compressed: "Compressed memory history, bytes; since this window opened"
        case .cpu: "CPU history, percent (one core = 100%)"
        case .memory: "Memory (footprint) history, bytes"
        case .io: "I/O history, bytes per second"
        case .systemPower: "System power history, watts"
        case .power: "Process power history, watts (OS-attributed)"
        }
    }

    var fields: [(HistoryPoint) -> Metric?] {
        switch self {
        case .systemCPU, .cpu: [{ $0.cpuPercent }]
        case .systemMemory: [{ $0.memoryUsedBytes }]
        case .pressure: [{ $0.memoryPressurePercent }]
        case .memory: [{ $0.footprintBytes }]
        case .io: [{ $0.diskReadBps }, { $0.diskWriteBps }]
        case .systemPower: [{ $0.systemPowerMW }]
        case .power: [{ $0.powerMW }]
        case .swap, .compressed: []
        }
    }

    func format(_ value: Double) -> String {
        switch self {
        case .systemCPU, .cpu: Display.percent(value)
        case .pressure: String(format: "%.0f%%", value)
        case .io: Display.bytes(value) + "/s"
        case .systemPower, .power: Display.watts(value / 1000)
        default: Display.bytes(value)
        }
    }

    func values(at point: HistoryPoint?) -> String {
        fields.enumerated().map { index, field in
            let prefix = self == .io ? (index == 0 ? "Read: " : "Write: ") : ""
            guard let point, let metric = field(point) else { return prefix + "No history" }
            return prefix + metricText(metric)
        }.joined(separator: ", ")
    }

    func metricText(_ metric: Metric) -> String {
        let text = Display.metric(metric, format: format)
        return text.text + (text.reason.map { " (\($0))" } ?? "")
    }

    func hoverReadout(series: HistorySeries?, time: Date?, hovered: Bool) -> String? {
        guard let time, let series, let point = ChartGeometry.nearestPoint(in: series, to: time) else { return nil }
        let values = values(at: point)
        return hovered ? time.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits)) + " · " + values : values
    }
}

@MainActor
struct HistoryChart: View {
    let model: MonitorViewModel
    let kind: HistoryChartKind
    var compact = false

    var fixedMaximum: Double? {
        if kind == .systemCPU || kind == .pressure {
            return 100
        }
        return kind == .systemMemory ? model.header.map { Double($0.system.physicalMemoryBytes) } : nil
    }

    var hasTrend: Bool {
        guard kind == .swap || kind == .compressed else { return true }
        return ChartGeometry.memorySegments(model.memorySummaryHistory, gaps: model.systemHistory?.gaps ?? [],
                                            value: { kind == .swap ? $0.swap : $0.compressed }).contains { $0.count > 1 }
    }

    var body: some View {
        let system = [.systemCPU, .systemMemory, .pressure, .swap, .compressed, .systemPower].contains(kind)
        let series = system ? model.systemHistory : model.history
        let memoryPoints = kind == .swap || kind == .compressed ? model.memorySummaryHistory : []
        if hasTrend {
            HistoryPlot(kind: kind, series: series, memoryPoints: memoryPoints, maximum: fixedMaximum,
                        timeRange: ChartGeometry.historyWindow(endingAt: model.header?.sampledAt ?? series?.points.last?.t, minutes: model.policy.historyMinutes),
                        compact: compact, selection: model.chartSelection)
        } else {
            Color.clear.frame(height: compact ? 38 : 78).accessibilityHidden(true)
        }
    }
}

private struct PlotSegment: Identifiable {
    var id: Int
    var label: String
    var points: [ChartPoint]
}

@MainActor
private struct HistoryPlot: View {
    let kind: HistoryChartKind
    let series: HistorySeries?
    let memoryPoints: [MemorySummaryPoint]
    let compact: Bool
    let selection: ChartSelection
    let segments: [PlotSegment]
    let maximum: Double
    let timeRange: ClosedRange<Date>

    init(kind: HistoryChartKind, series: HistorySeries?, memoryPoints: [MemorySummaryPoint], maximum: Double?, timeRange: ClosedRange<Date>, compact: Bool, selection: ChartSelection) {
        self.kind = kind
        self.series = series
        self.memoryPoints = memoryPoints
        self.compact = compact
        self.selection = selection
        var groups: [PlotSegment] = []
        if kind == .swap || kind == .compressed {
            let lines = ChartGeometry.memorySegments(memoryPoints, gaps: series?.gaps ?? [], value: { kind == .swap ? $0.swap : $0.compressed })
            groups = lines.enumerated().map { PlotSegment(id: $0.offset, label: kind.label, points: $0.element) }
        } else if let series {
            for (index, field) in kind.fields.enumerated() {
                let lines = kind == .pressure ? ChartGeometry.pressureSegments(series) : ChartGeometry.segments(series, value: field)
                for line in lines {
                    groups.append(PlotSegment(id: groups.count, label: kind == .io ? (index == 0 ? "Read" : "Write") : kind.label, points: line))
                }
            }
        }
        segments = groups
        self.maximum = max(1, maximum ?? groups.flatMap(\.points).map(\.value).max() ?? 1)
        self.timeRange = timeRange
    }

    private var latest: String {
        if kind == .swap || kind == .compressed {
            guard let last = memoryPoints.last else { return "No history" }
            return kind.metricText(kind == .swap ? last.swap : last.compressed)
        }
        return kind.values(at: series?.points.last)
    }

    private var readout: String? {
        let hovered = selection.hoveredChart == kind
        if kind == .swap || kind == .compressed {
            guard let time = selection.time, let point = ChartGeometry.nearestMemoryPoint(in: memoryPoints, to: time, gaps: series?.gaps ?? []) else { return nil }
            let value = kind.metricText(kind == .swap ? point.swap : point.compressed)
            return hovered ? time.formatted(date: .omitted, time: .standard) + " · " + value : value
        }
        return kind.hoverReadout(series: series, time: selection.time, hovered: hovered)
    }

    private var selectionBinding: Binding<Date?> {
        Binding(get: { selection.time }, set: { selection.updateSelection($0, from: kind) })
    }

    @ChartContentBuilder
    private func marks(for point: ChartPoint, in segment: PlotSegment) -> some ChartContent {
        if kind == .pressure {
            let color = Color(nsColor: ChartGeometry.pressureColor(point.pressure))
            AreaMark(x: .value("Time", point.time), y: .value("Pressure", point.value), series: .value("Segment", segment.id), stacking: .unstacked)
                .foregroundStyle(color.opacity(0.18))
            LineMark(x: .value("Time", point.time), y: .value("Pressure", point.value), series: .value("Segment", segment.id))
                .foregroundStyle(color)
                .lineStyle(StrokeStyle(lineWidth: 1.5))
        } else {
            if !compact, kind != .io {
                AreaMark(x: .value("Time", point.time), y: .value("Value", point.value), series: .value("Segment", segment.id), stacking: .unstacked)
                    .foregroundStyle(.blue.opacity(0.1))
            }
            LineMark(x: .value("Time", point.time), y: .value("Value", point.value), series: .value("Segment", segment.id))
                .foregroundStyle(by: .value("Series", segment.label))
                .lineStyle(StrokeStyle(lineWidth: 1.5))
        }
        if !compact, segment.points.count == 1 {
            let color: Color = switch kind {
            case .pressure: Color(nsColor: ChartGeometry.pressureColor(point.pressure))
            case .io: segment.label == "Write" ? .orange : .blue
            default: .blue
            }
            PointMark(x: .value("Time", point.time), y: .value("Value", point.value))
                .foregroundStyle(color)
                .symbolSize(10)
        }
    }

    var body: some View {
        Chart {
            ForEach(segments) { segment in
                ForEach(Array(segment.points.enumerated()), id: \.offset) { _, point in
                    marks(for: point, in: segment)
                }
            }
            if let time = selection.time, timeRange.contains(time) {
                RuleMark(x: .value("Selected time", time))
                    .foregroundStyle(Color.secondary)
                    .annotation(position: .overlay, alignment: .topLeading, spacing: 0,
                                overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart)))
                    {
                        if let readout {
                            Text(readout)
                                .font(.system(size: 10).monospacedDigit())
                                .foregroundStyle(Color.primary)
                                .fixedSize()
                                .padding(3)
                                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 4))
                        }
                    }
            }
        }
        .chartXScale(domain: timeRange, range: .plotDimension(padding: 0))
        .chartYScale(domain: 0 ... maximum, range: .plotDimension(padding: 2))
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartForegroundStyleScale(domain: kind == .io ? ["Read", "Write"] : [kind.label], range: [.blue, .orange])
        .chartLegend(kind == .io ? .visible : .hidden)
        .chartXSelection(value: selectionBinding)
        .chartOverlay { proxy in
            GeometryReader { geometry in
                ChartHoverArea { location in
                    guard let location, let frame = proxy.plotFrame else { selection.clear(from: kind); return }
                    let x = location.x - geometry[frame].minX
                    if let time: Date = proxy.value(atX: x), timeRange.contains(time) {
                        selection.move(to: time, from: kind)
                    } else {
                        selection.clear(from: kind)
                    }
                }
                .accessibilityHidden(true)
            }
        }
        .frame(height: compact ? 38 : 78)
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isImage)
        .accessibilityIdentifier(kind.identifier)
        .accessibilityLabel(kind.label + (readout.map { "; Cursor: " + $0 } ?? ""))
        .accessibilityValue(latest)
        .onDisappear { selection.clear(from: kind) }
    }
}
