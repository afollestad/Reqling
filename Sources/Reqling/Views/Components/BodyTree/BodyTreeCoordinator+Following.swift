import AppKit

/// Following a live timeline: while its outline is scrolled to the end, `updateMessages` keeps it there as rows
/// arrive, the way the Text timeline does.
extension BodyTreeCoordinator {
    /// Within a row of the end, so a few points short of it still counts; a tree shorter than its pane is at its end.
    func isScrolledToEnd(_ outline: NSOutlineView) -> Bool {
        guard let clip = outline.enclosingScrollView?.contentView else {
            return false
        }
        return clip.bounds.maxY >= outline.bounds.height - outline.rowHeight
    }

    func scrollToEnd(_ outline: NSOutlineView) {
        let last = outline.numberOfRows - 1
        if last >= 0 {
            outline.scrollRowToVisible(last)
        }
    }
}
