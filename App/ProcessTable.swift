import AppKit
import ProcglintCore

@MainActor
final class ProcessTableDataSource: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let model: MonitorViewModel
    var selectionChanged: (@MainActor () -> Void)?
    var queryChanged: (@MainActor () -> Void)?
    private var restoringSelection = false

    init(model: MonitorViewModel) {
        self.model = model
    }

    func numberOfRows(in _: NSTableView) -> Int {
        model.rows.count
    }

    func cellText(row: Int, column: ProcessColumn) -> MetricText? {
        guard model.rows.indices.contains(row) else { return nil }
        return column.text(for: model.rows[row])
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn, let column = ProcessColumn(rawValue: tableColumn.identifier.rawValue),
              let value = cellText(row: row, column: column) else { return nil }
        let cell = tableView.makeView(withIdentifier: tableColumn.identifier, owner: self) as? NSTableCellView ?? makeCell(tableColumn.identifier)
        cell.textField?.setAccessibilityIdentifier("process.\(model.rows[row].pid).\(column.rawValue)")
        cell.textField?.font = column.numeric ? .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular) : .systemFont(ofSize: NSFont.systemFontSize)
        cell.textField?.alignment = column.numeric ? .right : .left
        cell.textField?.stringValue = value.text
        cell.textField?.toolTip = value.reason
        cell.textField?.setAccessibilityHelp(value.reason)
        cell.toolTip = value.reason
        return cell
    }

    private func makeCell(_ identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier
        let text = NSTextField(labelWithString: "")
        text.lineBreakMode = .byTruncatingTail
        text.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(text)
        cell.textField = text
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    func reload(_ tableView: NSTableView) {
        restoringSelection = true
        tableView.reloadData()
        restoreSelection(tableView, scrollToSelection: false)
        restoringSelection = false
    }

    func restoreSelection(_ tableView: NSTableView, scrollToSelection: Bool = true) {
        restoringSelection = true
        defer { restoringSelection = false }
        if let index = model.rows.firstIndex(where: { $0.processKey == model.selectedKey }) {
            if tableView.selectedRow != index {
                tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
                if scrollToSelection {
                    tableView.scrollRowToVisible(index)
                }
            }
        } else {
            tableView.deselectAll(nil)
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !restoringSelection, let table = notification.object as? NSTableView else { return }
        model.select(model.rows.indices.contains(table.selectedRow) ? model.rows[table.selectedRow].processKey : nil)
        selectionChanged?()
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange _: [NSSortDescriptor]) {
        guard let sort = tableView.sortDescriptors.first, let key = sort.key, let column = ProcessColumn(rawValue: key) else { return }
        model.setSort(column: column, ascending: sort.ascending)
        queryChanged?()
    }
}

@MainActor
private final class FlippedDocumentView: NSView {
    override var isFlipped: Bool {
        true
    }
}

@MainActor
func scrollingContent(_ content: NSView) -> NSScrollView {
    let scroll = NSScrollView()
    scroll.hasVerticalScroller = true
    scroll.drawsBackground = false
    let document = FlippedDocumentView()
    document.translatesAutoresizingMaskIntoConstraints = false
    inset(content, in: document)
    scroll.documentView = document
    document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true
    return scroll
}

@MainActor
func verticalStack(_ views: [NSView], spacing: CGFloat = 8) -> NSStackView {
    let stack = NSStackView(views: views)
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = spacing
    return stack
}

@MainActor
func inset(_ content: NSView, in container: NSView, by padding: CGFloat = 12) {
    content.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(content)
    NSLayoutConstraint.activate([
        content.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: padding),
        content.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -padding),
        content.topAnchor.constraint(equalTo: container.topAnchor, constant: padding),
        content.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -padding),
    ])
}
