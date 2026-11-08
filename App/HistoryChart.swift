import AppKit
import ProcglintCore

struct ChartPoint: Equatable {
    var time: Date
    var value: Double
}

enum ChartGeometry {
    static func fraction(_ value: Double, in range: ClosedRange<Double>) -> Double {
        let clamped = min(range.upperBound, max(range.lowerBound, value))
        return (clamped - range.lowerBound) / (range.upperBound - range.lowerBound)
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
            current.append(ChartPoint(time: point.t, value: number))
        }
        if !current.isEmpty {
            result.append(current)
        }
        return result
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
    private let colors: [NSColor] = [.systemBlue, .systemOrange]

    init(label: String, fields: [(HistoryPoint) -> Metric?], compact: Bool = false,
         format: @escaping (Double) -> String = { String(format: "%.1f", $0) })
    {
        self.fields = fields
        self.label = label
        self.format = format
        self.compact = compact
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityLabel(label + ": No history")
        setAccessibilityRole(.image)
        heightAnchor.constraint(equalToConstant: compact ? 32 : 80).isActive = true
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Programmatic UI only")
    }

    func update(_ series: HistorySeries?, fixedYRange: ClosedRange<Double>? = nil) {
        if let range = fixedYRange {
            precondition(range.lowerBound.isFinite && range.upperBound.isFinite && range.upperBound > range.lowerBound)
        }
        guard self.series != series || self.fixedYRange != fixedYRange else { return }
        self.series = series
        self.fixedYRange = fixedYRange
        let last = series?.points.last
        let values = fields.map { field in
            guard let last, let metric = field(last) else { return "No history" }
            let value = Display.metric(metric, format: format)
            return value.reason.map { "\(value.text) (\($0))" } ?? value.text
        }
        let latest = values.joined(separator: ", ")
        setAccessibilityValue(latest)
        setAccessibilityLabel(label + ": " + latest)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.controlBackgroundColor.setFill()
        bounds.fill()
        guard let series, let first = series.points.first?.t, let last = series.points.last?.t else { return }
        let lines = fields.map { field in ChartGeometry.segments(series, value: field) }
        let maximum = max(1, lines.flatMap(\.self).flatMap(\.self).map(\.value).max() ?? 1)
        let range = fixedYRange ?? 0 ... maximum
        let duration = max(1, last.timeIntervalSince(first))
        let plot = bounds.insetBy(dx: compact ? 2 : 4, dy: compact ? 2 : 4)
        for (index, segments) in lines.enumerated() {
            colors[index % colors.count].setStroke()
            colors[index % colors.count].setFill()
            for segment in segments {
                let path = NSBezierPath()
                for (offset, point) in segment.enumerated() {
                    let position = NSPoint(x: plot.minX + point.time.timeIntervalSince(first) / duration * plot.width,
                                           y: plot.minY + ChartGeometry.fraction(point.value, in: range) * plot.height)
                    if offset == 0 {
                        path.move(to: position)
                    } else {
                        path.line(to: position)
                    }
                    if segment.count == 1 {
                        NSBezierPath(ovalIn: NSRect(x: position.x - 2, y: position.y - 2, width: 4, height: 4)).fill()
                    }
                }
                path.lineWidth = 1.5
                path.stroke()
            }
        }
    }
}
