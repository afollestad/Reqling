import XCTest

@testable import Reqling

/// What `SecondsField` stores from typing and from its arrows.
final class SecondsFieldTests: XCTestCase {
    private let range: ClosedRange<Double> = 1...600

    func testTypedValuesAreHeldToTheRangeAndClearingGoesBackToTheDefault() {
        XCTAssertEqual(SecondsField.typed(45, in: range), 45)
        XCTAssertEqual(SecondsField.typed(2.5, in: range), 2.5, "Fractions are kept")
        XCTAssertEqual(SecondsField.typed(-3, in: range), 1)
        XCTAssertEqual(SecondsField.typed(0, in: range), 1)
        XCTAssertEqual(SecondsField.typed(9_000, in: range), 600)
        XCTAssertEqual(SecondsField.typed(.infinity, in: range), 600)
        XCTAssertNil(SecondsField.typed(nil, in: range))
        XCTAssertNil(SecondsField.typed(.nan, in: range), "A project file can't store it")
    }

    func testEitherArrowOnAnEmptyFieldGivesTheStartAndThenStepsFromIt() {
        XCTAssertEqual(SecondsField.stepped(from: nil, to: 35, start: 30, in: range), 30)
        XCTAssertEqual(SecondsField.stepped(from: nil, to: 25, start: 30, in: range), 30)
        XCTAssertEqual(SecondsField.stepped(from: 30, to: 35, start: 30, in: range), 35)
        XCTAssertEqual(SecondsField.stepped(from: nil, to: 1, start: 900, in: range), 600, "A start outside the range is held to it")
    }
}
