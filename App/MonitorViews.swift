import ProcglintCore
import SwiftUI

struct MonitorHeader: View {
    let model: MonitorViewModel

    var body: some View {
        HStack(spacing: 10) {
            ForEach(SummaryCard.visible(in: model.header)) { card in
                MetricCard(model: model, card: card)
            }
        }
        .padding(14)
        .background(.bar)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("systemSummary")
    }
}

private struct MetricCard: View {
    let model: MonitorViewModel
    let card: SummaryCard

    private var battery: BatteryDisplay? {
        guard card == .battery, model.header?.status != .unavailable else { return nil }
        return model.header?.system.battery.map { BatteryDisplay(battery: $0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label {
                Text(card.title)
            } icon: {
                HStack(spacing: 2) {
                    Image(systemName: card.symbol(model.header))
                    if battery?.battery.isCharging == true {
                        Image(systemName: "bolt.fill")
                    }
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            Text(card.value(model.header))
                .accessibilityIdentifier("summaryValue.\(card.rawValue)")
                .font(.system(size: 23, weight: .semibold, design: .rounded).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if card == .pressure {
                let level = model.header?.status == .unavailable ? nil : model.header?.system.memoryPressure.value
                Text(card.caption(model.header))
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Color(nsColor: ChartGeometry.pressureColor(level)).opacity(0.18), in: Capsule())
            } else {
                Text(card.caption(model.header))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(height: 18)
            }
            if let battery {
                Text(battery.power)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                    .accessibilityIdentifier("batteryPower")
            }
            Spacer(minLength: 0)
            HistoryChart(model: model, kind: card.chart, compact: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary, lineWidth: 0.5))
        .help([battery?.tooltip ?? Display.summaryTooltip(model.header), model.message].filter { !$0.isEmpty }.joined(separator: "\n"))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("summaryCard.\(card.rawValue)")
    }
}

struct ProcessInspector: View {
    let model: MonitorViewModel
    let terminate: (TerminationSignal) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    InspectorIdentity(model: model)
                    if model.selectedKey != nil {
                        InspectorLaunchDetails(model: model)
                        InspectorHistory(model: model)
                    }
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if model.selectedKey != nil {
                InspectorActions(model: model, terminate: terminate)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 12)
            }
        }
        .background(.background)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Process inspector")
        .accessibilityIdentifier("processInspector")
    }
}

private struct InspectorIdentity: View {
    let model: MonitorViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Identity", systemImage: "app.badge")
                .font(.headline)
            Text(model.identityText)
                .textSelection(.enabled)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("processIdentity")
        }
    }
}

private struct InspectorLaunchDetails: View {
    let model: MonitorViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            Text("Path").font(.headline)
            Text(model.pathText)
                .textSelection(.enabled)
                .font(.callout)
                .accessibilityIdentifier("processPath")
            Divider()
            Text("Launched by")
                .font(.headline)
                .accessibilityIdentifier("launchedBy")
            ForEach(Array(model.rootAncestors.enumerated()), id: \.offset) { index, ancestor in
                VStack(alignment: .leading, spacing: 4) {
                    Button(ancestor.name + " (" + String(ancestor.pid) + ")") {
                        Task { await model.selectAncestor(ancestor) }
                    }
                    .buttonStyle(.link)
                    .disabled(!model.canSelectAncestor(ancestor))
                    .accessibilityIdentifier("ancestor.\(ancestor.pid)")
                    if model.permissions.contains(.includeCommandLines), let command = ancestor.commandLine {
                        Text(command.displayText)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .accessibilityIdentifier("ancestorCommand.\(ancestor.pid)")
                    }
                }
                .padding(.leading, CGFloat(min(index, 8) * 10))
            }
            Text(model.lineageStatusText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("lineageStatus")
            Text("Command line").font(.headline)
            Text(model.commandLineText)
                .font(.callout.monospaced())
                .textSelection(.enabled)
                .accessibilityIdentifier("processCommandLine")
            if !model.cwdText.isEmpty {
                Text(model.cwdText)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .accessibilityIdentifier("processCwd")
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct InspectorHistory: View {
    let model: MonitorViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            Toggle("Pin process history", isOn: Binding(get: { model.pinned }, set: { _ in
                Task { await model.togglePin() }
            }))
            .disabled(model.detail == nil)
            .accessibilityIdentifier("pinProcess")
            Text("History starts when a process is pinned or selected")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("CPU · 1 core = 100%").font(.headline)
            HistoryChart(model: model, kind: .cpu)
            Text("Memory (footprint)").font(.headline)
            HistoryChart(model: model, kind: .memory)
            Text("Attributed disk I/O per second").font(.headline)
            HistoryChart(model: model, kind: .io)
            Text("Power · OS-attributed").font(.headline)
            HistoryChart(model: model, kind: .power)
                .help(ProcessColumn.power.tooltip ?? "")
        }
    }
}

private struct InspectorActions: View {
    let model: MonitorViewModel
    let terminate: (TerminationSignal) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            HStack {
                Button("Quit (SIGTERM)") { terminate(.term) }
                    .disabled(!model.canQuit)
                    .accessibilityIdentifier("quitProcess")
                Button("Force Quit (SIGKILL)", role: .destructive) { terminate(.kill) }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .disabled(!model.canForceQuit)
                    .accessibilityIdentifier("forceQuitProcess")
            }
            Text(model.inspectorMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .accessibilityIdentifier("terminationFeedback")
        }
    }
}
