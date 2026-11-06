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
    /// A timeline scrolled to its end stays there as rows arrive; off while a search moves through its matches.
    var followsNewest = false
    /// A live timeline opens at its end and stays there through resizes, where `followsNewest` keeps it.
    var isLive = false
    /// Whether the outline is scrolled to its end, reported as it changes.
    var onScrolledToEndChange: ((Bool) -> Void)?

    /// How far a row's text starts inside its cell.
    static let cellTextInset: CGFloat = 2

    /// Expand All stops opening rows past this many, so a huge body never builds millions of rows; Option-clicking a
    /// disclosure triangle, which expands a whole subtree, stops at it too.
    static let expandBudget = 5_000

    /// A timeline's first show opens its newest messages only until their fields reach this many rows: opening thousands
    /// of messages at once built tens of thousands of rows, which stalled switching a long stream to Tree.
    static let openBudget = 2_000

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
        context.coordinator.observeScrolling(of: scrollView)
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
        outline.target = coordinator
        outline.doubleAction = #selector(BodyTreeCoordinator.toggleClickedRow(_:))
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
        coordinator.followsNewest = followsNewest
        coordinator.isLive = isLive
        coordinator.onScrolledToEndChange = onScrolledToEndChange
        coordinator.outline?.setAccessibilityLabel(accessibilityLabel)
        coordinator.show(structure)
        coordinator.reveal(currentMatch)
    }
}

/// How the section bar's Expand All and Collapse All, and a timeline's Jump to Bottom, reach the tree on screen.
@MainActor
final class BodyTreeController {
    weak var coordinator: BodyTreeCoordinator?

    func expandAll() {
        coordinator?.expand(from: nil, budget: BodyTreeView.expandBudget)
    }

    func collapseAll() {
        coordinator?.collapseAll()
    }

    func scrollToEnd() {
        coordinator?.scrollToEnd()
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
    var followsNewest = false
    var isLive = false
    var onScrolledToEndChange: ((Bool) -> Void)?
    /// What `onScrolledToEndChange` last heard, so it hears only changes.
    var reportedAtEnd: Bool?
    /// A start at the end still waiting for the scroll view to have a size to scroll within.
    var pendingScrollToEnd = false

    // MARK: - Content

    /// Shows `structure` with its top level open; the same structure again changes nothing.
    func show(_ structure: BodyStructure) {
        guard let outline else {
            return
        }
        if case .messages(let timeline) = structure, case .messages(let current) = self.structure, timeline.id == current.id {
            self.structure = structure
            updateMessages(timeline)
            return
        }
        guard structure.id != self.structure?.id else {
            return
        }
        self.structure = structure
        revealed = nil
        document = BodyTreeItem(node: .document, range: 0..<1, parentNode: nil)
        roots = displayChildren(of: document)
        rootCount = document.childNodes?.count ?? 0
        outline.reloadData()
        openSingleRoot()
        // Set either way, so an earlier start that never landed can't move a finished timeline.
        pendingScrollToEnd = isLive
        scrollToEndOnceSized()
        reportScrolledToEnd()
    }

    /// Opens the top-level value of a single document, and a timeline's messages or events, whose fields are what it is
    /// for (the newest, within `BodyTreeView.openBudget`); a sequence of documents starts closed.
    private func openSingleRoot() {
        if case .messages = structure {
            openMessages(newestWithinOpenBudget(roots))
        } else if rootCount == 1, let root = roots.first, isExpandable(root) {
            outline?.expandOne(root)
        }
    }

    private func openMessages(_ items: [BodyTreeItem]) {
        guard let outline else {
            return
        }
        // One batch: a timeline can hold thousands of entries.
        outline.beginUpdates()
        for item in items where isExpandable(item) {
            outline.expandOne(item)
        }
        outline.endUpdates()
    }

    /// Applies a newer update of the same timeline: adds its new rows and drops the trimmed ones, keeping the rest, and
    /// what is expanded in them, as they are.
    private func updateMessages(_ timeline: MessageTimeline) {
        guard let outline else {
            return
        }
        let follows = followsNewest && isScrolledToEnd(outline)
        var existing: [Int: BodyTreeItem] = [:]
        for item in roots {
            if case .message(let message) = item.node {
                existing[message.item.sequence] = item
            }
        }
        let kept = Set(timeline.messages.map(\.item.sequence))
        let removed = IndexSet(roots.indices.filter { index in
            guard case .message(let message) = roots[index].node else {
                return true
            }
            return !kept.contains(message.item.sequence)
        })
        var inserted = IndexSet()
        let items = timeline.messages.enumerated().map { position, message in
            if let item = existing[message.item.sequence] {
                item.range = position..<position + 1
                return item
            }
            inserted.insert(position)
            return BodyTreeItem(node: .message(message), range: position..<position + 1, parentNode: document)
        }
        document.childNodes = timeline.messages.map(BodyTreeItem.Node.message)
        document.displayChildren = items
        roots = items
        rootCount = items.count
        guard !removed.isEmpty || !inserted.isEmpty else {
            return
        }
        outline.beginUpdates()
        outline.removeItems(at: removed, inParent: nil, withAnimation: [])
        outline.insertItems(at: inserted, inParent: nil, withAnimation: [])
        outline.endUpdates()
        openMessages(inserted.map { items[$0] })
        // After opening the new rows, so their fields show too.
        if follows, !inserted.isEmpty {
            scrollToEnd(outline)
        }
        reportScrolledToEnd()
    }

    /// True for the top-level value of a single document, which reads as the whole document rather than an item.
    func isSingleRoot(_ item: BodyTreeItem) -> Bool {
        item.parentNode === document && rootCount == 1
    }

    func isExpandable(_ item: BodyTreeItem) -> Bool {
        switch item.node {
        case nil, .document:
            true
        case .json(let entry, _):
            entry.childCount > 0
        case .message(let message):
            !message.fields.isEmpty
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
        // A timeline's messages stay one flat list, which streaming updates insert into and trim in place.
        let children: [BodyTreeItem]
        if case .document = item.node, case .messages = structure, let nodes = owner.childNodes {
            children = range.map { BodyTreeItem(node: nodes[$0], range: $0..<$0 + 1, parentNode: owner) }
        } else {
            children = BodyTreeItem.level(of: owner, range: range)
        }
        item.displayChildren = children
        return children
    }

    private func loadChildren(of item: BodyTreeItem) -> [BodyTreeItem.Node] {
        switch (item.node, structure) {
        case (.document, .json(let index)):
            index.rootEntries().map { .json($0, index) }
        case (.document, .xml(let index)):
            index.roots.map(BodyTreeItem.Node.xml)
        case (.document, .messages(let timeline)):
            timeline.messages.map(BodyTreeItem.Node.message)
        case (.json(let entry, let index), _):
            entry.container.map { index.children(of: $0).map { .json($0, index) } } ?? []
        case (.message(let message), _):
            message.index.map { index in message.fields.map { .json($0, index) } } ?? []
        case (.xml(let node), .xml(let index)):
            index.children(of: node).map(BodyTreeItem.Node.xml)
        default:
            []
        }
    }

    // MARK: - Collapsing and revealing

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

/// Expand All and Collapse All, for Tree mode; the gRPC Messages tab shows them too.
struct BodyTreeControls: View {
    let controller: BodyTreeController

    var body: some View {
        HStack(spacing: 2) {
            Button {
                controller.expandAll()
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
            }
            .help("Expand all")
            .accessibilityLabel("Expand all")
            Button {
                controller.collapseAll()
            } label: {
                Image(systemName: "arrow.down.right.and.arrow.up.left")
            }
            .help("Collapse all")
            .accessibilityLabel("Collapse all")
        }
        .buttonStyle(IconButtonStyle())
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
        let inset = BodyTreeView.cellTextInset
        field.frame = NSRect(x: inset, y: ((bounds.height - height) / 2).rounded(), width: max(bounds.width - inset - 4, 0), height: height)
    }
}
