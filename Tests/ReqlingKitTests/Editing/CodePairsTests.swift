import Foundation
import ReqlingKit
import XCTest

/// Brackets and quotes typed in a script or a GraphQL query, with `|` marking the cursor.
final class CodePairsTests: XCTestCase {
    private func typing(_ typed: String, _ marked: String, in language: SyntaxLanguage = .javascript) -> CodePairs.Typing? {
        let cursor = (marked as NSString).range(of: "|").location
        return CodePairs.typing(typed, in: marked.replacingOccurrences(of: "|", with: ""), at: cursor, language: language)
    }

    private func deletesPair(_ marked: String, in language: SyntaxLanguage = .javascript) -> Bool {
        let cursor = (marked as NSString).range(of: "|").location
        return CodePairs.deletesPair(in: marked.replacingOccurrences(of: "|", with: ""), at: cursor, language: language)
    }

    func testAnOpenerPairsWhereNothingFollowsIt() {
        XCTAssertEqual(typing("(", "rq.cookies.get|"), .pair(closer: ")"))
        XCTAssertEqual(typing("(", "rq.expect(rq.cookies.get|)"), .pair(closer: ")"), "before a closer")
        XCTAssertEqual(typing("[", "const a = |;"), .pair(closer: "]"))
        XCTAssertEqual(typing("{", "if (ok) |"), .pair(closer: "}"))
        XCTAssertEqual(typing("(", "f| // later"), .pair(closer: ")"))
        XCTAssertEqual(typing("(", "`${f|}`"), .pair(closer: ")"), "a template's substitution is code")
        XCTAssertNil(typing("(", "|value"), "in front of a name, which it would close before")
    }

    func testABraceAfterADollarInTemplateTextOpensASubstitution() {
        XCTAssertEqual(typing("{", "`id: $|`"), .pair(closer: "}"))
        XCTAssertNil(typing("{", "`id: |`"), "without the `$`, a brace is text")
    }

    func testQuotesPairInCodeButNotAfterANameOrInsideAnotherString() {
        XCTAssertEqual(typing("\"", "rq.cookies.get(|)"), .pair(closer: "\""))
        XCTAssertEqual(typing("'", "x = |"), .pair(closer: "'"))
        XCTAssertEqual(typing("`", "x = |"), .pair(closer: "`"))
        XCTAssertNil(typing("'", "don|"), "after a name, as in don't")
        XCTAssertNil(typing("'", #"x = "it|""#), "inside a string of the other kind")
        XCTAssertNil(typing("\"", "x = |value"))
    }

    func testCharactersInStringsCommentsAndOtherLanguagesAreTypedAsIs() {
        XCTAssertNil(typing("(", #"rq.test("a|"#))
        XCTAssertNil(typing("[", "// see f|"))
        XCTAssertNil(typing("(", "`text |`"))
        XCTAssertNil(typing("(", "`${a}| b`"), "text resuming after a substitution")
        XCTAssertNil(typing(")", "`${a}|)`"), "a `)` in template text is no closer")
        XCTAssertNil(typing("(", "`${a}|"), "an unterminated template's text, at the end")
        XCTAssertNil(typing("\"", "{|}", in: .json))
        XCTAssertNil(typing("(", "a|", in: .plainText))
    }

    func testACloserStepsOverOneThatAlreadyClosesItsBracket() {
        XCTAssertEqual(typing(")", "f(1|)"), .stepOver)
        XCTAssertEqual(typing(")", "f(g(|))"), .stepOver)
        XCTAssertEqual(typing("]", "[1, 2|]"), .stepOver)
        XCTAssertEqual(typing("}", "{ a: 1 |}"), .stepOver)
        XCTAssertEqual(typing("}", "`${a|}`"), .stepOver, "a substitution's `}`")
        XCTAssertNil(typing(")", "f(g(|)"), "a `(` is still open: this one closes it")
        XCTAssertNil(typing("]", "f(1|)"), "another kind's closer")
        XCTAssertNil(typing(")", #"f(")|")"#), "inside a string")
    }

    func testAQuoteStepsOverTheOneClosingItsString() {
        XCTAssertEqual(typing("\"", #"get("name|")"#), .stepOver)
        XCTAssertEqual(typing("'", "x = '|'"), .stepOver, "an empty string")
        XCTAssertEqual(typing("`", "`text|`"), .stepOver)
        XCTAssertEqual(typing("`", "`${a}|`"), .stepOver, "after a substitution")
        XCTAssertNil(typing("'", #""it|""#), "the string closes with the other kind")
        XCTAssertNil(typing("\"", #""a\|""#), "an escaped quote closes nothing")
    }

    func testBackspaceRemovesOnlyAnEmptyPair() {
        XCTAssertTrue(deletesPair("f(|)"))
        XCTAssertTrue(deletesPair("[|]"))
        XCTAssertTrue(deletesPair("x = {|}"))
        XCTAssertTrue(deletesPair(#"get("|")"#))
        XCTAssertTrue(deletesPair("x = '|'"))
        XCTAssertTrue(deletesPair("x = `|`"))
        XCTAssertFalse(deletesPair("f(|1)"))
        XCTAssertFalse(deletesPair(#"f("(|)")"#), "inside a string")
        XCTAssertFalse(deletesPair(#""a"|"b""#), "two strings meeting")
        XCTAssertFalse(deletesPair("f(|)", in: .json))
    }

    func testGraphQLPairsBracketsAndDoubleQuotes() {
        XCTAssertEqual(typing("(", "{ books|", in: .graphQL), .pair(closer: ")"))
        XCTAssertEqual(typing("{", "query |", in: .graphQL), .pair(closer: "}"))
        XCTAssertEqual(typing("[", "query ($ids: |)", in: .graphQL), .pair(closer: "]"))
        XCTAssertEqual(typing("\"", "{ books(filter: |) }", in: .graphQL), .pair(closer: "\""))
        XCTAssertNil(typing("'", "{ books(filter: |) }", in: .graphQL), "GraphQL has no single-quoted strings")
        XCTAssertNil(typing("(", "# see books|", in: .graphQL), "a comment")
        XCTAssertNil(typing("(", "\"\"\"a |\"\"\"", in: .graphQL), "a block string")
        XCTAssertEqual(typing(")", "{ books(first: 1|) }", in: .graphQL), .stepOver)
        XCTAssertEqual(typing("\"", "{ books(filter: \"a|\") }", in: .graphQL), .stepOver)
        XCTAssertTrue(deletesPair("{ books(|) }", in: .graphQL))
    }

    /// A `{{variable}}` is one GraphQL token; its braces still pair as they're typed and step over once it has a name.
    func testGraphQLVariablesPairAndStepOverTheirClosingBraces() {
        XCTAssertEqual(typing("{", "{ book(id: |) }", in: .graphQL), .pair(closer: "}"))
        XCTAssertEqual(typing("{", "{ book(id: {|}) }", in: .graphQL), .pair(closer: "}"), "the second brace of `{{`")
        XCTAssertTrue(deletesPair("{ book(id: {{|}}) }", in: .graphQL))
        XCTAssertEqual(typing("}", "{ book(id: {{token|}}) }", in: .graphQL), .stepOver)
        XCTAssertEqual(typing("}", "{ book(id: {{token}|}) }", in: .graphQL), .stepOver)
        XCTAssertNil(typing("(", "{ book(id: {{tok|en}}) }", in: .graphQL), "inside its name")
    }
}
