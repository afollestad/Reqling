import Foundation
import ReqlingKit
import XCTest

/// Where inserted lines of code go, such as a script snippet: `|` marks the cursor and `«…»` a selection, before and
/// after; `<#…#>` marks the code's placeholder.
extension CodeIndentTests {
    func testCodeGoesOnTheCursorsLineWhenThatLineIsBlank() {
        XCTAssertEqual(insert("a(<#x#>)", into: "|"), "a(«x»)")
        XCTAssertEqual(insert("a()", into: "one\n  |\ntwo"), "one\n  a()|\ntwo", "at the blanks already there")
        XCTAssertEqual(insert("a()", into: "one\n |  \ntwo"), "one\n   a()|\ntwo", "a cursor inside them")
    }

    func testOtherwiseItGoesOnANewLineAfterTheCursorsLineNeverOverTheSelection() {
        XCTAssertEqual(insert("b()", into: "a(|1)\nc()"), "a(1)\nb()|\nc()")
        XCTAssertEqual(insert("b()", into: "  a(|)"), "  a()\n  b()|", "keeping the line's indentation")
        XCTAssertEqual(insert("b()", into: "«a(1)»\nc()"), "a(1)\nb()|\nc()")
        XCTAssertEqual(insert("b()", into: "«a(1)\n»c()"), "a(1)\nb()|\nc()", "a selection ending at a line's start")
    }

    func testItIndentsOneLevelDeeperAfterAnOpenBracketOutsideStringsAndComments() {
        XCTAssertEqual(insert("b()", into: "rq.onEvent((event) => {|\n})"), "rq.onEvent((event) => {\n  b()|\n})")
        XCTAssertEqual(insert("b()", into: "const a = [|"), "const a = [\n  b()|")
        XCTAssertEqual(insert("b()", into: #"const s = "{"|"#), "const s = \"{\"\nb()|")
        XCTAssertEqual(insert("b()", into: "// opens {|"), "// opens {\nb()|")
    }

    func testEachLineOfTheCodeTakesTheIndentationAndItsPlaceholderIsSelected() {
        XCTAssertEqual(
            insert("if (x) {\n  <#y#>()\n\n}", into: "  a {|"),
            "  a {\n    if (x) {\n      «y»()\n\n    }",
            "an empty line stays empty"
        )
    }

    private func insert(_ markedCode: String, into marked: String) -> String {
        let (code, placeholder) = Self.unmark(markedCode, open: "<#", close: "#>")
        let (text, selection) = marked.contains("«")
            ? Self.unmark(marked, open: "«", close: "»")
            : Self.unmark(marked, open: "|", close: nil)
        let insertion = CodeIndent.insertion(
            of: code,
            placeholder: placeholder,
            in: text,
            selection: selection ?? NSRange(location: 0, length: 0),
            language: .javascript
        )
        let result = (text as NSString).replacingCharacters(in: insertion.range, with: insertion.replacement) as NSString
        let selected = NSRange(location: insertion.range.location + insertion.selection.location, length: insertion.selection.length)
        guard selected.length > 0 else {
            return result.replacingCharacters(in: NSRange(location: selected.location, length: 0), with: "|")
        }
        return result.replacingCharacters(in: selected, with: "«" + result.substring(with: selected) + "»")
    }

    /// `marked` without its markers, and the range between them; a `nil` close marks a cursor.
    private static func unmark(_ marked: String, open: String, close: String?) -> (String, NSRange?) {
        let units = marked as NSString
        let start = units.range(of: open)
        guard start.location != NSNotFound else {
            return (marked, nil)
        }
        let rest = units.replacingCharacters(in: start, with: "") as NSString
        guard let close else {
            return (rest as String, NSRange(location: start.location, length: 0))
        }
        let end = rest.range(of: close)
        return (rest.replacingCharacters(in: end, with: ""), NSRange(location: start.location, length: end.location - start.location))
    }
}
