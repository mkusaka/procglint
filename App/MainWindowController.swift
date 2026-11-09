import AppKit
import ProcglintCore

@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate, NSSearchFieldDelegate {
    let model: MonitorViewModel
    let table = NSTableView()
    let dataSource: ProcessTableDataSource
    let summary = NSTextField(wrappingLabelWithString: "unavailable")
    let search = NSSearchField()
    let filter = NSSegmentedControl(labels: ["All", "Mine", "Pinned"], trackingMode: .selectOne, target: nil, action: nil)
    let identity = NSTextField(wrappingLabelWithString: "Select a process")
    let path = NSTextField(wrappingLabelWithString: "")
    let feedback = NSTextField(wrappingLabelWithString: "")
    let systemCPUChart = HistoryChartView(label: "System CPU history, percent", fields: [{ $0.cpuPercent }], compact: true, format: Display.percent)
    let systemMemoryChart = HistoryChartView(label: "System memory used history, bytes", fields: [{ $0.memoryUsedBytes }], compact: true, format: Display.bytes)
    let systemPressureChart = HistoryChartView(label: "Memory pressure history, percent", fields: [{ $0.memoryPressurePercent }], compact: true, pressureArea: true, format: { String(format: "%.0f%%", $0) })
    let chartCursor = ChartCursor()
    let cpuChart = HistoryChartView(label: "CPU history, percent (one core = 100%)", fields: [{ $0.cpuPercent }], format: Display.percent)
    let memoryChart = HistoryChartView(label: "Memory (footprint) history, bytes", fields: [{ $0.footprintBytes }], format: Display.bytes)
    let ioChart = HistoryChartView(label: "I/O history, bytes per second; blue read, orange write", fields: [{ $0.diskReadBps }, { $0.diskWriteBps }], fieldLabels: ["Read", "Write"], format: { Display.bytes($0) + "/s" })
    let pin = NSButton(checkboxWithTitle: "Pin process history", target: nil, action: nil)
    let quitProcess = NSButton(title: "Quit (SIGTERM)", target: nil, action: nil)
    let killProcess = NSButton(title: "Force Quit (SIGKILL)", target: nil, action: nil)
    let loadMore = NSButton(title: "Load more", target: nil, action: nil)
    let count = NSTextField(labelWithString: "")
    let agentBanner = NSBox()
    let agentBannerDetail = NSTextField(wrappingLabelWithString: "")
    let registerAgent = NSButton(title: "Register agent…", target: nil, action: nil)
    let loginItems = NSButton(title: "Open Login Items…", target: nil, action: nil)
    private let register: @MainActor () -> Void
    private let openLoginItems: @MainActor () -> Void
    var visibilityChanged: (@MainActor () -> Void)?
    var focusChanged: (@MainActor () -> Void)?
    private var renderedRows: [ProcessSample] = []

    init(model: MonitorViewModel, register: @escaping @MainActor () -> Void = {},
         openLoginItems: @escaping @MainActor () -> Void = {})
    {
        self.model = model
        self.register = register
        self.openLoginItems = openLoginItems
        dataSource = ProcessTableDataSource(model: model)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "procglint"
        window.setAccessibilityIdentifier("mainWindow")
        window.minSize = NSSize(width: 1000, height: 650)
        window.isReleasedWhenClosed = false
        window.acceptsMouseMovedEvents = true
        super.init(window: window)
        window.delegate = self
        window.center()
        buildUI(window)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Programmatic UI only")
    }

    var monitoringVisible: Bool {
        window?.isVisible == true && window?.occlusionState.contains(.visible) == true && window?.isMiniaturized == false
    }

    private func buildUI(_ window: NSWindow) {
        systemCPUChart.setAccessibilityIdentifier("systemCPUChart")
        systemMemoryChart.setAccessibilityIdentifier("systemMemoryChart")
        systemPressureChart.setAccessibilityIdentifier("systemPressureChart")
        for chart in [systemCPUChart, systemMemoryChart, systemPressureChart, cpuChart, memoryChart, ioChart] {
            chart.cursor = chartCursor
        }
        cpuChart.setAccessibilityIdentifier("processCPUChart")
        memoryChart.setAccessibilityIdentifier("processMemoryChart")
        ioChart.setAccessibilityIdentifier("processIOChart")
        summary.setAccessibilityIdentifier("systemSummary")
        identity.setAccessibilityIdentifier("processIdentity")
        feedback.setAccessibilityIdentifier("terminationFeedback")
        quitProcess.setAccessibilityIdentifier("quitProcess")
        killProcess.setAccessibilityIdentifier("forceQuitProcess")
        count.setAccessibilityIdentifier("processCount")
        search.setAccessibilityIdentifier("processSearch")
        filter.setAccessibilityIdentifier("processFilter")
        table.setAccessibilityIdentifier("processTable")
        search.placeholderString = "Search name or exact PID"
        search.setAccessibilityLabel("Search processes by name or PID")
        search.delegate = self
        filter.selectedSegment = 0
        filter.target = self
        filter.action = #selector(filterChanged)
        filter.setAccessibilityLabel("Process filter")
        let controls = NSStackView(views: [search, filter])
        search.widthAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.documentView = table
        table.dataSource = dataSource
        table.delegate = dataSource
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = false
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.setAccessibilityLabel("Processes")
        let columnMenu = NSMenu(title: "Columns")
        for column in ProcessColumn.allCases {
            let item = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.rawValue))
            item.title = column.title
            item.headerCell.setAccessibilityIdentifier("column.\(column.rawValue)")
            item.headerToolTip = column.tooltip
            item.headerCell.setAccessibilityHelp(column.tooltip)
            item.width = column == .name ? 180 : 100
            item.isHidden = !model.preferences.visible(column)
            if column.sort != nil {
                item.sortDescriptorPrototype = NSSortDescriptor(key: column.rawValue, ascending: column == .name || column == .pid)
            }
            table.addTableColumn(item)
            if column.optional {
                let menuItem = NSMenuItem(title: column.title, action: #selector(toggleColumn(_:)), keyEquivalent: "")
                menuItem.representedObject = column.rawValue
                menuItem.target = self
                menuItem.state = item.isHidden ? .off : .on
                columnMenu.addItem(menuItem)
            }
        }
        table.headerView?.menu = columnMenu
        table.sortDescriptors = [NSSortDescriptor(key: ProcessColumn.cpu.rawValue, ascending: false)]
        dataSource.queryChanged = { [weak self] in self?.refreshQuery() }
        dataSource.selectionChanged = { [weak self] in
            guard let self else { return }
            Task { await self.model.refreshInspector() }
        }
        loadMore.target = self
        loadMore.action = #selector(more)
        let list = verticalStack([controls, scroll, NSStackView(views: [count, loadMore])])
        for view in [controls, scroll] {
            view.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
        }
        let listContainer = NSView()
        inset(list, in: listContainer, by: 0)
        let inspector = inspectorView()
        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.addArrangedSubview(listContainer)
        split.addArrangedSubview(inspector)
        inspector.widthAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
        listContainer.widthAnchor.constraint(greaterThanOrEqualToConstant: 600).isActive = true
        let cpuSummary = verticalStack([NSTextField(labelWithString: "System CPU · 0–100%"), systemCPUChart], spacing: 2)
        let memorySummary = verticalStack([NSTextField(labelWithString: "Memory used / physical"), systemMemoryChart], spacing: 2)
        let pressureSummary = verticalStack([NSTextField(labelWithString: "Memory pressure"), systemPressureChart], spacing: 2)
        for group in [cpuSummary, memorySummary, pressureSummary] {
            group.widthAnchor.constraint(equalToConstant: 160).isActive = true
        }
        for chart in [systemCPUChart, systemMemoryChart, systemPressureChart] {
            chart.widthAnchor.constraint(equalToConstant: 160).isActive = true
        }
        summary.setContentHuggingPriority(.defaultLow, for: .horizontal)
        summary.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let summaryBar = NSStackView(views: [summary, cpuSummary, memorySummary, pressureSummary])
        summaryBar.distribution = .fill
        summaryBar.alignment = .top
        summaryBar.spacing = 16
        let root = verticalStack([onboardingBanner(), summaryBar, split])
        agentBanner.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        split.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        summaryBar.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        let content = NSView()
        inset(root, in: content)
        window.contentView = content
    }

    private func onboardingBanner() -> NSView {
        agentBanner.boxType = .custom
        agentBanner.titlePosition = .noTitle
        agentBanner.borderColor = .controlAccentColor
        agentBanner.fillColor = NSColor.controlAccentColor.withAlphaComponent(0.1)
        agentBanner.cornerRadius = 8
        agentBanner.contentViewMargins = NSSize(width: 12, height: 12)
        agentBanner.setAccessibilityIdentifier("agentOnboardingBanner")
        let explanation = NSTextField(wrappingLabelWithString: "procglint needs its background agent to show processes.")
        explanation.font = .systemFont(ofSize: 15, weight: .semibold)
        explanation.setAccessibilityIdentifier("agentOnboardingMessage")
        agentBannerDetail.setAccessibilityIdentifier("agentOnboardingDetail")
        registerAgent.target = self
        registerAgent.action = #selector(registerBackgroundAgent)
        registerAgent.setAccessibilityIdentifier("registerAgent")
        loginItems.target = self
        loginItems.action = #selector(showLoginItems)
        loginItems.setAccessibilityIdentifier("agentLoginItems")
        let content = verticalStack([explanation, agentBannerDetail, NSStackView(views: [registerAgent, loginItems])])
        for label in [explanation, agentBannerDetail] {
            label.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        }
        if let container = agentBanner.contentView {
            inset(content, in: container, by: 0)
        }
        return agentBanner
    }

    @objc private func registerBackgroundAgent() {
        register()
    }

    @objc private func showLoginItems() {
        openLoginItems()
    }

    private func inspectorView() -> NSView {
        identity.isSelectable = true
        path.isSelectable = true
        pin.target = self
        pin.action = #selector(togglePin)
        quitProcess.target = self
        quitProcess.action = #selector(terminateProcess(_:))
        killProcess.target = self
        killProcess.action = #selector(terminateProcess(_:))
        path.lineBreakMode = .byCharWrapping
        let historyNote = NSTextField(wrappingLabelWithString: "History starts when a process is pinned or selected")
        let stack = verticalStack([
            identity, path, pin, historyNote,
            NSTextField(labelWithString: "CPU · 1 core = 100%"), cpuChart,
            NSTextField(labelWithString: "Memory (footprint)"), memoryChart,
            NSTextField(labelWithString: "Attributed disk I/O per second"), ioChart,
            quitProcess, killProcess, feedback,
        ])
        for view in [identity, path, historyNote, cpuChart, memoryChart, ioChart, feedback] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        return scrollingContent(stack)
    }

    func render() {
        agentBanner.isHidden = !model.showsAgentBanner
        loginItems.isHidden = model.registrationStatus() != .requiresApproval
        switch model.registrationStatus() {
        // SMAppService reports .notFound for a bundled agent that has never been registered.
        case .notRegistered, .notFound: agentBannerDetail.stringValue = "Register the agent to start monitoring; registration only happens when you click below."
        case .requiresApproval: agentBannerDetail.stringValue = "Allow procglint in System Settings → General → Login Items, then return to the app."
        case .enabled: agentBannerDetail.stringValue = "The agent is registered but not responding; register it again or check Settings for diagnostics."
        }
        table.isHidden = !model.agentReachable
        table.usesAlternatingRowBackgroundColors = model.agentReachable && !model.rows.isEmpty
        count.isHidden = !model.agentReachable
        let text = NSMutableAttributedString(string: model.summary, attributes: [.foregroundColor: NSColor.labelColor])
        let badgeColor: NSColor = switch model.header?.status == .unavailable ? nil : model.header?.system.memoryPressure.value {
        case .normal: .systemGreen
        case .warning: .systemYellow
        case .critical: .systemRed
        case nil: .secondaryLabelColor
        }
        text.addAttributes([.backgroundColor: badgeColor.withAlphaComponent(0.2),
                            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)],
                           range: NSRange(location: 0, length: Display.pressure(model.header).utf16.count))
        summary.attributedStringValue = text
        summary.toolTip = [Display.summaryTooltip(model.header), model.message].filter { !$0.isEmpty }.joined(separator: "\n")
        summary.setAccessibilityHelp(summary.toolTip)
        if renderedRows != model.rows {
            renderedRows = model.rows
            dataSource.reload(table)
        }
        count.stringValue = "\(model.rows.count) of \(model.totalMatched) processes"
        loadMore.isHidden = model.nextCursor == nil
        loadMore.isEnabled = !model.isFetching
        if let detail = model.detail {
            identity.stringValue = "\(detail.name)\nPID \(detail.pid) · \(detail.user) (uid \(detail.uid))\nKey: \(detail.processKey.rawValue)\nStarted: \(detail.startTime.formatted(date: .abbreviated, time: .standard))\nStatus: \(detail.status.rawValue)"
            let pathsAllowed = (try? model.preferences.store.allowedPermissions().contains(.includePaths)) == true
            path.stringValue = pathsAllowed ? "Path: \(detail.path ?? "— (not available)")" : "Path: — (permission_denied; enable include_paths in Settings)"
        } else {
            identity.stringValue = "Select a process"
            path.stringValue = ""
        }
        let permissions = try? model.preferences.store.allowedPermissions()
        let own = model.detail?.isOwn == true && model.detail?.status == .ok && model.header?.status != .unavailable && model.header != nil
        quitProcess.isEnabled = own && permissions?.contains(.terminate) == true && !model.terminating
        killProcess.isEnabled = quitProcess.isEnabled && permissions?.contains(.forceKill) == true
        pin.isEnabled = model.detail != nil
        pin.state = model.pinned ? .on : .off
        feedback.stringValue = model.inspectorMessage
        systemCPUChart.update(model.systemHistory, fixedYRange: 0 ... 100)
        let physical = model.header.map { Double($0.system.physicalMemoryBytes) } ?? 0
        systemMemoryChart.update(model.systemHistory, fixedYRange: physical > 0 ? 0 ... physical : nil)
        systemPressureChart.update(model.systemHistory, fixedYRange: 0 ... 100)
        cpuChart.update(model.history)
        memoryChart.update(model.history)
        ioChart.update(model.history)
    }

    func controlTextDidChange(_: Notification) {
        model.setSearch(search.stringValue); refreshQuery()
    }

    @objc private func filterChanged() {
        model.setFilter([.all, .mine, .pinned][filter.selectedSegment]); refreshQuery()
    }

    private func refreshQuery() {
        Task { await model.tick() }
    }

    @objc private func more() {
        Task { await model.loadMore() }
    }

    @objc private func togglePin() {
        Task { await model.togglePin() }
    }

    @objc private func toggleColumn(_ item: NSMenuItem) {
        guard let raw = item.representedObject as? String, let column = ProcessColumn(rawValue: raw),
              let tableColumn = table.tableColumns.first(where: { $0.identifier.rawValue == raw }) else { return }
        tableColumn.isHidden.toggle()
        item.state = tableColumn.isHidden ? .off : .on
        model.preferences.setVisible(!tableColumn.isHidden, column: column)
    }

    @objc private func terminateProcess(_ sender: NSButton) {
        let signal: TerminationSignal = sender === killProcess ? .kill : .term
        Task {
            await model.terminate(signal: signal) { [weak self] target, signal in
                guard let window = self?.window else { return false }
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "\(signal == .kill ? "Force quit" : "Quit") \(target.name) (PID \(target.pid))?"
                alert.informativeText = "Unsaved data may be lost, even with SIGTERM. This sends \(signal == .kill ? "SIGKILL" : "SIGTERM") only to this process; it never escalates automatically."
                alert.addButton(withTitle: "Cancel").setAccessibilityIdentifier("cancelTermination")
                alert.addButton(withTitle: signal == .kill ? "Force Quit (SIGKILL)" : "Quit (SIGTERM)").setAccessibilityIdentifier("confirmTermination")
                return await withCheckedContinuation { continuation in
                    alert.beginSheetModal(for: window) { response in continuation.resume(returning: response == .alertSecondButtonReturn) }
                }
            }
        }
    }

    func windowDidBecomeKey(_: Notification) {
        focusChanged?()
    }

    func windowDidResignKey(_: Notification) {
        if let chart = chartCursor.hoveredChart {
            chartCursor.clear(from: chart)
        }
        focusChanged?()
    }

    func windowDidChangeOcclusionState(_: Notification) {
        visibilityChanged?()
    }

    func windowDidMiniaturize(_: Notification) {
        visibilityChanged?()
    }

    func windowDidDeminiaturize(_: Notification) {
        visibilityChanged?()
    }

    func windowWillClose(_: Notification) {
        Task { @MainActor [weak self] in self?.visibilityChanged?() }
    }
}
