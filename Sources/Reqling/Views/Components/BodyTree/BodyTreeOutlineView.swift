import AppKit

/// The tree's outline: Option-clicking a disclosure triangle expands only up to `BodyTreeView.expandBudget` rows, ⌘C
/// copies the selected value, and the Find menu reaches the tree's search.
final class BodyTreeOutlineView: NSOutlineView, InPlaceFindTarget {
    weak var coordinator: BodyTreeCoordinator?
    var onFind: ((NSTextFinder.Action) -> Void)?

    /// AppKit's recursive expand would build every row of a huge body; within the budget, the coordinator walks it.
    override func expandItem(_ item: Any?, expandChildren: Bool) {
        guard expandChildren, let coordinator else {
            super.expandItem(item, expandChildren: expandChildren)
            return
        }
        coordinator.expand(from: item as? BodyTreeItem, budget: numberOfRows + BodyTreeView.expandBudget)
    }

    /// Moves each disclosure triangle right by half the gap between it and its row's text, so the top level's isn't
    /// pressed against the pane's edge; the text stays put, so leaves still line up with their siblings. The glyph is
    /// centered in a frame much wider than it, so the gap is measured from the frame's middle less half a glyph.
    override func frameOfOutlineCell(atRow row: Int) -> NSRect {
        var frame = super.frameOfOutlineCell(atRow: row)
        guard !frame.isEmpty else {
            return frame
        }
        let textStart = super.frameOfCell(atColumn: 0, row: row).minX + BodyTreeView.cellTextInset
        let gap = textStart - frame.midX - Self.disclosureGlyphHalfWidth
        if gap > 0 {
            frame.origin.x += (gap / 2).rounded()
        }
        return frame
    }

    /// About half the width of the system's disclosure chevron, which is 5 to 8 points wide depending on direction.
    private static let disclosureGlyphHalfWidth: CGFloat = 3

    /// Expands one item, without the budgeted walk.
    func expandOne(_ item: BodyTreeItem) {
        super.expandItem(item, expandChildren: false)
    }

    func performFind(_ action: NSTextFinder.Action) {
        onFind?(action)
    }

    @objc func copy(_ sender: Any?) {
        guard let coordinator, let item = item(atRow: selectedRow) as? BodyTreeItem, !item.isBucket else {
            NSSound.beep()
            return
        }
        coordinator.copyToPasteboard(coordinator.value(of: item))
    }
}

/// Draws the selection as a tint of `appAccent` and keeps the cell's syntax colors as they are, which a solid
/// selection, and the emphasized style AppKit gives cells on one, would wash out.
final class BodyTreeRowView: NSTableRowView {
    var accent: NSColor = .controlAccentColor

    override var interiorBackgroundStyle: NSView.BackgroundStyle {
        .normal
    }

    override func drawSelection(in dirtyRect: NSRect) {
        let color = isEmphasized ? accent.withAlphaComponent(0.25) : NSColor.unemphasizedSelectedContentBackgroundColor
        color.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 1), xRadius: AppMetrics.badgeCornerRadius, yRadius: AppMetrics.badgeCornerRadius).fill()
    }
}
