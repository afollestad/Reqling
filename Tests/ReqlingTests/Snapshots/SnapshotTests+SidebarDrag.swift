import ReqlingKit
import SwiftUI
import XCTest

@testable import Reqling

/// The sidebar mid-drag, started at a pointer since a snapshot can't move a mouse. Rows sit 32pt apart from List users'
/// at 112pt, as `testSidebar` lays them out.
extension SnapshotTests {
    /// A dragged folder fades with its contents, and the accent line marks the place above List users.
    func testSidebarDraggingAFolderShowsTheLine() throws {
        let project = try SnapshotProject.make(in: fixture)

        assertBothAppearances(
            sidebar(dragging: .node(project.id, project.folder), at: CGPoint(x: 140, y: 118)),
            size: CGSize(width: 280, height: 360)
        )
    }

    /// Over a folder, the drop goes into it, and the border wraps it and its open contents.
    func testSidebarDraggingIntoAFolderShowsItsBorder() throws {
        let project = try SnapshotProject.make(in: fixture)

        assertBothAppearances(
            sidebar(dragging: .node(project.id, project.listUsers), at: CGPoint(x: 140, y: 196)),
            size: CGSize(width: 280, height: 360)
        )
    }

    private func sidebar(dragging item: SidebarItem, at pointer: CGPoint) -> SidebarView {
        let system = SidebarDragSystem(sleep: { _ in }, isEscapePressed: { false }, isPointerDown: { true })
        let drag = SidebarDragController(model: fixture.model, system: system, initialDrag: (item, pointer))
        drag.reducesMotion = true
        return SidebarView(model: fixture.model, drag: drag)
    }
}
