import AppKit
import ReqlingKit

/// Where Share… or Manage Sharing… was chosen, so the share sheet opens beside it: a project's sidebar row, whose
/// context menu has no view of its own, or the Share button on its page.
enum ShareOrigin: Hashable {
    case sidebar(ProjectID)
    case details(ProjectID)

    var project: ProjectID {
        switch self {
        case .sidebar(let id), .details(let id):
            id
        }
    }

    /// Beside a row, into the window; below a button.
    var edge: NSRectEdge {
        switch self {
        case .sidebar:
            .maxX
        case .details:
            .minY
        }
    }
}

/// The views the share sheet opens beside, by where Share… was chosen; kept weakly, since SwiftUI owns them.
@MainActor
final class ShareAnchors {
    private final class WeakView {
        weak var view: NSView?

        init(_ view: NSView) {
            self.view = view
        }
    }

    private var views: [ShareOrigin: WeakView] = [:]

    /// A row's view, reused for another project as the sidebar scrolls, stops standing for the one it showed before.
    func register(_ view: NSView, as origin: ShareOrigin) {
        views = views.filter { $0.value.view != nil && $0.value.view !== view }
        views[origin] = WeakView(view)
    }

    /// Beside `origin`'s view while it's on screen, or else its project's sidebar row, as when the page scrolled its
    /// button away; `nil` when neither is.
    func anchor(for origin: ShareOrigin) -> SharingAnchor? {
        for candidate in [origin, .sidebar(origin.project)] {
            if let view = views[candidate]?.view, view.window != nil, !view.isHiddenOrHasHiddenAncestor {
                return SharingAnchor(view: view, edge: candidate.edge)
            }
        }
        return nil
    }
}
