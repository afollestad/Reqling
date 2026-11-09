import CoreGraphics
import Foundation
import ReqlingKit

/// A sidebar drag's lifecycle, after Alveary's: a session from the moment a row's drag passes its threshold until the
/// mouse comes up, and after Escape a latch that holds until then too, so that release clicks nothing beneath it.
enum SidebarDragState: Equatable {
    case idle
    case active(SidebarDragSession)
    case cancelledUntilMouseUp(UUID)

    var session: SidebarDragSession? {
        if case .active(let session) = self {
            return session
        }
        return nil
    }
}

/// One drag. The pointer and the drop frozen at mouse-up live in a reference, so moving the pointer publishes nothing:
/// every row observes the state, which may only change as a drag starts and ends.
struct SidebarDragSession: Equatable {
    let id: UUID
    let source: SidebarItem
    /// The dragged node and everything inside it (`SidebarDragLayout.sourceNodes`).
    let sourceNodes: Set<RequestNodeID>
    private let context = Context()

    init(id: UUID = UUID(), source: SidebarItem, sourceNodes: Set<RequestNodeID>, location: CGPoint? = nil) {
        self.id = id
        self.source = source
        self.sourceNodes = sourceNodes
        context.location = location
    }

    /// The pointer in the window's coordinates, once the event monitor has seen it.
    var location: CGPoint? {
        get { context.location }
        nonmutating set { context.location = newValue }
    }

    /// Whether the drop was frozen, which happens once: at the mouse-up the monitor sees, or as the drag finishes.
    var isFrozen: Bool {
        context.isFrozen
    }

    var frozenCandidate: SidebarDropCandidate? {
        context.frozenCandidate
    }

    func freeze(_ candidate: SidebarDropCandidate?) {
        guard !context.isFrozen else {
            return
        }
        context.isFrozen = true
        context.frozenCandidate = candidate
    }

    func isDragged(_ item: SidebarItem) -> Bool {
        SidebarDragLayout.isDragged(item, source: source, sourceNodes: sourceNodes)
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.source == rhs.source
    }

    private final class Context {
        var location: CGPoint?
        var isFrozen = false
        var frozenCandidate: SidebarDropCandidate?
    }
}
