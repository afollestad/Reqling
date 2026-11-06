import AppKit

/// Opening and closing rows: Expand All's budgeted walk, and the double-click that toggles one container.
extension BodyTreeCoordinator {
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

    /// The newest of a timeline's `messages` whose fields fit `BodyTreeView.openBudget` rows, in timeline order. A
    /// message too big for what is left stops the walk, so the open ones are always the newest run of them.
    func newestWithinOpenBudget(_ messages: [BodyTreeItem]) -> [BodyTreeItem] {
        var budget = BodyTreeView.openBudget
        var opening: [BodyTreeItem] = []
        for item in messages.reversed() where isExpandable(item) {
            let rows = displayChildren(of: item).count
            guard rows <= budget else {
                break
            }
            budget -= rows
            opening.append(item)
        }
        return opening.reversed()
    }

    /// Double-clicking a container's row, its `{ 3 keys }` included, opens or closes it as its disclosure triangle does.
    @objc func toggleClickedRow(_ sender: Any?) {
        guard let outline else {
            return
        }
        toggle(row: outline.clickedRow)
    }

    /// Opens or closes the container on `row`; a row without one, or no row (a double-click below the last), does
    /// nothing.
    func toggle(row: Int) {
        guard let outline, row >= 0, let item = outline.item(atRow: row) as? BodyTreeItem, isExpandable(item) else {
            return
        }
        if outline.isItemExpanded(item) {
            outline.collapseItem(item)
        } else {
            outline.expandOne(item)
        }
    }
}
