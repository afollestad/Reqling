import XCTest

@testable import Reqling

final class SearchablePickerFilterTests: XCTestCase {
    private let methods = ["ListUsersPaged", "GetUser", "ListUsers"]

    func testABlankQueryShowsEverythingAndStartsAtTheSelection() {
        XCTAssertEqual(SearchablePickerFilter.matches(methods, query: " "), [0, 1, 2])
        XCTAssertEqual(SearchablePickerFilter.preferred(in: methods, query: "", selection: "GetUser"), 1)
        XCTAssertEqual(SearchablePickerFilter.preferred(in: methods, query: "", selection: ""), 0)
    }

    /// Typing a whole name picks it, even when a longer one containing it is declared first.
    func testAnExactMatchBeatsAnEarlierSubstringMatch() {
        let matches = SearchablePickerFilter.matches(methods, query: "listusers")
        XCTAssertEqual(matches, [0, 2])

        let labels = matches.map { methods[$0] }
        XCTAssertEqual(SearchablePickerFilter.preferred(in: labels, query: "listusers", selection: "GetUser"), 1)
        XCTAssertEqual(SearchablePickerFilter.preferred(in: labels, query: "List", selection: ""), 0)
    }

    func testArrowKeysStopAtEitherEnd() {
        XCTAssertEqual(SearchablePickerFilter.moved(0, by: -1, count: 3), 0)
        XCTAssertEqual(SearchablePickerFilter.moved(1, by: 1, count: 3), 2)
        XCTAssertEqual(SearchablePickerFilter.moved(2, by: 1, count: 3), 2)
        XCTAssertEqual(SearchablePickerFilter.moved(0, by: 1, count: 0), 0)
    }
}
