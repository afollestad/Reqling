import ReqlingKit
import XCTest

@testable import Reqling

@MainActor
final class CheckboxRangeTests: XCTestCase {
    // XCTest makes a fresh instance per test, so these start over each time.
    private var rows = (0..<6).map { KeyValuePair(key: "k\($0)", value: "", isEnabled: false) }
    private var range = CheckboxRange<KeyValuePairID>()

    func testAPlainClickSetsOnlyItsRowAndBecomesTheAnchor() {
        click(2, to: true)

        XCTAssertEqual(enabled, [2])
        XCTAssertEqual(range.anchor, rows[2].id)
    }

    func testAShiftClickSetsEveryRowFromTheAnchorInEitherDirection() {
        click(1, to: true)
        click(4, to: true, extending: true)
        XCTAssertEqual(enabled, [1, 2, 3, 4])

        click(2, to: false, extending: true)
        XCTAssertEqual(enabled, [1], "the range takes the clicked box's state, switching on rows off too")
    }

    func testShiftClicksChainFromTheLastClickedRow() {
        click(0, to: true)
        click(2, to: true, extending: true)
        click(5, to: true, extending: true)

        XCTAssertEqual(enabled, [0, 1, 2, 3, 4, 5])
        XCTAssertEqual(range.anchor, rows[5].id)
    }

    func testAShiftClickWithoutAnAnchorSetsOnlyItsRow() {
        click(3, to: true, extending: true)

        XCTAssertEqual(enabled, [3])
    }

    func testAShiftClickWhoseAnchorWasRemovedSetsOnlyItsRow() {
        click(1, to: true)
        rows.remove(at: 1)

        click(3, to: true, extending: true)

        XCTAssertEqual(enabled, [3])
    }

    func testAnIDOutsideTheRowsChangesNothingAndKeepsTheAnchor() {
        click(1, to: true)
        let draftID = KeyValuePairID()

        range.set(\.isEnabled, to: true, at: draftID, extending: true, in: &rows)

        XCTAssertEqual(enabled, [1])
        XCTAssertEqual(range.anchor, rows[1].id)
    }

    private var enabled: [Int] {
        rows.indices.filter { rows[$0].isEnabled }
    }

    private func click(_ index: Int, to isOn: Bool, extending: Bool = false) {
        range.set(\.isEnabled, to: isOn, at: rows[index].id, extending: extending, in: &rows)
    }
}
