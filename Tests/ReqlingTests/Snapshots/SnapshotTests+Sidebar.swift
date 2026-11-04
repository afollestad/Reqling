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

    func testSidebarEmpty() {
        assertBothAppearances(SidebarView(model: fixture.model), size: CGSize(width: 280, height: 360))
    }

    /// The sidebar's minimum width, where the actions stack instead of sharing a row.
    func testSidebarEmptyNarrow() {
        assertBothAppearances(SidebarView(model: fixture.model), size: CGSize(width: 220, height: 360))
    }
}
