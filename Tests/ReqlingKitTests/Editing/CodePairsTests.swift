import Foundation
import ReqlingKit
import XCTest

/// Parentheses typed in a script, with `|` marking the cursor.
final class CodePairsTests: XCTestCase {
    private func typing(_ typed: String, _ marked: String, in language: SyntaxLanguage = .javascript) -> CodePairs.Typing? {
        let cursor = (marked as NSString).range(of: "|").location
        return CodePairs.typing(typed, in: marked.replacingOccurrences(of: "|", with: ""), at: cursor, language: language)
    }

    private func deletesPair(_ marked: String, in language: SyntaxLanguage = .javascript) -> Bool {
        let cursor = (marked as NSString).range(of: "|").location
        return CodePairs.deletesPair(in: marked.replacingOccurrences(of: "|", with: ""), at: cursor, language: language)
    }

    func testAnOpeningParenthesisPairsWhereNothingFollowsIt() {
        XCTAssertEqual(typing("(", "rq.cookies.get|"), .pair)
        XCTAssertEqual(typing("(", "rq.expect(rq.cookies.get|)"), .pair, "before a closer")
        XCTAssertEqual(typing("(", "f|, 2"), .pair)
        XCTAssertEqual(typing("(", "f| // later"), .pair)
        XCTAssertEqual(typing("(", "`${f|}`"), .pair, "a template's substitution is code")
        XCTAssertNil(typing("(", "|value"), "in front of a name, which it would close before")
    }

    func testParenthesesInStringsCommentsAndOtherLanguagesAreTypedAsIs() {
        XCTAssertNil(typing("(", #"rq.test("a|"#))
        XCTAssertNil(typing("(", "// see f|"))
        XCTAssertNil(typing("(", "`text |`"))
        XCTAssertNil(typing("(", "`${a}| b`"), "text resuming after a substitution")
        XCTAssertNil(typing(")", "`${a}|)`"), "a `)` in template text is no closer")
        XCTAssertNil(typing("(", "`${a}|"), "an unterminated template's text, at the end")
        XCTAssertNil(typing("(", "field|", in: .graphQL))
        XCTAssertNil(typing(")", "f(|)", in: .json))
    }

    func testAClosingParenthesisStepsOverOneThatAlreadyClosesItsCall() {
        XCTAssertEqual(typing(")", "f(1|)"), .stepOver)
        XCTAssertEqual(typing(")", "f(g(|))"), .stepOver)
        XCTAssertNil(typing(")", "f(g(|)"), "a `(` is still open: this one closes it")
        XCTAssertNil(typing(")", "f(1|"), "no closer to step over")
        XCTAssertNil(typing(")", #"f(")|")"#), "inside a string")
    }

    func testBackspaceRemovesOnlyAnEmptyPairInCode() {
        XCTAssertTrue(deletesPair("f(|)"))
        XCTAssertFalse(deletesPair("f(|1)"))
        XCTAssertFalse(deletesPair(#"f("(|)")"#), "inside a string")
        XCTAssertFalse(deletesPair("f(|)", in: .graphQL))
    }
}
