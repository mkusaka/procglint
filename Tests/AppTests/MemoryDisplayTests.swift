import AppKit
@testable import ProcglintApp
import ProcglintCore
import Testing

@MainActor
struct MemoryDisplayTests {
    @Test(arguments: MemoryPressure.allCases)
    func headerShowsPressureAndUsefulMemory(pressure: MemoryPressure) {
        var header = snapshot().header
        header.system.memoryPressure = .ok(pressure)
        header.system.memoryUsedBytes = 54200 * 1_073_741_824 / 1000
        header.system.physicalMemoryBytes = 64 * 1_073_741_824
        header.system.compressedBytes = 23200 * 1_073_741_824 / 1000
        header.system.swapUsedBytes = .ok(10.4 * 1_073_741_824)
        header.system.swapTotalBytes = .ok(12 * 1_073_741_824)
        let text = Display.summary(header)
        #expect(text.hasPrefix("Memory pressure: \(pressure.rawValue.capitalized)\n"))
        #expect(text.contains("Used 54.2 GB of 64 GB · Swap 10.4 GB · Compressed 23.2 GB"))
        #expect(!text.contains("wired"))
        #expect(Display.summaryTooltip(header).contains("Swap total: 12 GB"))
    }

    @Test func unavailableIsNotNormalOrZero() {
        var header = snapshot().header
        header.system.memoryPressure = .unsupported
        header.system.swapUsedBytes = .permissionDenied
        #expect(Display.summary(header).contains("Memory pressure: Unavailable"))
        #expect(Display.summary(header).contains("Swap — (permission_denied)"))
        #expect(!Display.summary(nil).contains("Normal"))
        #expect(!Display.summary(nil).contains("0 B"))
        header.system.memoryPressure = .ok(.normal)
        header.system.swapUsedBytes = .ok(0)
        #expect(Display.summary(header).contains("Swap 0 B"))
        header.status = .unavailable
        #expect(!Display.summary(header).contains("Normal"))
        #expect(Display.memoryBytes(.nan) == "—")
        #expect(Display.memoryBytes(-1) == "—")
    }

    @Test(arguments: MemoryPressure.allCases)
    func headerBadgeAndColumnKeepAccessibleText(pressure: MemoryPressure) throws {
        let prefs = preferences()
        defer { prefs.defaults.removePersistentDomain(forName: prefs.store.suiteName ?? "") }
        let service = try FakeMonitorService()
        service.current.system.memoryPressure = .ok(pressure)
        let model = try MonitorViewModel(service: service, preferences: prefs)
        model.apply(ProcessPage(snapshot: service.current.header, items: [], totalMatched: 0))
        let controller = MainWindowController(model: model)
        controller.render()
        #expect(controller.summary.stringValue.hasPrefix("Memory pressure: \(pressure.rawValue.capitalized)"))
        let color: NSColor = switch pressure {
        case .normal: .systemGreen
        case .warning: .systemYellow
        case .critical: .systemRed
        }
        #expect(controller.summary.attributedStringValue.attribute(.backgroundColor, at: 0, effectiveRange: nil) as? NSColor == color.withAlphaComponent(0.2))
        #expect(controller.summary.toolTip?.contains("Wired:") == true)
        let column = try #require(controller.table.tableColumns.first { $0.identifier.rawValue == "footprint" })
        #expect(column.title == "Memory")
        #expect(column.headerToolTip == ProcessColumn.footprint.tooltip)
        #expect(column.headerCell.accessibilityHelp()?.contains("including compressed and swapped pages") == true)
        #expect(!column.isHidden)
        #expect(controller.table.sortDescriptors.first?.key == "cpu")
        #expect(controller.memoryChart.accessibilityLabel()?.contains("Memory (footprint)") == true)
    }
}
