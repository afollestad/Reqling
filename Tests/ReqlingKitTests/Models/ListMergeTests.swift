import ReqlingKit
import XCTest

final class ListMergeTests: XCTestCase {
    func testARowTheDraftLeftAloneTakesTheStoredVersionIncludingItsRemoval() {
        let merged = merge(base: ["a", "b", "c"], draft: ["a:draft", "b", "c"], stored: ["a", "b:stored"])

        XCTAssertEqual(merged, ["a:draft", "b:stored"])
    }

    func testAnEditBeatsARemovalElsewhereAndARemovalBeatsAnEditElsewhere() {
        XCTAssertEqual(merge(base: ["a", "b"], draft: ["a", "b:draft"], stored: ["a"]), ["a", "b:draft"])
        XCTAssertEqual(merge(base: ["a", "b"], draft: ["a"], stored: ["a", "b:stored"]), ["a"])
    }

    func testWhenBothSidesEditARowTheDraftsVersionWins() {
        XCTAssertEqual(merge(base: ["a", "b"], draft: ["a:draft", "b"], stored: ["a:stored", "b"]), ["a:draft", "b"])
    }

    func testRowsAddedElsewhereFollowTheirStoredPredecessorAndDraftRowsTheirDraftPredecessor() {
        let merged = merge(base: ["a", "b"], draft: ["a:draft", "b", "d"], stored: ["x", "a", "y", "b", "z"])

        XCTAssertEqual(merged, ["x", "a:draft", "y", "b", "d", "z"])
    }

    func testARowAddedOnBothSidesUnderOneIDIsKeptOnceAsTheDrafts() {
        XCTAssertEqual(merge(base: ["a"], draft: ["a", "n:draft"], stored: ["n:stored", "a"]), ["n:draft", "a"])
    }

    func testTheDraftsReorderWins() {
        let merged = merge(base: ["a", "b", "c"], draft: ["c", "a", "b"], stored: ["a", "x", "b", "c:stored"])

        XCTAssertEqual(merged, ["c:stored", "a", "x", "b"], "the draft's order, a stored edit to a row it only moved, and x after a")
    }

    func testAReorderElsewhereSurvivesADraftThatOnlyEdited() {
        XCTAssertEqual(merge(base: ["a", "b", "c"], draft: ["a", "b:draft", "c"], stored: ["c", "a", "b"]), ["c", "a", "b:draft"])
    }

    func testEmptyListsOnEitherSide() {
        XCTAssertEqual(merge(base: [], draft: [], stored: ["x"]), ["x"])
        XCTAssertEqual(merge(base: ["a"], draft: [], stored: ["a", "x"]), ["x"])
        XCTAssertEqual(merge(base: ["a"], draft: ["a:draft"], stored: []), ["a:draft"])
        XCTAssertEqual(merge(base: [], draft: ["n"], stored: []), ["n"])
    }

    func testUnchangedStoredRowsKeepTheDraftExactly() {
        XCTAssertEqual(merge(base: ["a", "b"], draft: ["b", "n", "a:draft"], stored: ["a", "b"]), ["b", "n", "a:draft"])
    }

    /// Rows that cannot be told apart merge as one field.
    func testARepeatedIDMakesTheListOneField() {
        XCTAssertEqual(merge(base: ["a", "a"], draft: ["a", "a:draft"], stored: ["b"]), ["a", "a:draft"])
        XCTAssertEqual(merge(base: ["a", "a"], draft: ["a", "a"], stored: ["b"]), ["b"])
        XCTAssertEqual(merge(base: ["a"], draft: ["a:draft"], stored: ["b", "b"]), ["a:draft"])
    }

    func testCallersDecideWhatCountsAsAnEditAndHowBothSidesCombine() {
        let base = rows(["a", "b"])
        let merged = ListMerge.merge(
            base: base,
            draft: base,
            stored: rows(["a:stored"]),
            isEdited: { $1.id == "b" || $0 != $1 },
            mergeEdited: { _, draft, stored in Row(id: draft.id, value: "\(draft.value)+\(stored.value)") }
        )

        XCTAssertEqual(merged.map(\.label), ["a:stored", "b"], "b counts as edited, so its removal elsewhere loses")

        let combined = ListMerge.merge(
            base: base,
            draft: rows(["a:draft", "b"]),
            stored: rows(["a:stored", "b"]),
            mergeEdited: { _, draft, stored in Row(id: draft.id, value: "\(draft.value)+\(stored.value)") }
        )
        XCTAssertEqual(combined.map(\.label), ["a:draft+stored", "b"])
    }

    // MARK: - Support

    /// Rows written `id` or `id:value`, so a list reads as its IDs and which side last changed each row.
    private func merge(base: [String], draft: [String], stored: [String]) -> [String] {
        ListMerge.merge(base: rows(base), draft: rows(draft), stored: rows(stored)).map(\.label)
    }

    private func rows(_ labels: [String]) -> [Row] {
        labels.map { label in
            let parts = label.split(separator: ":", maxSplits: 1).map(String.init)
            return Row(id: parts[0], value: parts.count > 1 ? parts[1] : "")
        }
    }
}

private struct Row: Identifiable, Equatable {
    let id: String
    var value: String

    var label: String {
        value.isEmpty ? id : "\(id):\(value)"
    }
}
