import Foundation
import ReqlingKit
import XCTest

final class SyntaxTokenizerTests: XCTestCase {
    private func roles(_ source: String, _ language: SyntaxLanguage) -> [(String, SyntaxRole)] {
        SyntaxTokenizer.tokens(in: source, language: language).map { ((source as NSString).substring(with: $0.range), $0.role) }
    }

    private func assertRoles(
        _ source: String,
        _ language: SyntaxLanguage,
        _ expected: [(String, SyntaxRole)],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let actual = roles(source, language)
        XCTAssertEqual(actual.map(\.0), expected.map(\.0), file: file, line: line)
        XCTAssertEqual(actual.map(\.1), expected.map(\.1), file: file, line: line)
    }

    func testJSONSeparatesKeysFromValues() {
        assertRoles(#"{"id": 7, "name": "a: b", "ok": true}"#, .json, [
            ("{", .symbol), (#""id""#, .property), (":", .symbol), ("7", .number), (",", .symbol),
            (#""name""#, .property), (":", .symbol), (#""a: b""#, .string), (",", .symbol),
            (#""ok""#, .property), (":", .symbol), ("true", .keyword), ("}", .symbol)
        ])
    }

    func testCommentMarkersInsideStringsStayStrings() {
        assertRoles(#"const url = "http://x"; // done"#, .javascript, [
            ("const", .keyword), (#""http://x""#, .string), ("// done", .comment)
        ])
        assertRoles("key: \"# not a comment\" # comment", .yaml, [
            ("key", .property), ("\"# not a comment\"", .string), ("# comment", .comment)
        ])
    }

    /// A quote opens a YAML string only where a value starts, and a `#` a comment only after a blank, so prose in a
    /// plain or block scalar stays plain.
    func testYAMLQuotesAndCommentsNeedTheirContext() {
        assertRoles("note: we've done it's\nurl: https://x/#top\nlist: ['a', \"b\"]", .yaml, [
            ("note", .property), ("url", .property), ("list", .property), ("'a'", .string), ("\"b\"", .string)
        ])
        assertRoles("text: |-\n  it's a block\n  'quoted' line", .yaml, [("text", .property), ("'quoted'", .string)])
    }

    func testMarkup() {
        assertRoles(#"<a href="x">&amp;</a>"#, .xml, [
            ("<a", .keyword), ("href", .property), ("=", .symbol), (#""x""#, .string), (">", .symbol),
            ("&amp;", .keyword), ("</a", .keyword), (">", .symbol)
        ])
    }

    func testGraphQL() {
        assertRoles("query User($id: ID!) { user(id: $id) @cached { name } } # c", .graphQL, [
            ("query", .keyword), ("(", .symbol), ("$id", .property), (":", .symbol), ("!", .symbol), (")", .symbol),
            ("{", .symbol), ("(", .symbol), (":", .symbol), ("$id", .property), (")", .symbol), ("@cached", .keyword),
            ("{", .symbol), ("}", .symbol), ("}", .symbol), ("# c", .comment)
        ])
    }

    func testPlainTextAndOversizedSourcesAreLeftPlain() {
        XCTAssertTrue(SyntaxTokenizer.tokens(in: #"{"a": 1}"#, language: .plainText).isEmpty)
        // The regex languages stop at the limit; JSON has none (`testJSONOverTheRegexLimitStillColors`).
        let huge = String(repeating: "1", count: SyntaxTokenizer.maximumLength + 1)
        XCTAssertTrue(SyntaxTokenizer.tokens(in: huge, language: .yaml).isEmpty)
    }

    func testContentTypesMapToLanguages() {
        XCTAssertEqual(ContentTypeLanguage.language(forContentType: "application/json; charset=utf-8"), .json)
        XCTAssertEqual(ContentTypeLanguage.language(forContentType: "application/problem+json"), .json)
        XCTAssertEqual(ContentTypeLanguage.language(forContentType: "application/atom+xml"), .xml)
        XCTAssertEqual(ContentTypeLanguage.language(forContentType: "text/xml"), .xml)
        XCTAssertEqual(ContentTypeLanguage.language(forContentType: "TEXT/HTML"), .html)
        XCTAssertEqual(ContentTypeLanguage.language(forContentType: "application/x-yaml"), .yaml)
        XCTAssertEqual(ContentTypeLanguage.language(forContentType: "application/openapi+yaml; version=3.1"), .yaml)
        XCTAssertEqual(ContentTypeLanguage.language(forContentType: "text/yaml"), .yaml)
        XCTAssertEqual(ContentTypeLanguage.language(forContentType: "text/plain"), .plainText)
        XCTAssertEqual(ContentTypeLanguage.language(forContentType: nil), .plainText)
    }
}
