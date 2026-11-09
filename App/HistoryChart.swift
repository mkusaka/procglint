import AppKit
import ProcglintCore

struct ChartPoint: Equatable {
    var time: Date
    var value: Double
    var pressure: MemoryPressure?
}

enum ChartGeometry {
    static func fraction(_ value: Double, in range: ClosedRange<Double>) -> Double {
        let clamped = min(range.upperBound, max(range.lowerBound, value))
        return (clamped - range.lowerBound) / (range.upperBound - range.lowerBound)
    }

    static func x(for time: Date, in range: ClosedRange<Date>, plot: CGRect) -> Double {
        let duration = range.upperBound.timeIntervalSince(range.lowerBound)
        return plot.minX + time.timeIntervalSince(range.lowerBound) / (duration > 0 ? duration : 1) * plot.width
    }

    static func time(atX x: Double, in range: ClosedRange<Date>, plot: CGRect) -> Date {
        let fraction = plot.width > 0 ? min(1, max(0, (x - plot.minX) / plot.width)) : 0
        return range.lowerBound.addingTimeInterval(fraction * range.upperBound.timeIntervalSince(range.lowerBound))
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
                    // Split halfway between samples so each sample retains its recorded categorical colour.
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
final class ChartCursor {
    private let charts = NSHashTable<HistoryChartView>.weakObjects()
    private(set) var time: Date?
    private(set) weak var hoveredChart: HistoryChartView?

    func add(_ chart: HistoryChartView) {
        charts.add(chart)
    }

    func remove(_ chart: HistoryChartView) {
        clear(from: chart)
        charts.remove(chart)
    }

    func move(to time: Date, from chart: HistoryChartView) {
        self.time = time
        hoveredChart = chart
        charts.allObjects.forEach { $0.cursorChanged() }
    }

    func clear(from chart: HistoryChartView) {
        guard hoveredChart === chart else { return }
        time = nil
        hoveredChart = nil
        charts.allObjects.forEach { $0.cursorChanged() }
    }
}

@MainActor
final class HistoryChartView: NSView {
    private var series: HistorySeries?
    private(set) var fixedYRange: ClosedRange<Double>?
    private let fields: [(HistoryPoint) -> Metric?]
    private let label: String
    private let format: (Double) -> String
    private let compact: Bool
    private let pressureArea: Bool
    private let fieldLabels: [String]
    private let colors: [NSColor] = [.systemBlue, .systemOrange]
    private var tracking: NSTrackingArea?
    weak var cursor: ChartCursor? {
        didSet {
            oldValue?.remove(self)
            cursor?.add(self)
            cursorChanged()
        }
    }

    init(label: String, fields: [(HistoryPoint) -> Metric?], compact: Bool = false, pressureArea: Bool = false,
         fieldLabels: [String] = [], format: @escaping (Double) -> String = { String(format: "%.1f", $0) })
    {
        self.fields = fields
        self.label = label
        self.format = format
        self.compact = compact
        self.pressureArea = pressureArea
        self.fieldLabels = fieldLabels
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityLabel(label + ": No history")
        setAccessibilityRole(.image)
        heightAnchor.constraint(equalToConstant: compact ? 36 : 80).isActive = true
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Programmatic UI only")
    }

    private var plot: CGRect {
        bounds.insetBy(dx: compact ? 2 : 4, dy: compact ? 2 : 4)
    }

    private var timeRange: ClosedRange<Date>? {
        series.flatMap(ChartGeometry.timeRange)
    }

    private func values(at point: HistoryPoint?) -> [String] {
        fields.map { field in
            guard let point, let metric = field(point) else { return "No history" }
            let value = Display.metric(metric, format: format)
            return value.reason.map { "\(value.text) (\($0))" } ?? value.text
        }
    }

    var hoverReadout: String? {
        guard let time = cursor?.time, let series,
              let point = ChartGeometry.nearestPoint(in: series, to: time) else { return nil }
        let values = values(at: point).enumerated().map { index, value in
            fieldLabels.indices.contains(index) ? "\(fieldLabels[index]): \(value)" : value
        }.joined(separator: ", ")
        guard cursor?.hoveredChart === self else { return values }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss"
        return "\(formatter.string(from: time)) · \(values)"
    }

    func cursorChanged() {
        // Keep AXValue as the latest sample; AXTitle exposes the transient, synchronised read-out.
        setAccessibilityTitle(hoverReadout.map { "Cursor: " + $0 })
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking {
            removeTrackingArea(tracking)
        }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        mouseMoved(with: event)
    }

    override func mouseMoved(with event: NSEvent) {
        guard let timeRange else { cursor?.clear(from: self); return }
        let x = convert(event.locationInWindow, from: nil).x
        cursor?.move(to: ChartGeometry.time(atX: x, in: timeRange, plot: plot), from: self)
    }

    override func mouseExited(with _: NSEvent) {
        cursor?.clear(from: self)
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            cursor?.clear(from: self)
        }
        super.viewWillMove(toWindow: newWindow)
    }

    func update(_ series: HistorySeries?, fixedYRange: ClosedRange<Double>? = nil) {
        if let range = fixedYRange {
            precondition(range.lowerBound.isFinite && range.upperBound.isFinite && range.upperBound > range.lowerBound)
        }
        guard self.series != series || self.fixedYRange != fixedYRange else { return }
        self.series = series
        self.fixedYRange = fixedYRange
        let latest = values(at: series?.points.last).joined(separator: ", ")
        setAccessibilityValue(latest)
        setAccessibilityLabel(label + ": " + latest)
        cursorChanged()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.controlBackgroundColor.setFill()
        bounds.fill()
        guard let series, let timeRange else { return }
        let lines = pressureArea ? [ChartGeometry.pressureSegments(series)] : fields.map { ChartGeometry.segments(series, value: $0) }
        let maximum = max(1, lines.flatMap(\.self).flatMap(\.self).map(\.value).max() ?? 1)
        let range = fixedYRange ?? 0 ... maximum
        for (index, segments) in lines.enumerated() {
            for segment in segments {
                let color = pressureArea ? ChartGeometry.pressureColor(segment.first?.pressure) : colors[index % colors.count]
                color.setStroke()
                color.setFill()
                let positions = segment.map { point in
                    NSPoint(x: ChartGeometry.x(for: point.time, in: timeRange, plot: plot),
                            y: plot.minY + ChartGeometry.fraction(point.value, in: range) * plot.height)
                }
                guard let first = positions.first, let last = positions.last else { continue }
                let path = NSBezierPath()
                path.move(to: first)
                for position in positions.dropFirst() {
                    path.line(to: position)
                }
                if pressureArea {
                    let area = NSBezierPath()
                    area.move(to: NSPoint(x: first.x, y: plot.minY))
                    for position in positions {
                        area.line(to: position)
                    }
                    area.line(to: NSPoint(x: last.x, y: plot.minY))
                    area.close()
                    area.fill()
                }
                if positions.count == 1 {
                    NSBezierPath(ovalIn: NSRect(x: first.x - 2, y: first.y - 2, width: 4, height: 4)).fill()
                }
                path.lineWidth = 1.5
                path.stroke()
            }
        }
        if let time = cursor?.time, timeRange.contains(time) {
            let x = ChartGeometry.x(for: time, in: timeRange, plot: plot)
            NSColor.labelColor.setStroke()
            let line = NSBezierPath()
            line.move(to: NSPoint(x: x, y: plot.minY))
            line.line(to: NSPoint(x: x, y: plot.maxY))
            line.lineWidth = 1
            line.stroke()
            if let hoverReadout {
                let text = NSAttributedString(string: hoverReadout, attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium),
                    .foregroundColor: NSColor.labelColor, .backgroundColor: NSColor.controlBackgroundColor,
                ])
                text.draw(in: NSRect(x: plot.minX + 2, y: plot.maxY - 28, width: plot.width - 4, height: 28))
            }
        }
    }
}
