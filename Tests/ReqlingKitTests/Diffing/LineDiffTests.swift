import Foundation
import ReqlingKit
import XCTest

final class LineDiffTests: XCTestCase {
    func testTheScriptRebuildsTheNewTextWithTheFewestEdits() throws {
        struct Case {
            let old: [String]
            let new: [String]
            let changes: Int
        }
        let cases = [
            Case(old: ["a", "b", "c"], new: ["a", "b", "c"], changes: 0),
            Case(old: ["a", "b", "c"], new: ["a", "x", "b", "c"], changes: 1),
            Case(old: ["a", "b", "c"], new: ["a", "c"], changes: 1),
            Case(old: ["a", "b", "c"], new: ["a", "x", "c"], changes: 2),
            Case(old: [], new: ["a", "b"], changes: 2),
            Case(old: ["a", "b"], new: [], changes: 2),
            Case(old: ["a", "b", "c", "a", "b", "b", "a"], new: ["c", "b", "a", "b", "a", "c"], changes: 5)
        ]
        for test in cases {
            let edits = try LineDiff.edits(from: test.old, to: test.new)

            XCTAssertEqual(rebuild(test.old, test.new, edits), test.new, "\(test.old) → \(test.new)")
            XCTAssertEqual(edits.filter(\.isChange).count, test.changes, "\(test.old) → \(test.new)")
        }
    }

    /// Lines both texts share at either end stay paired by position, so numbering survives the trimming.
    func testSharedEndsKeepTheirPlaces() throws {
        let old = (0..<100).map { "line \($0)" }
        var new = old
        new[50] = "changed"

        let edits = try LineDiff.edits(from: old, to: new)

        XCTAssertEqual(edits.first, .equal(old: 0, new: 0))
        XCTAssertEqual(edits.last, .equal(old: 99, new: 99))
        XCTAssertEqual(edits.filter(\.isChange), [.removed(old: 50), .added(new: 50)])
    }

    /// Past the edit limit the middle reads as replaced wholesale: longer than the shortest script, but still right.
    func testTooManyEditsFallBackToReplacingTheMiddle() throws {
        let old = ["keep", "a", "b", "c", "end"]
        let new = ["keep", "x", "b", "y", "end"]

        let edits = try LineDiff.edits(from: old, to: new, maxEditDistance: 1)

        XCTAssertEqual(rebuild(old, new, edits), new)
        XCTAssertEqual(edits.filter(\.isChange).count, 6)
        XCTAssertEqual(edits.first, .equal(old: 0, new: 0))
    }

    func testACancelledDiffStops() async {
        let old = (0..<5_000).map { "old \($0)" }
        let new = (0..<5_000).map { "new \($0)" }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try LineDiff.edits(from: old, to: new, maxEditDistance: 4_000)
        }

        let result = await task.result

        XCTAssertThrowsError(try result.get()) { XCTAssertTrue($0 is CancellationError) }
    }

    /// Applies the script: equal and added lines in order make the new text.
    private func rebuild(_ old: [String], _ new: [String], _ edits: [LineDiff.Edit]) -> [String] {
        edits.compactMap { edit in
            switch edit {
            case .equal(let oldIndex, let newIndex):
                XCTAssertEqual(old[oldIndex], new[newIndex])
                return new[newIndex]
            case .added(let newIndex):
                return new[newIndex]
            case .removed:
                return nil
            }
        }
    }
}

private extension LineDiff.Edit {
    var isChange: Bool {
        if case .equal = self {
            return false
        }
        return true
    }
}
