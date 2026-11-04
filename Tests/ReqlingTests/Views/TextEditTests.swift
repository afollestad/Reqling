import Foundation
import XCTest

@testable import Reqling

final class TextEditTests: XCTestCase {
    func testReplacesOnlyTheSpanThatDiffers() {
        let edit = TextEdit.minimal(from: "hello world", to: "hello there world")

        XCTAssertEqual(edit, TextEdit(range: NSRange(location: 6, length: 0), replacement: "there "))
    }

    func testNeverSplitsAComposedCharacter() {
        let edit = TextEdit.minimal(from: "a😀b", to: "a😁b")

        XCTAssertEqual(edit, TextEdit(range: NSRange(location: 1, length: 2), replacement: "😁"))
    }

    func testMapsASelectionAroundTheSpan() {
        let edit = TextEdit(range: NSRange(location: 4, length: 2), replacement: "xyz")

        XCTAssertEqual(edit.mapping(NSRange(location: 1, length: 3)), NSRange(location: 1, length: 3))
        XCTAssertEqual(edit.mapping(NSRange(location: 7, length: 1)), NSRange(location: 8, length: 1))
        XCTAssertEqual(edit.mapping(NSRange(location: 5, length: 0)), NSRange(location: 7, length: 0))
    }
}
