import AppKit
import XCTest

@testable import Reqling

final class MainToolbarSpacerPlacementTests: XCTestCase {
    private let sidebarToggle = NSToolbarItem.Identifier("com.apple.SwiftUI.navigationSplitView.toggleSidebar")
    private let title = NSToolbarItem.Identifier(MainToolbarItemID.title)
    private let trailing = NSToolbarItem.Identifier(MainToolbarItemID.trailing)

    /// The order `NavigationSplitView` builds: its own spacer holds the sidebar toggle at the sidebar's edge and stays.
    func testInsertsASpacerBeforeTheTrailingItemsAndLeavesTheSidebarsOwn() {
        let identifiers: [NSToolbarItem.Identifier] = [.flexibleSpace, sidebarToggle, title, trailing, .init(MainToolbarItemID.settings)]

        XCTAssertEqual(MainToolbarSpacerPlacement.insertionIndex(in: identifiers), 3)
    }

    func testLeavesASpacerAlreadyInPlace() {
        XCTAssertNil(MainToolbarSpacerPlacement.insertionIndex(in: [.flexibleSpace, sidebarToggle, title, .flexibleSpace, trailing]))
    }

    func testNeedsBothAppItems() {
        XCTAssertNil(MainToolbarSpacerPlacement.insertionIndex(in: [.flexibleSpace, sidebarToggle, title]))
        XCTAssertNil(MainToolbarSpacerPlacement.insertionIndex(in: [.flexibleSpace, sidebarToggle, trailing]))
    }
}
