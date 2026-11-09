import ProcglintCore
import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: SettingsViewModel
    let setMenuBar: (Bool) -> Void
    let setAdaptiveRefresh: (Bool) -> Void
    let unregister: () -> Void
    let openLoginItems: () -> Void
    let copyConfiguration: () -> Void
    @State private var interval: SamplingInterval
    @State private var historyMinutes: Int

    init(model: SettingsViewModel, setMenuBar: @escaping (Bool) -> Void, setAdaptiveRefresh: @escaping (Bool) -> Void,
         unregister: @escaping () -> Void, openLoginItems: @escaping () -> Void, copyConfiguration: @escaping () -> Void)
    {
        self.model = model
        self.setMenuBar = setMenuBar
        self.setAdaptiveRefresh = setAdaptiveRefresh
        self.unregister = unregister
        self.openLoginItems = openLoginItems
        self.copyConfiguration = copyConfiguration
        _interval = State(initialValue: model.policy.guiIntervalMS)
        _historyMinutes = State(initialValue: model.policy.historyMinutes)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                general
                agent
                privacy
                sampling
                controlPermissions
                diagnostics
            }
            .formStyle(.grouped)
            .toggleStyle(.checkbox)
            Divider()
            HStack(spacing: 12) {
                Button("Copy MCP config", action: copyConfiguration)
                    .accessibilityIdentifier("copyMCPConfig")
                Text(model.message)
                    .font(.caption)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("settingsFeedback")
                Spacer(minLength: 0)
            }
            .padding(14)
            .background(.bar)
        }
        .onChange(of: model.policy) { _, policy in
            interval = policy.guiIntervalMS
            historyMinutes = policy.historyMinutes
        }
    }

    private var general: some View {
        Section("General") {
            Toggle("Open procglint at login", isOn: Binding(get: { model.opensAtLogin }, set: { enabled in
                Task { await model.setOpensAtLogin(enabled) }
            }))
            .disabled(model.changingLoginItem)
            .accessibilityIdentifier("launchAtLoginToggle")
            if !model.loginItemHint.isEmpty {
                Text(model.loginItemHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("launchAtLoginHint")
                Button("Open Login Items…", action: openLoginItems)
                    .accessibilityIdentifier("launchAtLoginApproval")
            }
            Toggle("Show CPU and memory in the menu bar", isOn: Binding(get: { model.preferences.menuBar }, set: { setMenuBar($0) }))
                .accessibilityIdentifier("menuBarToggle")
            Toggle("Slow refresh when the main window is not focused", isOn: Binding(get: { model.preferences.adaptiveRefresh }, set: { setAdaptiveRefresh($0) }))
                .help("Uses the next slower update interval, up to 10 seconds, while the main window is unfocused. Hidden windows stop their lease.")
                .accessibilityIdentifier("adaptiveRefreshToggle")
        }
    }

    private var agent: some View {
        Section("Agent") {
            LabeledContent("Background agent", value: model.agentSetup.title)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Background agent: " + model.agentSetup.title)
                .accessibilityIdentifier("agentRegistrationStatus")
            Text(model.agentSetup.explanation)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("agentRegistrationDetail")
            HStack {
                Button("Register agent…") { Task { await model.register() } }
                    .disabled(!model.agentSetup.canRegister || model.changingRegistration)
                    .accessibilityIdentifier("settingsRegisterAgent")
                Button("Unregister agent", action: unregister)
                    .disabled(!model.agentSetup.canUnregister || model.changingRegistration)
                    .accessibilityIdentifier("settingsUnregisterAgent")
                Button("Open Login Items…", action: openLoginItems)
                    .accessibilityIdentifier("settingsLoginItems")
            }
        }
    }

    private var privacy: some View {
        Section("Privacy") {
            permission(.includeSystem, title: "Include system processes")
            permission(.includePaths, title: "Include executable paths")
            permission(.includeCommandLines, title: "Show command lines and working directory")
            Text("Arguments can contain secrets; redaction is best-effort.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("commandLineWarning")
        }
    }

    private var sampling: some View {
        Section("History and sampling") {
            Picker("Update interval", selection: $interval) {
                ForEach(SamplingInterval.allCases, id: \.self) { value in
                    Text("\(value.rawValue / 1000) s").tag(value)
                }
            }
            .accessibilityLabel("GUI update interval")
            .accessibilityIdentifier("guiInterval")
            Picker("History retention", selection: $historyMinutes) {
                ForEach(1 ... 10, id: \.self) { minutes in Text("\(minutes) min").tag(minutes) }
            }
            .accessibilityIdentifier("historyRetention")
            Button("Apply sampling policy") { Task { await model.savePolicy(interval: interval, historyMinutes: historyMinutes) } }
                .accessibilityIdentifier("applySamplingPolicy")
        }
    }

    private var controlPermissions: some View {
        Section("MCP and process control") {
            permission(.observe, title: "Allow timed observations")
            permission(.configure, title: "Allow sampling configuration")
            permission(.terminate, title: "Allow Quit (SIGTERM)")
            permission(.forceKill, title: "Allow Force Quit (SIGKILL)")
            Text("Permissions cap GUI and MCP access. MCP launch flags further restrict access. The MCP host may send process results to external models. Never enable permissions you do not want to share.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var diagnostics: some View {
        Section {
            DisclosureGroup("Diagnostics") {
                Button("Refresh diagnostics") { Task { await model.refresh() } }
                    .accessibilityIdentifier("refreshDiagnostics")
                Text(model.diagnostics)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel("Agent and clients diagnostics")
                    .accessibilityIdentifier("agentDiagnostics")
            }
        }
    }

    private func permission(_ permission: Permission, title: String) -> some View {
        Toggle(title, isOn: Binding(get: { model.permissions.contains(permission) }, set: { model.setPermission(permission, allowed: $0) }))
            .accessibilityIdentifier(permission.rawValue)
    }
}
