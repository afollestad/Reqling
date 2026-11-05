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

        XCTAssertEqual(MainToolbarSpacerPlacement.flexibleSpaceIndex(in: identifiers), 3)
    }

    func testLeavesASpacerAlreadyInPlace() {
        XCTAssertNil(MainToolbarSpacerPlacement.flexibleSpaceIndex(in: [.flexibleSpace, sidebarToggle, title, .flexibleSpace, trailing]))
    }

    func testNeedsBothAppItems() {
        XCTAssertNil(MainToolbarSpacerPlacement.flexibleSpaceIndex(in: [.flexibleSpace, sidebarToggle, title]))
        XCTAssertNil(MainToolbarSpacerPlacement.flexibleSpaceIndex(in: [.flexibleSpace, sidebarToggle, trailing]))
    }

    func testSpacesThePickerFromTheButtonsAfterItOnce() {
        let settings = NSToolbarItem.Identifier(MainToolbarItemID.settings)

        XCTAssertEqual(MainToolbarSpacerPlacement.pickerSpaceIndex(in: [title, .flexibleSpace, trailing, settings]), 3)
        XCTAssertNil(MainToolbarSpacerPlacement.pickerSpaceIndex(in: [title, .flexibleSpace, trailing, .space, settings]))
        XCTAssertNil(MainToolbarSpacerPlacement.pickerSpaceIndex(in: [title, .flexibleSpace, trailing]))
        XCTAssertNil(MainToolbarSpacerPlacement.pickerSpaceIndex(in: [title, .flexibleSpace, settings]))
    }
}
