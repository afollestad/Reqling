import ReqlingKit
import SwiftUI
import XCTest

@testable import Reqling

extension SnapshotTests {
    func testSidebar() throws {
        // Unselected: List's vibrant selection highlight does not survive an offscreen capture.
        _ = try SnapshotProject.make(in: fixture)

        assertBothAppearances(SidebarView(model: fixture.model), size: CGSize(width: 280, height: 360))
    }

    func testSidebarFiltered() throws {
        _ = try SnapshotProject.make(in: fixture)
        fixture.model.sidebar.query = "users"
        fixture.model.sidebar.filter = RequestFilter(methods: [.get])

        assertBothAppearances(SidebarView(model: fixture.model), size: CGSize(width: 280, height: 300))
    }

    /// A folder renamed in place: the field boxes its name where the label was, and its count stays put.
    func testSidebarRenaming() throws {
        let project = try SnapshotProject.make(in: fixture)

        assertBothAppearances(sidebar(renaming: .node(project.id, project.folder)), size: CGSize(width: 280, height: 360))
    }

    func testSidebarEmpty() {
        assertBothAppearances(SidebarView(model: fixture.model), size: CGSize(width: 280, height: 360))
    }

    /// The sidebar's minimum width, where the actions stack instead of sharing a row.
    func testSidebarEmptyNarrow() {
        assertBothAppearances(SidebarView(model: fixture.model), size: CGSize(width: 220, height: 360))
    }

    /// Begins the rename for each appearance: closing one appearance's window ends it, as a row leaving the window does.
    private func sidebar(renaming item: SidebarItem) -> SidebarView {
        fixture.model.beginRename(item)
        return SidebarView(model: fixture.model)
    }
}
