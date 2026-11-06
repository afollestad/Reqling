import AppKit

/// Following a live timeline: while its outline is scrolled to the end, `updateMessages` keeps it there as rows
/// arrive, the way the Text timeline does, and `onScrolledToEndChange` tells the timeline when it isn't, for its Jump
/// to Bottom.
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

    /// Jump to Bottom: the newest row, where the next update follows on.
    func scrollToEnd() {
        if let outline {
            scrollToEnd(outline)
        }
    }

    /// Reports each scroll and resize of `scrollView`, and keeps a live timeline at its end through a resize. A selector
    /// observer, which the notification center drops when the coordinator goes.
    func observeScrolling(of scrollView: NSScrollView) {
        let clip = scrollView.contentView
        clip.postsBoundsChangedNotifications = true
        clip.postsFrameChangedNotifications = true
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(clipViewDidChange(_:)), name: NSView.boundsDidChangeNotification, object: clip)
        center.addObserver(self, selector: #selector(clipViewDidChange(_:)), name: NSView.frameDidChangeNotification, object: clip)
    }

    @objc private func clipViewDidChange(_ notification: Notification) {
        scrollToEndOnceSized()
        // A resize keeps a live timeline that was at its end there: only scrolling away pauses following.
        if notification.name == NSView.frameDidChangeNotification, isLive, reportedAtEnd == true, let outline, !isScrolledToEnd(outline) {
            scrollToEnd(outline)
        }
        reportScrolledToEnd()
    }

    /// A tree shown before its pane is laid out has nothing to scroll within yet, so the start at the end waits for
    /// the clip view's first size.
    func scrollToEndOnceSized() {
        guard pendingScrollToEnd, let outline, let clip = outline.enclosingScrollView?.contentView, clip.bounds.height > 0 else {
            return
        }
        pendingScrollToEnd = false
        scrollToEnd(outline)
    }

    /// Tells `onScrolledToEndChange` whether the outline is at its end, when that changed. Not before the pane has a size
    /// and any start at the end has landed: an unsized tree reads as scrolled away, so Jump to Bottom would flash.
    /// Asynchronously: a scroll can land inside the SwiftUI update that moved the outline, where changing the view's
    /// state is not allowed.
    func reportScrolledToEnd() {
        guard let outline, let report = onScrolledToEndChange, !pendingScrollToEnd,
              let clip = outline.enclosingScrollView?.contentView, clip.bounds.height > 0 else {
            return
        }
        let isAtEnd = isScrolledToEnd(outline)
        guard isAtEnd != reportedAtEnd else {
            return
        }
        reportedAtEnd = isAtEnd
        DispatchQueue.main.async {
            report(isAtEnd)
        }
    }
}
