import Foundation
import ProcglintCore

extension Display {
    static func power(_ milliwatts: Double) -> String {
        guard milliwatts.isFinite, milliwatts >= 0 else { return "—" }
        return milliwatts < 1000
            ? String(format: "%.0f mW", locale: Locale(identifier: "en_US_POSIX"), milliwatts)
            : String(format: "%.2f W", locale: Locale(identifier: "en_US_POSIX"), milliwatts / 1000)
    }

    static func watts(_ value: Double) -> String {
        guard value.isFinite, value >= 0 else { return "—" }
        return String(format: "%.1f W", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    static func batteryTime(_ minutes: Double) -> String {
        guard minutes.isFinite, (0 ..< 65535).contains(minutes) else { return "—" }
        let minutes = Int(minutes)
        return String(format: "%d:%02d", minutes / 60, minutes % 60)
    }
}

struct BatteryDisplay {
    let battery: BatteryMetrics

    var symbol: String {
        guard let percent = battery.percent.value, percent.isFinite else { return "battery.0" }
        let level = switch percent {
        case 87.5...: 100
        case 62.5 ..< 87.5: 75
        case 37.5 ..< 62.5: 50
        case 12.5 ..< 37.5: 25
        default: 0
        }
        return "battery.\(level)"
    }

    var caption: String {
        if battery.isCharging == true {
            return timedCaption("Charging", suffix: "to full")
        }
        if battery.externalPower == true {
            if battery.isCharging == false, let percent = battery.percent.value, percent >= 100 {
                return "Fully charged"
            }
            return "On power adapter"
        }
        if battery.externalPower == false {
            return timedCaption("On battery", suffix: "left")
        }
        return "Battery state unavailable"
    }

    private func timedCaption(_ state: String, suffix: String) -> String {
        let time = Display.metric(battery.timeRemainingMinutes, format: Display.batteryTime)
        return time.reason == nil && time.text != "—" ? "\(state) · \(time.text) \(suffix)" : state
    }

    var power: String {
        let system = Display.metric(battery.systemPowerMW) { Display.watts($0 / 1000) }
        var text = "Using \(system.text)" + (system.reason.map { " (\($0))" } ?? "")
        if battery.isCharging != true, let drain = battery.batteryPowerMW.value, drain < 0 {
            text += "\nDraining \(Display.watts(-drain / 1000))"
        }
        return text
    }

    var tooltip: String {
        let health = Display.metric(battery.healthPercent) { String(format: "%.0f%%", $0) }
        let cycles = Display.metric(battery.cycleCount) { String(format: "%.0f", $0) }
        let time = Display.metric(battery.timeRemainingMinutes, format: Display.batteryTime)
        return "Health \(health.text)\(health.reason.map { " (\($0))" } ?? "") · \(cycles.text) cycles\(cycles.reason.map { " (\($0))" } ?? "")\nTime remaining: \(time.text)\(time.reason.map { " (\($0))" } ?? "")"
    }
}
