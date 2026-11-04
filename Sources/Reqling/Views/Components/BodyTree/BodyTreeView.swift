import AppKit
import ReqlingKit
import SwiftUI

/// A JSON or XML body as a collapsible tree, virtualized end to end: `NSOutlineView` makes views only for the rows on
/// screen, and `BodyTreeItem`s exist only for containers someone expanded, so a body of any size opens at once.
struct BodyTreeView: NSViewRepresentable {
    let structure: BodyStructure
    var currentMatch: BodyTreeMatch?
    var controller: BodyTreeController?
    var accessibilityLabel: String
    /// The Find menu reaching the tree while it has focus.
    var onFind: ((NSTextFinder.Action) -> Void)?

    /// Expand All stops opening rows past this many, so a huge body never builds millions of rows; Option-clicking a
    /// disclosure triangle, which expands a whole subtree, stops at it too.
    static let expandBudget = 5_000

    func makeCoordinator() -> BodyTreeCoordinator {
        BodyTreeCoordinator()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let outline = Self.makeOutline(coordinator: context.coordinator)
        let scrollView = NSScrollView()
        scrollView.documentView = outline
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        return scrollView
    }

    /// The outline, wired to `coordinator`.
    static func makeOutline(coordinator: BodyTreeCoordinator) -> BodyTreeOutlineView {
        let outline = BodyTreeOutlineView()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("value"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        outline.rowHeight = CodeViewerMetrics.standard.rowHeight + 4
        outline.usesAutomaticRowHeights = false
        outline.style = .plain
        outline.backgroundColor = .clear
        outline.allowsTypeSelect = false
        outline.indentationPerLevel = 14
        outline.autoresizesOutlineColumn = false
        outline.coordinator = coordinator
        outline.dataSource = coordinator
        outline.delegate = coordinator
        let menu = NSMenu()
        menu.delegate = coordinator
        outline.menu = menu
        coordinator.outline = outline
        return outline
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.accent = context.environment.appAccent
        controller?.coordinator = coordinator
        coordinator.outline?.onFind = onFind
        coordinator.outline?.setAccessibilityLabel(accessibilityLabel)
        coordinator.show(structure)
        coordinator.reveal(currentMatch)
    }
}

/// How the section bar's Expand All and Collapse All reach the tree on screen.
@MainActor
final class BodyTreeController {
    weak var coordinator: BodyTreeCoordinator?

    func expandAll() {
        coordinator?.expand(from: nil, budget: BodyTreeView.expandBudget)
    }

    func collapseAll() {
        coordinator?.collapseAll()
    }
}

/// The outline's data source and delegate: loads children as rows expand, and expands, collapses, and reveals.
@MainActor
final class BodyTreeCoordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
    weak var outline: BodyTreeOutlineView?
    var accent: NSColor = .controlAccentColor
    private(set) var structure: BodyStructure?
    /// The hidden node above the top-level values.
    private(set) var document = BodyTreeItem(node: .document, range: 0..<1, parentNode: nil)
    /// The rows at the top level: the top-level values, or buckets of them.
    private(set) var roots: [BodyTreeItem] = []
    /// How many top-level values there are: one for a document, more for newline-delimited JSON.
    private(set) var rootCount = 0
    private var revealed: BodyTreeMatch?

    // MARK: - Content

    /// Shows `structure` with its top level open; the same structure again changes nothing.
    func show(_ structure: BodyStructure) {
        guard structure.id != self.structure?.id, let outline else {
            return
        }
        self.structure = structure
        revealed = nil
        document = BodyTreeItem(node: .document, range: 0..<1, parentNode: nil)
        roots = displayChildren(of: document)
        rootCount = document.childNodes?.count ?? 0
        outline.reloadData()
        openSingleRoot()
    }

    /// Opens the top-level value of a single document; a sequence of them starts closed.
    private func openSingleRoot() {
        if rootCount == 1, let root = roots.first, isExpandable(root) {
            outline?.expandOne(root)
        }
    }

    /// True for the top-level value of a single document, which reads as the whole document rather than an item.
    func isSingleRoot(_ item: BodyTreeItem) -> Bool {
        item.parentNode === document && rootCount == 1
    }

    func isExpandable(_ item: BodyTreeItem) -> Bool {
        switch item.node {
        case nil, .document:
            true
        case .json(let entry):
            entry.childCount > 0
        case .xml(let node):
            if case .xml(let index) = structure {
                index.nodes[node].childCount > 0
            } else {
                false
            }
        }
    }

    func displayChildren(of item: BodyTreeItem) -> [BodyTreeItem] {
        if let children = item.displayChildren {
            return children
        }
        guard let owner = item.childSource else {
            return []
        }
        if owner.childNodes == nil {
            owner.childNodes = loadChildren(of: owner)
        }
        let range = item.isBucket ? item.range : 0..<(owner.childNodes?.count ?? 0)
        let children = BodyTreeItem.level(of: owner, range: range)
        item.displayChildren = children
        return children
    }

    private func loadChildren(of item: BodyTreeItem) -> [BodyTreeItem.Node] {
        switch (item.node, structure) {
        case (.document, .json(let index)):
            index.rootEntries().map(BodyTreeItem.Node.json)
        case (.document, .xml(let index)):
            index.roots.map(BodyTreeItem.Node.xml)
        case (.json(let entry), .json(let index)):
            entry.container.map { index.children(of: $0).map(BodyTreeItem.Node.json) } ?? []
        case (.xml(let node), .xml(let index)):
            index.children(of: node).map(BodyTreeItem.Node.xml)
        default:
            []
        }
    }

    // MARK: - Expanding

    /// Opens rows breadth-first from `start` (or the top) until the tree shows about `budget` rows.
    func expand(from start: BodyTreeItem?, budget: Int) {
        guard let outline else {
            return
        }
        var queue = start.map { [$0] } ?? roots
        var rows = outline.numberOfRows
        var index = 0
        // One batch: expanding item by item makes the outline redo its row bookkeeping after each.
        outline.beginUpdates()
        defer { outline.endUpdates() }
        while index < queue.count, rows < budget {
            let item = queue[index]
            index += 1
            guard isExpandable(item) else {
                continue
            }
            let children = displayChildren(of: item)
            if !outline.isItemExpanded(item) {
                outline.expandOne(item)
                rows += children.count
            }
            queue.append(contentsOf: children)
        }
    }

    /// Closes everything below the top level.
    func collapseAll() {
        guard let outline else {
            return
        }
        for root in roots {
            outline.collapseItem(root, collapseChildren: true)
        }
        openSingleRoot()
    }

    /// Expands down to the node `match` names, then selects it and scrolls to it.
    func reveal(_ match: BodyTreeMatch?) {
        guard match != revealed, let outline else {
            return
        }
        revealed = match
        guard let match else {
            return
        }
        var item = document
        for position in match.path {
            if item !== document {
                outline.expandOne(item)
            }
            var children = displayChildren(of: item)
            while let bucket = children.first(where: { $0.isBucket && $0.range.contains(position) }) {
                outline.expandOne(bucket)
                children = displayChildren(of: bucket)
            }
            guard let next = children.first(where: { !$0.isBucket && $0.range.lowerBound == position }) else {
                return
            }
            item = next
        }
        let row = outline.row(forItem: item)
        guard row >= 0 else {
            return
        }
        outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        outline.scrollRowToVisible(row)
    }

    // MARK: - NSOutlineViewDataSource

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let item = item as? BodyTreeItem else {
            return roots.count
        }
        return displayChildren(of: item).count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let item = item as? BodyTreeItem else {
            return roots[index]
        }
        return displayChildren(of: item)[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? BodyTreeItem).map(isExpandable) ?? false
    }

    // MARK: - NSOutlineViewDelegate

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let item = item as? BodyTreeItem else {
            return nil
        }
        let identifier = NSUserInterfaceItemIdentifier("BodyTreeCell")
        let cell = outlineView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView ?? Self.makeCell(identifier)
        let row = rowText(for: item)
        cell.textField?.attributedStringValue = row.text
        cell.textField?.setAccessibilityLabel(row.accessibilityLabel)
        return cell
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        let identifier = NSUserInterfaceItemIdentifier("BodyTreeRow")
        let rowView = outlineView.makeView(withIdentifier: identifier, owner: nil) as? BodyTreeRowView ?? BodyTreeRowView()
        rowView.identifier = identifier
        rowView.accent = accent
        return rowView
    }

    private static func makeCell(_ identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = BodyTreeCell()
        cell.identifier = identifier
        return cell
    }

    // MARK: - NSMenuDelegate

    /// The row right-clicked, or the selected one for the keyboard's menu.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let outline else {
            return
        }
        let row = outline.clickedRow >= 0 ? outline.clickedRow : outline.selectedRow
        guard let item = outline.item(atRow: row) as? BodyTreeItem, !item.isBucket else {
            return
        }
        let commands = [("Copy Value", #selector(copyValue(_:))), ("Copy Key", #selector(copyKey(_:))), ("Copy Path", #selector(copyPath(_:)))]
        for (title, action) in commands {
            if action == #selector(copyKey(_:)), key(of: item) == nil {
                continue
            }
            let menuItem = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            menuItem.target = self
            menuItem.representedObject = item
        }
    }

    @objc private func copyValue(_ sender: NSMenuItem) {
        (sender.representedObject as? BodyTreeItem).map { copyToPasteboard(value(of: $0)) }
    }

    @objc private func copyKey(_ sender: NSMenuItem) {
        (sender.representedObject as? BodyTreeItem).flatMap(key(of:)).map(copyToPasteboard)
    }

    @objc private func copyPath(_ sender: NSMenuItem) {
        (sender.representedObject as? BodyTreeItem).map { copyToPasteboard(path(of: $0)) }
    }

    func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// A tree pane: the in-place search above a `BodyTreeView` on the editors' surface.
struct BodyTreePane: View {
    let structure: BodyStructure
    @Bindable var search: BodySearchModel
    let controller: BodyTreeController
    let accessibilityLabel: String

    var body: some View {
        VStack(spacing: 6) {
            if search.isPresented {
                BodySearchBar(search: search)
            }
            BodyTreeView(
                structure: structure,
                currentMatch: search.isPresented ? search.currentTreeMatch : nil,
                controller: controller,
                accessibilityLabel: accessibilityLabel,
                onFind: { search.perform($0) }
            )
            .editorChrome()
        }
        .task(id: search.key(for: .tree(structure))) {
            await search.search(in: .tree(structure))
        }
    }
}

/// A row's cell: one truncating label, laid out by frame. Constraints per cell made expanding a large container
/// spend most of its time in the layout engine.
private final class BodyTreeCell: NSTableCellView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let field = NSTextField(labelWithString: "")
        field.lineBreakMode = .byTruncatingTail
        field.cell?.usesSingleLineMode = true
        addSubview(field)
        textField = field
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        guard let field = textField else {
            return
        }
        let height = field.intrinsicContentSize.height
        field.frame = NSRect(x: 2, y: ((bounds.height - height) / 2).rounded(), width: max(bounds.width - 6, 0), height: height)
    }
}
