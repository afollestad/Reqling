import SwiftUI

enum SidebarRowClick {
    /// How far the pointer may move between press and release for it to stay a click.
    static let slop: CGFloat = 10
}

extension View {
    /// The row's click, which it takes for itself rather than leaving to the list's table.
    ///
    /// The table can't have the press: `NSHostingView` passes a press no SwiftUI gesture claims at once to
    /// `-[NSTableView mouseDown:]`, whose tracking loop then swallows every later drag event and the mouse-up, so the
    /// row's drag (`sidebarDragSource`) would get one update and no end. A zero-distance drag claims the press as it
    /// happens, and unlike a tap gesture it still ends however long the press is held. So a row is selected as the
    /// mouse comes up, and `SidebarDragController.click(_:)` gives the table the keyboard the table's own click did.
    ///
    /// Pass `isEnabled: false` while a drag is under way, so the release that ends it doesn't click the row beneath.
    func sidebarRowClick(isEnabled: Bool, action: @escaping @MainActor () -> Void) -> some View {
        contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onEnded { value in
                        guard abs(value.translation.width) < SidebarRowClick.slop, abs(value.translation.height) < SidebarRowClick.slop else {
                            return
                        }
                        action()
                    },
                including: isEnabled ? .all : .subviews
            )
    }
}
