import AppKit
import SwiftUI

/// Where the sidebar's `List` sits in AppKit, asked when it matters rather than mirrored in state: whether it is on
/// screen, since `NavigationSplitView` hides a collapsed column instead of removing it, and its scroll view and table,
/// which the drag scrolls and a row's click gives the keyboard.
@MainActor
final class SidebarListHost {
    /// A view filling the list's frame, behind it.
    weak var view: NSView?
    private weak var resolvedScrollView: NSScrollView?

    var isOnScreen: Bool {
        guard let view else {
            return false
        }
        return view.window != nil && !view.isHiddenOrHasHiddenAncestor
    }

    var scrollView: NSScrollView? {
        if let resolvedScrollView, resolvedScrollView.window != nil, resolvedScrollView.window === view?.window {
            return resolvedScrollView
        }
        resolvedScrollView = overlappingScrollView()
        return resolvedScrollView
    }

    var tableView: NSTableView? {
        guard let scrollView else {
            return nil
        }
        return scrollView.documentView as? NSTableView ?? scrollView.descendants(of: NSTableView.self).first
    }

    /// Gives the table the keyboard, where the row's keys (`SidebarRowKeyMonitor`) and the table's ↑ and ↓ act.
    func focusTable() {
        guard let table = tableView, let window = table.window, window.firstResponder !== table else {
            return
        }
        window.makeFirstResponder(table)
    }

    /// The list's scroll view. SwiftUI puts this view beside the list, not inside it, so it is found as the scroll view
    /// covering the most of this view's frame, the smaller of two that cover as much.
    private func overlappingScrollView() -> NSScrollView? {
        guard let view, let contentView = view.window?.contentView else {
            return nil
        }
        let frame = view.convert(view.bounds, to: nil)
        guard !frame.isEmpty else {
            return nil
        }
        func area(_ rect: NSRect) -> CGFloat {
            rect.isEmpty ? 0 : rect.width * rect.height
        }
        return contentView.descendants(of: NSScrollView.self)
            .filter { $0.documentView != nil && $0.convert($0.bounds, to: nil).intersects(frame) }
            .max { lhs, rhs in
                let lhsFrame = lhs.convert(lhs.bounds, to: nil)
                let rhsFrame = rhs.convert(rhs.bounds, to: nil)
                let lhsArea = area(lhsFrame.intersection(frame))
                let rhsArea = area(rhsFrame.intersection(frame))
                return lhsArea != rhsArea ? lhsArea < rhsArea : area(lhsFrame) > area(rhsFrame)
            }
    }
}

struct SidebarListHostReader: NSViewRepresentable {
    let host: SidebarListHost

    func makeNSView(context: Context) -> SidebarListHostView {
        let view = SidebarListHostView()
        host.view = view
        return view
    }

    func updateNSView(_ view: SidebarListHostView, context: Context) {
        host.view = view
    }
}

final class SidebarListHostView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Clicks go to the list as before.
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

private extension NSView {
    func descendants<View: NSView>(of type: View.Type) -> [View] {
        subviews.flatMap { subview in
            ((subview as? View).map { [$0] } ?? []) + subview.descendants(of: type)
        }
    }
}
