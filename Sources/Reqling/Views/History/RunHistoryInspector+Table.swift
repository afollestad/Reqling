import AppKit
import ReqlingKit
import SwiftUI

/// The inspector's runs as a source-list `NSTableView`, a header row per day: arrow keys, ⇧-arrows, and ⌘- and ⇧-clicks
/// select as in any list, and the selection syncs with `RunHistoryViewModel.selection` both ways.
///
/// AppKit rather than a SwiftUI `List` for one reason: a focused list fills its selection with the accent and turns its
/// text white, which read as too strong beside the window's sidebar, whose selection macOS keeps neutral. SwiftUI
/// offers no way to change that, `.tint` included; `RunHistoryRowView` reports itself never emphasized, so a selected run
/// keeps the neutral highlight whether or not the table has focus.
struct RunHistoryTable: NSViewRepresentable {
    let history: RunHistoryViewModel
    let days: [RunHistoryDay]
    let latest: RunID?
    let selection: Set<RunID>

    func makeCoordinator() -> RunHistoryTableCoordinator {
        RunHistoryTableCoordinator()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let coordinator = context.coordinator
        let column = NSTableColumn(identifier: RunHistoryTableCoordinator.columnID)
        column.resizingMask = .autoresizingMask
        let table = RunHistoryTableView()
        table.addTableColumn(column)
        table.style = .sourceList
        table.headerView = nil
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        table.usesAutomaticRowHeights = true
        table.floatsGroupRows = false
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.backgroundColor = .clear
        table.setAccessibilityLabel("Run history")
        table.dataSource = coordinator
        table.delegate = coordinator
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = coordinator
        table.menu = menu
        coordinator.table = table
        let scrollView = NSScrollView()
        scrollView.documentView = table
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.update(history: history, days: days, latest: latest, selection: selection)
    }
}

/// Feeds `RunHistoryTable` its rows and menu, and carries selection between the table and the view model; applying the
/// view model's selection (`RunHistoryViewModel.displayedSelection`) to the table never echoes back.
@MainActor
final class RunHistoryTableCoordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    static let columnID = NSUserInterfaceItemIdentifier("run")
    private static let dayCellID = NSUserInterfaceItemIdentifier("day")
    private static let runCellID = NSUserInterfaceItemIdentifier("run-cell")

    private enum Item: Equatable {
        case day(String)
        case run(RunHistoryDay.Row, isLatest: Bool)

        var runID: RunID? {
            if case .run(let row, _) = self {
                return row.run.id
            }
            return nil
        }
    }

    weak var table: RunHistoryTableView?
    private var history: RunHistoryViewModel?
    private var items: [Item] = []
    private var isApplyingSelection = false

    func update(history: RunHistoryViewModel, days: [RunHistoryDay], latest: RunID?, selection: Set<RunID>) {
        self.history = history
        let items = days.flatMap { day in
            [Item.day(day.title)] + day.runs.map { Item.run($0, isLatest: $0.run.id == latest) }
        }
        if items != self.items {
            self.items = items
            // A reload keeps selected indexes, which now point at other runs; the view model's selection, applied next,
            // is the truth, so the reload's own selection change must not reach it.
            isApplyingSelection = true
            table?.reloadData()
            isApplyingSelection = false
        }
        applySelection(selection)
    }

    private func applySelection(_ selection: Set<RunID>) {
        guard let table else {
            return
        }
        let rows = IndexSet(items.indices.filter { items[$0].runID.map(selection.contains) == true })
        guard rows != table.selectedRowIndexes else {
            return
        }
        isApplyingSelection = true
        table.selectRowIndexes(rows, byExtendingSelection: false)
        isApplyingSelection = false
    }

    private func runIDs(at rows: IndexSet) -> Set<RunID> {
        Set(rows.compactMap { items.indices.contains($0) ? items[$0].runID : nil })
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int {
        items.count
    }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        items[row].runID == nil
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        items[row].runID != nil
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        RunHistoryRowView()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch items[row] {
        case .day(let title):
            let cell = tableView.makeView(withIdentifier: Self.dayCellID, owner: nil) as? NSTableCellView ?? Self.makeDayCell()
            cell.textField?.stringValue = title
            return cell
        case .run(let run, let isLatest):
            // The row itself stays SwiftUI, hosted in the cell: only the list around it needed AppKit.
            let content = RunHistoryRow(run: run.run, time: run.time, isLatest: isLatest)
            if let host = tableView.makeView(withIdentifier: Self.runCellID, owner: nil) as? NSHostingView<RunHistoryRow> {
                host.rootView = content
                return host
            }
            let host = NSHostingView(rootView: content)
            host.identifier = Self.runCellID
            return host
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isApplyingSelection, let table, let history else {
            return
        }
        history.select(runIDs(at: table.selectedRowIndexes))
    }

    private static func makeDayCell() -> NSTableCellView {
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        let cell = NSTableCellView()
        cell.identifier = dayCellID
        cell.textField = label
        cell.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            label.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor),
            label.topAnchor.constraint(equalTo: cell.topAnchor, constant: 8),
            label.bottomAnchor.constraint(equalTo: cell.bottomAnchor, constant: -5)
        ])
        return cell
    }

    // MARK: - Menu

    /// One run's actions, or Compare for two runs.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let table, let history else {
            return
        }
        let selected = menuRuns(in: table)
        let runs = history.runs.filter { selected.contains($0.id) }
        if runs.count == 1, let run = runs.first {
            menu.addItem(menuItem("Re-run", #selector(rerun(_:)), run, enabled: history.canReplay(run)))
            menu.addItem(menuItem("Restore Request…", #selector(restore(_:)), run, enabled: history.canRestore(run)))
            menu.addItem(.separator())
            menu.addItem(menuItem("Compare with Latest", #selector(compareWithLatest(_:)), run, enabled: run.id != history.runs.first?.id))
        } else if runs.count == 2 {
            menu.addItem(menuItem("Compare", #selector(compare(_:)), Array(selected), enabled: true))
        }
    }

    /// The selected runs when VoiceOver opened the menu; else the right-clicked run, or the selection the click landed in.
    private func menuRuns(in table: RunHistoryTableView) -> Set<RunID> {
        if table.isMenuForSelection {
            return runIDs(at: table.selectedRowIndexes)
        }
        guard items.indices.contains(table.clickedRow), let clicked = items[table.clickedRow].runID else {
            return []
        }
        return table.selectedRowIndexes.contains(table.clickedRow) ? runIDs(at: table.selectedRowIndexes) : [clicked]
    }

    private func menuItem(_ title: String, _ action: Selector, _ object: Any, enabled: Bool) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = object
        item.isEnabled = enabled
        return item
    }

    @objc private func rerun(_ sender: NSMenuItem) {
        if let run = sender.representedObject as? RunSummary {
            history?.rerun(run)
        }
    }

    @objc private func restore(_ sender: NSMenuItem) {
        if let run = sender.representedObject as? RunSummary {
            history?.requestRestore(run)
        }
    }

    @objc private func compareWithLatest(_ sender: NSMenuItem) {
        if let run = sender.representedObject as? RunSummary {
            history?.compareWithLatest(run.id)
        }
    }

    @objc private func compare(_ sender: NSMenuItem) {
        guard let runs = sender.representedObject as? [RunID], let history else {
            return
        }
        history.selection = Set(runs)
        history.compare()
    }
}

/// `RunHistoryTable`'s table, whose menu opened without a click (VoiceOver's VO-Shift-M) acts on the selected runs.
/// AppKit's own opens it for the row that last had keyboard focus, which a selection made through accessibility never
/// moves, so Re-run or Restore would act on a run other than the selected one.
final class RunHistoryTableView: NSTableView {
    /// True while a menu opened that way is up; `RunHistoryTableCoordinator.menuNeedsUpdate(_:)` reads it.
    var isMenuForSelection = false

    /// No menu without a selection: AppKit's would act on the focused row, which VoiceOver may never have spoken.
    override func accessibilityPerformShowMenu() -> Bool {
        guard menu != nil, selectedRow >= 0 else {
            return false
        }
        // A run-loop turn later, so the accessibility call returns while the menu tracks. Not a main-actor `Task`: tracking
        // inside one holds the main queue, stalling every other main-actor task until the menu closes.
        perform(#selector(showMenuForSelection), with: nil, afterDelay: 0)
        return true
    }

    @objc private func showMenuForSelection() {
        guard let menu, selectedRow >= 0 else {
            return
        }
        let row = rect(ofRow: selectedRow)
        isMenuForSelection = true
        defer { isMenuForSelection = false }
        menu.popUp(positioning: nil, at: NSPoint(x: row.minX, y: row.maxY), in: self)
    }
}

/// Never emphasized, so a selected run keeps the neutral highlight, with its cells' normal text colors, whether or not the
/// table has focus; see `RunHistoryTable`.
final class RunHistoryRowView: NSTableRowView {
    override var isEmphasized: Bool {
        get { false }
        set {}
    }
}
