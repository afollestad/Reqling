import SwiftUI

/// What the sidebar list publishes for dragging, on every layout pass: each mounted row's frame, the list's frame, and
/// the part of it not under the filter bar or footer.
///
/// All in `.global`, the window's coordinates. A space named outside the `List` can't reach its rows, each hosted in a
/// cell of its own, where `.named` quietly falls back to `.global`; so everything uses that one, and only drawing converts
/// out of it (`SidebarDragOverlay`).
struct SidebarDragGeometry: Equatable {
    var rows: [SidebarItem: CGRect] = [:]
    var list: CGRect?
    var visible: CGRect?
}

struct SidebarDragGeometryKey: PreferenceKey {
    static let defaultValue = SidebarDragGeometry()

    static func reduce(value: inout SidebarDragGeometry, nextValue: () -> SidebarDragGeometry) {
        let next = nextValue()
        value.rows.merge(next.rows) { $1 }
        value.list = next.list ?? value.list
        value.visible = next.visible ?? value.visible
    }
}

extension View {
    /// Publishes this row's frame, measured outside its indent, so every folder's and request's frame starts where a
    /// top-level one's content does and the drag can indent its line by level from there.
    func sidebarDragGeometry(_ item: SidebarItem) -> some View {
        background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: SidebarDragGeometryKey.self,
                    value: SidebarDragGeometry(rows: [item: proxy.frame(in: .global)])
                )
            }
        }
    }

    /// Makes the row a drag source once the pointer moves 3pt, handing the drag to `SidebarDragController`.
    ///
    /// Applied after the row's `sidebarRowClick`, so it wraps that click, as Alveary's sources wrap theirs: Alveary found
    /// a zero-distance gesture beside this one wins outright, and no drag starts. Always applied, with its gesture masked
    /// off when disabled, so turning it on and off never changes the row's identity, which would make the list animate
    /// the row out and back in.
    func sidebarDragSource(_ item: SidebarItem, drag: SidebarDragController, isEnabled: Bool) -> some View {
        highPriorityGesture(
            DragGesture(minimumDistance: 3)
                .onChanged { _ in drag.sourceChanged(item) }
                .onEnded { _ in drag.sourceEnded(item) },
            including: isEnabled && drag.isSourceEnabled(item) ? .all : .subviews
        )
    }

    /// Fades a dragged row in place, as Alveary does, rather than lifting an image of it.
    func sidebarDragFade(_ item: SidebarItem, drag: SidebarDragController) -> some View {
        let isDragged = drag.isDragged(item)
        return opacity(isDragged ? 0.48 : 1)
            .animation(drag.animation, value: isDragged)
    }
}

/// Publishes one of the list's two frames for the drag, read from where it sits rather than worked out from safe-area
/// insets, which a reader reports inconsistently for a list scrolling under bars.
struct SidebarListGeometryReader: View {
    enum Role {
        /// The whole list, under the filter bar and footer too: read inside the overlay that ignores the safe area,
        /// whose coordinates the event monitor's are.
        case list
        /// What the filter bar and footer leave of it: read inside an overlay that keeps to the safe area.
        case visible
    }

    let role: Role

    var body: some View {
        GeometryReader { proxy in
            let frame = proxy.frame(in: .global)
            Color.clear.preference(
                key: SidebarDragGeometryKey.self,
                value: role == .list ? SidebarDragGeometry(list: frame) : SidebarDragGeometry(visible: frame)
            )
        }
    }
}
