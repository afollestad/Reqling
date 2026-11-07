import Foundation
import ReqlingKit
import XCTest

/// Return in JSON, JavaScript, and GraphQL editors, with `|` marking the cursor before and after.
final class CodeIndentTests: XCTestCase {
    func testAnOpenedBracketGetsItsCloserOnTheLineAfter() {
        XCTAssertEqual(pressReturn("{|"), "{\n  |\n}")
        XCTAssertEqual(pressReturn("[|"), "[\n  |\n]")
        XCTAssertEqual(pressReturn("{\n  \"a\": {|\n}"), "{\n  \"a\": {\n    |\n  }\n}", "inside an object whose closer is already there")
        XCTAssertEqual(pressReturn("[\n  {|\n  {\"b\": 2}\n]"), "[\n  {\n    |\n  }\n  {\"b\": 2}\n]")
    }

    func testABracketWithItsCloserBesideTheCursorSplitsAroundIt() {
        XCTAssertEqual(pressReturn("{|}"), "{\n  |\n}")
        XCTAssertEqual(pressReturn("  \"a\": [| ]"), "  \"a\": [\n    |\n  ]")
    }

    func testABracketAlreadyClosedOnlyIndents() {
        XCTAssertEqual(pressReturn("{|\n  \"a\": 1\n}"), "{\n  |\n  \"a\": 1\n}")
        XCTAssertEqual(pressReturn("{|\"a\": 1}"), "{\n  |\"a\": 1}", "what follows the cursor moves down, indented")
    }

    func testOtherLinesKeepTheirIndentation() {
        XCTAssertEqual(pressReturn("{\n  \"a\": 1,|\n}"), "{\n  \"a\": 1,\n  |\n}")
        XCTAssertEqual(pressReturn("  |  x"), "  \n  |  x", "a cursor inside the indentation keeps what precedes it")
    }

    func testJSONStringsAndTemplatesHoldNoBrackets() {
        XCTAssertEqual(pressReturn("{\"a\": \"x {|\"}"), "{\"a\": \"x {\n|\"}", "inside a string: a plain line break")
        XCTAssertEqual(pressReturn("{\n  \"a\": \"}\",\n  \"b\": {|\n}"), "{\n  \"a\": \"}\",\n  \"b\": {\n    |\n  }\n}")
        XCTAssertEqual(pressReturn(#"{"a": "say \"{\"", "b": [|"#), "{\"a\": \"say \\\"{\\\"\", \"b\": [\n  |\n]", "escaped quotes")
        XCTAssertEqual(pressReturn("{{|"), "{{\n|", "a variable's opening")
    }

    func testGraphQLSelectionSetsIndentAndClose() {
        XCTAssertEqual(pressReturn("query {|", in: .graphQL), "query {\n  |\n}")
        XCTAssertEqual(pressReturn("{\n  me {|\n}", in: .graphQL), "{\n  me {\n    |\n  }\n}")
        XCTAssertEqual(pressReturn("{ me {|} }", in: .graphQL), "{ me {\n  |\n} }")
        XCTAssertEqual(pressReturn("{\n  me|\n}", in: .graphQL), "{\n  me\n  |\n}")
        XCTAssertEqual(pressReturn("{ me|ta }", in: .graphQL), "{ me\n|ta }", "inside a name after a brace")
    }

    func testGraphQLCommentsStringsAndVariablesHoldNoBrackets() {
        XCTAssertEqual(pressReturn("  # opens {|", in: .graphQL), "  # opens {\n  |", "a comment keeps its indentation")
        XCTAssertEqual(pressReturn("{ book(title: \"a {|\") }", in: .graphQL), "{ book(title: \"a {\n|\") }")
        XCTAssertEqual(pressReturn("\"\"\"\n{|\n\"\"\"", in: .graphQL), "\"\"\"\n{\n|\n\"\"\"", "a block string")
        XCTAssertEqual(pressReturn("{ user(id: {{userId}}|", in: .graphQL), "{ user(id: {{userId}}\n|")
        XCTAssertEqual(pressReturn("{ user(id: {{|", in: .graphQL), "{ user(id: {{\n|")
    }

    func testATypedCloserMovesBackToItsOpenersIndentation() {
        XCTAssertEqual(typeCloser("}", "{\n  \"a\": 1\n  |"), "{\n  \"a\": 1\n}|")
        XCTAssertEqual(typeCloser("]", "{\n  \"a\": [\n    1\n    |"), "{\n  \"a\": [\n    1\n  ]|")
        XCTAssertEqual(typeCloser("}", "query {\n  me {\n    name\n      |", in: .graphQL), "query {\n  me {\n    name\n  }|")
        XCTAssertEqual(typeCloser("}", "  {\n|"), "  {\n  }|", "out to the opener, too")
    }

    func testATypedCloserIsLeftWhereItIsOtherwise() {
        XCTAssertEqual(typeCloser("}", "{\n|"), "{\n}|", "already at its opener's indentation")
        XCTAssertEqual(typeCloser("}", "{\n  \"a\": 1 |"), "{\n  \"a\": 1 }|", "text before it on the line")
        XCTAssertEqual(typeCloser("}", "{\n  \"a\": \"\n  |"), "{\n  \"a\": \"\n  }|", "inside a string")
        XCTAssertEqual(typeCloser("}", "[\n  |"), "[\n  }|", "it closes no open bracket of its kind")
        XCTAssertEqual(typeCloser("}", "# {\n  |", in: .graphQL), "# {\n  }|", "a comment opens nothing")
        XCTAssertEqual(typeCloser("}", "{\n  |", in: .plainText), "{\n  }|")
        XCTAssertNil(CodeIndent.typing("x", in: "{\n  ", at: 4, language: .json))
    }

    func testJavaScriptBlocksIndentAndClose() {
        XCTAssertEqual(pressReturn("rq.test(\"ok\", () => {|", in: .javascript), "rq.test(\"ok\", () => {\n  |\n}")
        XCTAssertEqual(pressReturn("if (a) {|}", in: .javascript), "if (a) {\n  |\n}")
        XCTAssertEqual(pressReturn("const x = [|", in: .javascript), "const x = [\n  |\n]")
        XCTAssertEqual(pressReturn("{{|", in: .javascript), "{{\n  |\n}", "`{{` is code in a script")
        XCTAssertEqual(typeCloser("}", "function f() {\n  x()\n  |", in: .javascript), "function f() {\n  x()\n}|")
        XCTAssertEqual(stepOver("if (a) {\n  x()\n  |}", in: .javascript), "if (a) {\n  x()\n}|", "stepping over the closer moves it back")
        XCTAssertEqual(stepOver("if (a) {\n  x()\n|}", in: .javascript), nil, "already where it belongs")
        XCTAssertEqual(stepOver("if (a) { x() |}", in: .javascript), nil, "not at the start of its line")
    }

    func testJavaScriptStringsTemplatesRegexesAndCommentsHoldNoBrackets() {
        XCTAssertEqual(pressReturn("const s = \"{|\"", in: .javascript), "const s = \"{\n|\"")
        XCTAssertEqual(pressReturn("const s = `a {|`", in: .javascript), "const s = `a {\n|`", "template text")
        XCTAssertEqual(pressReturn("const r = /[{|]/", in: .javascript), "const r = /[{\n|]/")
        XCTAssertEqual(pressReturn("  // opens {|", in: .javascript), "  // opens {\n  |")
        XCTAssertEqual(pressReturn("const s = `${|`", in: .javascript), "const s = `${\n  |`", "a substitution's brace opens code")
        XCTAssertEqual(typeCloser("}", "const s = `\n  |", in: .javascript), "const s = `\n  }|", "inside a template")
    }

    func testOtherLanguagesKeepAPlainLineBreak() {
        XCTAssertNil(CodeIndent.newline(in: "{", at: 1, language: .plainText))
        XCTAssertNil(CodeIndent.newline(in: "<a>", at: 3, language: .xml))
    }

    /// Types `closer` at `|`, applying the edit, or inserting it as is where there is none.
    private func typeCloser(_ closer: String, _ marked: String, in language: SyntaxLanguage = .json) -> String {
        let cursor = (marked as NSString).range(of: "|").location
        let text = (marked as NSString).replacingCharacters(in: NSRange(location: cursor, length: 1), with: "") as NSString
        guard let edit = CodeIndent.typing(closer, in: text as String, at: cursor, language: language) else {
            return text.replacingCharacters(in: NSRange(location: cursor, length: 0), with: closer + "|")
        }
        let result = text.replacingCharacters(in: edit.range, with: edit.replacement) as NSString
        return result.replacingCharacters(in: NSRange(location: edit.range.location + edit.caret, length: 0), with: "|")
    }

    /// Applies the edit, or a plain line break where there is none.
    /// What stepping over the closer at `|` leaves, or nil where it only moves the cursor.
    private func stepOver(_ marked: String, in language: SyntaxLanguage) -> String? {
        let cursor = (marked as NSString).range(of: "|").location
        let text = (marked as NSString).replacingCharacters(in: NSRange(location: cursor, length: 1), with: "") as NSString
        guard let edit = CodeIndent.steppingOver(closerAt: cursor, in: text as String, language: language) else {
            return nil
        }
        let result = text.replacingCharacters(in: edit.range, with: edit.replacement) as NSString
        return result.replacingCharacters(in: NSRange(location: edit.range.location + edit.caret, length: 0), with: "|")
    }

    private func pressReturn(_ marked: String, in language: SyntaxLanguage = .json) -> String {
        let cursor = (marked as NSString).range(of: "|").location
        let text = (marked as NSString).replacingCharacters(in: NSRange(location: cursor, length: 1), with: "") as NSString
        guard let edit = CodeIndent.newline(in: text as String, at: cursor, language: language) else {
            return text.replacingCharacters(in: NSRange(location: cursor, length: 0), with: "\n|")
        }
        let result = text.replacingCharacters(in: edit.range, with: edit.replacement) as NSString
        return result.replacingCharacters(in: NSRange(location: edit.range.location + edit.caret, length: 0), with: "|")
    }
}
