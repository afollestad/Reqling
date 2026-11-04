import Foundation
@testable import ReqlingKit
import XCTest

final class TextDocumentTests: XCTestCase {
    private func document(_ text: String, _ language: SyntaxLanguage = .plainText) throws -> TextDocument {
        try XCTUnwrap(try TextDocument.make(Data(text.utf8), language: language))
    }

    private func lines(_ document: TextDocument) -> [String] {
        (0..<document.lineCount).map { document.text(in: document.byteRange(ofLine: $0)) }
    }

    func testSplitsLinesOnLineFeedsAndDropsTheCarriageReturnBeforeOne() throws {
        XCTAssertEqual(lines(try document("")), [""])
        XCTAssertEqual(lines(try document("a")), ["a"])
        XCTAssertEqual(lines(try document("a\nb\n")), ["a", "b", ""])
        XCTAssertEqual(lines(try document("a\r\nb\rc\r")), ["a", "b\rc\r"])
        XCTAssertEqual(try document("one\ntwo\nthree").line(containing: 5), 1)
    }

    func testRejectsBytesThatAreNotUTF8ButKeepsTextCutMidCharacter() throws {
        XCTAssertNil(try TextDocument.make(Data([0x61, 0xFF, 0x62]), language: .plainText))
        XCTAssertNil(try TextDocument.make(Data([0xED, 0xA0, 0x80]), language: .plainText), "a surrogate")
        // "é" is C3 A9; a body cut to fit the cache can end after its first byte.
        let cut = try XCTUnwrap(try TextDocument.make(Data([0x61, 0x0A, 0x62, 0xC3]), language: .plainText))
        XCTAssertEqual(cut.length, 3)
        XCTAssertEqual(lines(cut), ["a", "b"])
    }

    func testMeasuresColumnsForWideCombiningAndTabbedText() throws {
        let text = try document("ab\t東京e\u{301}🙂x")
        // a b → 2, tab → 4, 東 京 → 8, e + combining → 9, 🙂 → 11, x → 12
        XCTAssertEqual(text.columns(ofLine: 0), 12)
        let line = text.byteRange(ofLine: 0)
        XCTAssertEqual(text.column(ofByte: line.upperBound, line: 0), 12)
        let tokyo = text.byteOffset(line: 0, column: 4)
        XCTAssertEqual(text.text(in: tokyo..<line.upperBound), "東京e\u{301}🙂x")
        let midTokyo = text.byteOffset(line: 0, column: 5)
        XCTAssertEqual(text.text(in: midTokyo..<line.upperBound), "京e\u{301}🙂x", "mid-character columns start at the next one")
    }

    func testLongLinesWalkFromCheckpoints() throws {
        let long = String(repeating: "abcdefghé", count: 2_000)
        let text = try document("short\n" + long + "\nend")
        XCTAssertEqual(text.columns(ofLine: 1), 18_000)
        XCTAssertFalse(text.columnCheckpoints.isEmpty)
        for column in [0, 4095, 4096, 4097, 9_000, 17_999] {
            let offset = text.byteOffset(line: 1, column: column)
            XCTAssertEqual(text.column(ofByte: offset, line: 1), column, "column \(column)")
        }
        XCTAssertEqual(text.byteOffset(line: 1, column: 50_000), text.byteRange(ofLine: 1).upperBound)
    }

    func testWrapsOnlyLinesWiderThanTheColumns() throws {
        let text = try document("short\n" + String(repeating: "x", count: 100) + "\nmid\n" + String(repeating: "y", count: 45))
        let layout = WrapLayout(document: text, columns: 40)
        XCTAssertEqual(layout.rowCount, 1 + 3 + 1 + 2)
        XCTAssertEqual((0..<layout.rowCount).map { layout.position(ofRow: $0).line }, [0, 1, 1, 1, 2, 3, 3])
        XCTAssertEqual((0..<layout.rowCount).map { layout.position(ofRow: $0).chunk }, [0, 0, 1, 2, 0, 0, 1])
        XCTAssertEqual(layout.firstRow(ofLine: 2), 4)
        XCTAssertEqual(layout.byteRange(ofRow: 3).count, 20)
        for row in 0..<layout.rowCount {
            XCTAssertEqual(layout.row(ofByte: layout.byteRange(ofRow: row).lowerBound), row, "row \(row)")
        }
        XCTAssertEqual(WrapLayout(document: text, columns: 200).rowCount, text.lineCount)
        XCTAssertEqual(WrapLayout(document: text, columns: 10).columns, TextDocument.wrapMinimumColumns)
    }

    func testColorsJSONRowsAnywhereInAHugeMinifiedLine() throws {
        let items = (0..<20_000).map { #"{"key \#($0)":"a \"quoted\" value","n":\#($0)}"# }.joined(separator: ",")
        let text = try document("[" + items + "]", .json)
        let highlighter = TextHighlighter(document: text)
        let layout = WrapLayout(document: text, columns: 100)
        XCTAssertGreaterThan(layout.rowCount, 1_000)
        text.withBytes { bytes in
            let whole = JSONLexer.tokens(in: bytes, range: 0..<text.length, from: .start)
            for row in [0, 1, layout.rowCount / 2, layout.rowCount - 1] {
                let range = layout.byteRange(ofRow: row)
                XCTAssertEqual(highlighter.tokens(in: range, line: 0), ByteToken.clip(whole, to: range), "row \(row)")
            }
        }
    }

    func testColorsOtherLanguagesFromRegexTokensInBytes() throws {
        let text = try document("<a href=\"é\">\n<!-- note -->\n", .xml)
        let tokens = TextHighlighter(document: text).tokens(in: text.byteRange(ofLine: 1), line: 1)
        XCTAssertEqual(tokens.map { text.text(in: $0.range) }, ["<!-- note -->"])
        XCTAssertEqual(tokens.map(\.role), [.comment])
    }

    func testFindsCaseInsensitivelyInBytes() throws {
        let text = try document("Hello hello\nHÉLLO héllo")
        XCTAssertEqual(try text.find("hello").matches.map { text.text(in: $0) }, ["Hello", "hello"])
        XCTAssertEqual(try text.find("héllo").matches.map { text.text(in: $0) }, ["HÉLLO", "héllo"])
        XCTAssertEqual(try text.find("l", limit: 3), TextDocument.SearchResult(matches: [2..<3, 3..<4, 8..<9], isTruncated: true))
        XCTAssertEqual(try text.find("").matches, [])
    }
}
