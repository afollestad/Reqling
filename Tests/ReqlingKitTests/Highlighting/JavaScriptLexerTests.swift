import Foundation
@testable import ReqlingKit
import XCTest

final class JavaScriptLexerTests: XCTestCase {
    private func lexed(_ source: String) -> [(String, JavaScriptToken.Kind)] {
        JavaScriptLexer.tokens(in: source).map { ((source as NSString).substring(with: $0.range), $0.kind) }
    }

    private func assertTokens(
        _ source: String,
        _ expected: [(String, JavaScriptToken.Kind)],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let actual = lexed(source)
        XCTAssertEqual(actual.map(\.0), expected.map(\.0), file: file, line: line)
        XCTAssertEqual(actual.map(\.1), expected.map(\.1), file: file, line: line)
    }

    func testNamesKeywordsNumbersAndPunctuators() {
        assertTokens("const res = rq?.response.json() ?? 1.5e+3n;", [
            ("const", .keyword), ("res", .identifier), ("=", .punctuator), ("rq", .identifier), ("?.", .punctuator),
            ("response", .identifier), (".", .punctuator), ("json", .identifier), ("(", .punctuator), (")", .punctuator),
            ("??", .punctuator), ("1.5e+3n", .number), (";", .punctuator)
        ])
        assertTokens("a ?.5 : b => b === c", [
            ("a", .identifier), ("?", .punctuator), (".5", .number), (":", .punctuator), ("b", .identifier),
            ("=>", .punctuator), ("b", .identifier), ("===", .punctuator), ("c", .identifier)
        ])
    }

    func testStringsKeepEscapesAndRunToTheirLineWhenUnterminated() {
        assertTokens(#"'it\'s' "a\"b""#, [(#"'it\'s'"#, .string(terminated: true)), (#""a\"b""#, .string(terminated: true))])
        assertTokens("\"open\nnext", [("\"open", .string(terminated: false)), ("next", .identifier)])
        assertTokens("'a\\\nb'", [("'a\\\nb'", .string(terminated: true))])
    }

    func testCommentsBlockAndLine() {
        assertTokens("x // c\n/* b */ y /* open", [
            ("x", .identifier), ("// c", .comment(terminated: true)), ("/* b */", .comment(terminated: true)),
            ("y", .identifier), ("/* open", .comment(terminated: false))
        ])
    }

    func testASlashIsARegexOnlyWhereAValueCanStart() {
        assertTokens("a / b / c", [
            ("a", .identifier), ("/", .punctuator), ("b", .identifier), ("/", .punctuator), ("c", .identifier)
        ])
        assertTokens("x = /a[/]b\\//gi.test(s)", [
            ("x", .identifier), ("=", .punctuator), ("/a[/]b\\//gi", .regex(terminated: true)), (".", .punctuator),
            ("test", .identifier), ("(", .punctuator), ("s", .identifier), (")", .punctuator)
        ])
        assertTokens("return /x/", [("return", .keyword), ("/x/", .regex(terminated: true))])
        assertTokens("(a) / 2", [("(", .punctuator), ("a", .identifier), (")", .punctuator), ("/", .punctuator), ("2", .number)])
        assertTokens("this / 2", [("this", .keyword), ("/", .punctuator), ("2", .number)])
    }

    func testTemplatesNestAndSetTheirSubstitutionsApart() {
        assertTokens("`a${b + `c${d}`}e`", [
            ("`a", .templateText(terminated: true)), ("${", .punctuator), ("b", .identifier), ("+", .punctuator),
            ("`c", .templateText(terminated: true)), ("${", .punctuator), ("d", .identifier), ("}", .punctuator),
            ("`", .templateText(terminated: true)), ("}", .punctuator), ("e`", .templateText(terminated: true))
        ])
        assertTokens("{ `x${ {a: 1} }` }", [
            ("{", .punctuator), ("`x", .templateText(terminated: true)), ("${", .punctuator), ("{", .punctuator),
            ("a", .identifier), (":", .punctuator), ("1", .number), ("}", .punctuator), ("}", .punctuator),
            ("`", .templateText(terminated: true)), ("}", .punctuator)
        ])
        assertTokens("`open", [("`open", .templateText(terminated: false))])
    }

    func testRangesCountUTF16AfterAnEmoji() {
        let tokens = JavaScriptLexer.tokens(in: "'👋' + nameé")

        XCTAssertEqual(tokens.map(\.range), [NSRange(location: 0, length: 4), NSRange(location: 5, length: 1), NSRange(location: 7, length: 5)])
        XCTAssertEqual(tokens.last?.text, "nameé")
    }

    func testUnterminatedTokensHoldTheirEnd() {
        let open = JavaScriptLexer.tokens(in: "'ab")[0]
        let closed = JavaScriptLexer.tokens(in: "'ab'")[0]

        XCTAssertTrue(open.holds(3))
        XCTAssertFalse(closed.holds(4))
        XCTAssertTrue(closed.holds(2))
        XCTAssertFalse(closed.holds(0))
    }

    func testHighlightingRoles() {
        let source = "const t = `id ${rq.response.code}`; // done"
        let roles = SyntaxTokenizer.tokens(in: source, language: .javascript).map { ((source as NSString).substring(with: $0.range), $0.role) }

        XCTAssertEqual(roles.map(\.0), ["const", "`id ", "${", "response", "code", "}", "`", "// done"])
        XCTAssertEqual(roles.map(\.1), [.keyword, .string, .symbol, .property, .property, .symbol, .string, .comment])
    }
}
