import AppKit
import ProcglintCore
import SwiftUI

@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate, NSSearchFieldDelegate, NSToolbarDelegate, NSUserInterfaceValidations {
    let model: MonitorViewModel
    let table = NSTableView()
    let processScroll = NSScrollView()
    let footer = NSStackView()
    let agentBannerContainer = NSView()
    private var headerHeight: NSLayoutConstraint?
    private lazy var bannerHeight = agentBannerContainer.heightAnchor.constraint(equalToConstant: 0)
    let dataSource: ProcessTableDataSource
    let search = NSSearchField()
    let filter = NSSegmentedControl(labels: ["All", "Mine", "Pinned"], trackingMode: .selectOne, target: nil, action: nil)
    let splitController = NSSplitViewController()
    let loadMore = NSButton(title: "Load more", target: nil, action: nil)
    let count = NSTextField(labelWithString: "")
    let agentBanner = NSBox()
    let agentBannerDetail = NSTextField(wrappingLabelWithString: "")
    let registerAgent = NSButton(title: "Register agent…", target: nil, action: nil)
    let loginItems = NSButton(title: "Open Login Items…", target: nil, action: nil)
    private let register: @MainActor () -> Void
    private let registrationError: @MainActor () -> String
    private let openLoginItems: @MainActor () -> Void
    var visibilityChanged: (@MainActor () -> Void)?
    var focusChanged: (@MainActor () -> Void)?
    private var renderedRows: [ProcessSample] = []
    private var copied = false
    private var copyFeedback: Task<Void, Never>?

    init(model: MonitorViewModel, register: @escaping @MainActor () -> Void = {},
         openLoginItems: @escaping @MainActor () -> Void = {}, registrationError: @escaping @MainActor () -> String = { "" })
    {
        self.model = model
        self.register = register
        self.registrationError = registrationError
        self.openLoginItems = openLoginItems
        dataSource = ProcessTableDataSource(model: model)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1360, height: 900),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "procglint"
        window.toolbarStyle = .unified
        window.setAccessibilityIdentifier("mainWindow")
        window.minSize = NSSize(width: 1000, height: 650)
        window.isReleasedWhenClosed = false
        window.acceptsMouseMovedEvents = true
        super.init(window: window)
        window.delegate = self
        buildUI(window)
        window.setContentSize(NSSize(width: 1360, height: 900))
        window.contentView?.layoutSubtreeIfNeeded()
        splitController.splitView.setPosition(980, ofDividerAt: 0)
        window.center()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Programmatic UI only")
    }

    var monitoringVisible: Bool {
        window?.isVisible == true && window?.occlusionState.contains(.visible) == true && window?.isMiniaturized == false
    }

    private func buildUI(_ window: NSWindow) {
        count.setAccessibilityIdentifier("processCount")
        count.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        count.textColor = .secondaryLabelColor
        search.setAccessibilityIdentifier("processSearch")
        filter.setAccessibilityIdentifier("processFilter")
        table.setAccessibilityIdentifier("processTable")
        search.stringValue = model.query.search ?? ""
        search.placeholderString = "Search name or exact PID"
        search.setAccessibilityLabel("Search processes by name or PID")
        search.delegate = self
        filter.selectedSegment = 0
        filter.target = self
        filter.action = #selector(filterChanged)
        filter.setAccessibilityLabel("Process filter")
        let scroll = processScroll
        scroll.setAccessibilityIdentifier("processScroll")
        scroll.borderType = .noBorder
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.documentView = table
        table.dataSource = dataSource
        table.delegate = dataSource
        table.style = .fullWidth
        table.rowSizeStyle = .default
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = true
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.setAccessibilityLabel("Processes")
        let columnMenu = NSMenu(title: "Columns")
        for column in ProcessColumn.allCases {
            let item = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(column.rawValue))
            item.title = column.title
            item.headerCell.setAccessibilityIdentifier("column.\(column.rawValue)")
            item.headerToolTip = column.tooltip
            item.headerCell.setAccessibilityHelp(column.tooltip)
            item.headerCell.alignment = column.numeric ? .right : .left
            item.width = column == .name ? 200 : 100
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
        loadMore.bezelStyle = .inline
        footer.setViews([count, loadMore], in: .leading)
        footer.orientation = .horizontal
        footer.spacing = 8
        footer.edgeInsets = NSEdgeInsets(top: 6, left: 14, bottom: 6, right: 14)
        let list = NSView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        footer.translatesAutoresizingMaskIntoConstraints = false
        list.addSubview(scroll)
        list.addSubview(footer)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: list.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: list.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: list.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: footer.topAnchor),
            footer.leadingAnchor.constraint(equalTo: list.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: list.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: list.bottomAnchor),
            footer.heightAnchor.constraint(equalToConstant: 32),
        ])
        let listController = NSViewController()
        listController.view = list
        let content = NSSplitViewItem(viewController: listController)
        content.minimumThickness = 560
        let inspectorController = NSViewController()
        let inspector = NSHostingView(rootView: ProcessInspector(model: model, terminate: { [weak self] in self?.terminateProcess(signal: $0) },
                                                                 copyDetails: { [weak self] in self?.copyDetails() }))
        inspector.sizingOptions = []
        inspectorController.view = inspector
        let inspectorItem = NSSplitViewItem(inspectorWithViewController: inspectorController)
        inspectorItem.canCollapse = true
        inspectorItem.minimumThickness = 330
        inspectorItem.maximumThickness = 440
        splitController.splitView.isVertical = true
        splitController.addSplitViewItem(content)
        splitController.addSplitViewItem(inspectorItem)
        let header = NSHostingView(rootView: MonitorHeader(model: model))
        header.sizingOptions = []
        headerHeight = header.heightAnchor.constraint(equalToConstant: 178)
        headerHeight?.isActive = true
        let rootController = NSViewController()
        rootController.addChild(splitController)
        let root = NSView(frame: window.contentLayoutRect)
        rootController.view = root
        let banner = onboardingBanner()
        banner.translatesAutoresizingMaskIntoConstraints = false
        agentBannerContainer.addSubview(banner)
        NSLayoutConstraint.activate([
            banner.topAnchor.constraint(equalTo: agentBannerContainer.topAnchor),
            banner.leadingAnchor.constraint(equalTo: agentBannerContainer.leadingAnchor),
            banner.trailingAnchor.constraint(equalTo: agentBannerContainer.trailingAnchor),
            banner.heightAnchor.constraint(equalToConstant: 124),
        ])
        for view in [agentBannerContainer, header, splitController.view] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
            view.leadingAnchor.constraint(equalTo: root.leadingAnchor).isActive = true
            view.trailingAnchor.constraint(equalTo: root.trailingAnchor).isActive = true
        }
        // Only the split view is flexible; neither the banner nor the footer may consume its height.
        NSLayoutConstraint.activate([
            agentBannerContainer.topAnchor.constraint(equalTo: root.topAnchor),
            bannerHeight,
            header.topAnchor.constraint(equalTo: agentBannerContainer.bottomAnchor),
            splitController.view.topAnchor.constraint(equalTo: header.bottomAnchor),
            splitController.view.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        window.contentViewController = rootController
        let toolbar = NSToolbar(identifier: "mainToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
    }

    func toolbarDefaultItemIdentifiers(_: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.init("filter"), .flexibleSpace, .init("search"), .init("copyList"), .init("inspector")]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar _: Bool) -> NSToolbarItem? {
        if identifier.rawValue == "search" {
            let item = NSSearchToolbarItem(itemIdentifier: identifier)
            item.searchField = search
            return item
        }
        let item = NSToolbarItem(itemIdentifier: identifier)
        if identifier.rawValue == "filter" {
            item.label = "Process filter"
            item.view = filter
        } else if identifier.rawValue == "copyList" {
            item.label = "Copy List"
            item.toolTip = "Copy all shown processes as Markdown"
            let button = NSButton(image: NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy List")!, target: self, action: #selector(copyList))
            button.bezelStyle = .texturedRounded
            button.setAccessibilityIdentifier("copyList")
            item.view = button
        } else if identifier.rawValue == "inspector" {
            item.label = "Inspector"
            item.toolTip = "Show or hide inspector"
            let button = NSButton(image: NSImage(systemSymbolName: "sidebar.trailing", accessibilityDescription: "Toggle inspector")!, target: self, action: #selector(toggleInspector))
            button.bezelStyle = .texturedRounded
            button.setAccessibilityIdentifier("toggleInspector")
            item.view = button
        } else {
            return nil
        }
        return item
    }

    @objc func toggleInspector() {
        model.chartSelection.clear()
        guard let inspector = splitController.splitViewItems.last else { return }
        inspector.isCollapsed.toggle()
        splitController.splitView.adjustSubviews()
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
        if model.registrationStatus() == .enabled {
            Task { await model.tick() }
        } else {
            register()
        }
    }

    @objc private func showLoginItems() {
        openLoginItems()
        Task { await model.tick() }
    }

    func render() {
        headerHeight?.constant = model.header?.system.battery == nil ? 178 : 216
        window?.subtitle = copied ? "Copied" : (model.agentReachable ? "Agent · \(model.header?.status.rawValue ?? "unavailable")" : "Agent unavailable")
        let setup = AgentSetup(status: model.registrationStatus(), reachable: model.agentReachable)
        agentBanner.isHidden = !setup.showsBanner
        agentBannerContainer.isHidden = !setup.showsBanner
        bannerHeight.constant = setup.showsBanner ? 124 : 0
        loginItems.isHidden = !setup.needsApproval
        registerAgent.isHidden = setup.needsApproval
        registerAgent.title = setup.canRegister ? "Register agent…" : "Retry connection"
        agentBannerDetail.stringValue = registrationError().isEmpty ? setup.explanation : registrationError()
        table.isHidden = !model.agentReachable
        table.usesAlternatingRowBackgroundColors = model.agentReachable && !model.rows.isEmpty
        count.isHidden = !model.agentReachable
        if renderedRows != model.rows {
            renderedRows = model.rows
            dataSource.reload(table)
        } else {
            dataSource.restoreSelection(table)
        }
        count.stringValue = "\(model.rows.count) of \(model.totalMatched) processes" + (model.nextCursor == nil ? "" : " ·")
        loadMore.isHidden = model.nextCursor == nil
        loadMore.isEnabled = !model.isFetching
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

    @objc private func copyList() {
        copyRows(nil)
    }

    @objc func copy(_: Any?) {
        guard !table.selectedRowIndexes.isEmpty else { return }
        copyRows(table.selectedRowIndexes)
    }

    func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        item.action != #selector(copy(_:)) || (!table.isHidden && !table.selectedRowIndexes.isEmpty)
    }

    private func copyRows(_ selectedRows: IndexSet?) {
        guard !table.isHidden else { return }
        let columns = table.tableColumns.filter { !$0.isHidden }.compactMap { ProcessColumn(rawValue: $0.identifier.rawValue) }
        copyText(CopyText.list(rows: model.rows, columns: columns, header: model.header, totalMatched: model.totalMatched,
                               query: model.displayedQuery ?? model.query, selectedRows: selectedRows))
    }

    private func copyDetails() {
        guard let process = model.detail else { return }
        let window = ChartGeometry.historyWindow(endingAt: model.header?.sampledAt ?? model.history?.points.last?.t, minutes: model.policy.historyMinutes)
        copyText(CopyText.details(process: process, permissions: model.permissions, history: model.history, window: window))
    }

    private func copyText(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copyFeedback?.cancel()
        copied = true
        render()
        copyFeedback = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(1500)) } catch { return }
            self?.copied = false
            self?.render()
        }
    }

    @objc private func toggleColumn(_ item: NSMenuItem) {
        guard let raw = item.representedObject as? String, let column = ProcessColumn(rawValue: raw),
              let tableColumn = table.tableColumns.first(where: { $0.identifier.rawValue == raw }) else { return }
        tableColumn.isHidden.toggle()
        item.state = tableColumn.isHidden ? .off : .on
        model.preferences.setVisible(!tableColumn.isHidden, column: column)
    }

    private func terminateProcess(signal: TerminationSignal) {
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
        model.chartSelection.clear(); focusChanged?()
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
