import Foundation
import ReqlingKit
import XCTest

final class DiffDocumentTests: XCTestCase {
    /// Unchanged lines beyond three of a change fold into one row once there are eight or more of them.
    func testLongUnchangedStretchesCollapseAroundTheChange() throws {
        let old = (1...30).map { "line \($0)" }
        var new = old
        new[14] = "changed"

        let diff = try DiffDocument.make(old: old.joined(separator: "\n"), new: new.joined(separator: "\n"), language: .plainText)

        XCTAssertEqual(diff.lines.map(\.kind), [.omitted(11)] + Array(repeating: .context, count: 3) + [.removed, .added]
            + Array(repeating: .context, count: 3) + [.omitted(12)])
        let removed = try XCTUnwrap(diff.lines.first { $0.kind == .removed })
        XCTAssertEqual(removed.oldNumber, 15)
        XCTAssertNil(removed.newNumber)
        XCTAssertEqual(diff.text.lineCount, diff.lines.count)
        XCTAssertEqual(diff.text.text(in: diff.text.byteRange(ofLine: 4)), "line 15", "markers stay out of the text")
        XCTAssertEqual([diff.addedCount, diff.removedCount], [1, 1])
    }

    func testShortUnchangedStretchesStay() throws {
        let old = (1...7).map { "line \($0)" }
        let new = old + ["line 8"]

        let diff = try DiffDocument.make(old: old.joined(separator: "\n"), new: new.joined(separator: "\n"), language: .plainText)

        XCTAssertEqual(diff.lines.map(\.kind), Array(repeating: .context, count: 7) + [.added])
    }

    /// Lines compare by their bytes, so text that differs only in Unicode normalization still differs.
    func testLinesDifferingOnlyInNormalizationDiffer() throws {
        let composed = "caf\u{E9}"
        let decomposed = "cafe\u{301}"
        XCTAssertEqual(composed, decomposed, "Swift calls them equal")

        XCTAssertTrue(try DiffDocument.make(old: composed, new: decomposed, language: .plainText).hasChanges)
    }

    /// Line endings and a final line break don't count as changes, and empty text has no lines to remove.
    func testLineEndingsAndEmptyTextAreNotChanges() throws {
        XCTAssertFalse(try DiffDocument.make(old: "a\r\nb\r\n", new: "a\nb", language: .plainText).hasChanges)

        let fromEmpty = try DiffDocument.make(old: "", new: "a", language: .plainText)
        XCTAssertEqual(fromEmpty.lines.map(\.kind), [.added])
    }
}
