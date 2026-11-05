import AppKit
import XCTest

@testable import Reqling

/// Return in JSON and GraphQL editors, through the text view; `CodeIndentTests` covers what it inserts.
extension CodeTextViewTests {
    func testReturnInAJSONEditorClosesTheBracketAsOneUndoStep() {
        let host = UndoHost()
        let textView = makeTextView(isSingleLine: false, text: "", delegate: host)
        textView.language = .json
        let window = focus(textView)
        type("{", into: textView, host: host)

        host.manager.beginUndoGrouping()
        textView.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        host.manager.endUndoGrouping()

        XCTAssertEqual(textView.string, "{\n  \n}")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 4, length: 0), "between the brackets")
        host.manager.undo()
        XCTAssertEqual(textView.string, "{")
        textView.language = .plainText
        textView.setSelectedRange(NSRange(location: 1, length: 0))
        host.manager.beginUndoGrouping()
        textView.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        host.manager.endUndoGrouping()
        XCTAssertEqual(textView.string, "{\n", "other languages keep AppKit's plain line break")
        textView.language = .graphQL
        textView.setSelectedRange(NSRange(location: 1, length: 0))
        host.manager.beginUndoGrouping()
        textView.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        host.manager.endUndoGrouping()
        XCTAssertEqual(textView.string, "{\n  \n}\n", "a GraphQL selection set too")
        window.close()
    }

    func testATypedCloserMovesBackAsOneUndoStep() {
        let host = UndoHost()
        let textView = makeTextView(isSingleLine: false, text: "{\n  \"a\": 1\n  ", delegate: host)
        textView.language = .json
        let window = focus(textView)

        type("}", into: textView, host: host)

        XCTAssertEqual(textView.string, "{\n  \"a\": 1\n}")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: (textView.string as NSString).length, length: 0))
        host.manager.undo()
        XCTAssertEqual(textView.string, "{\n  \"a\": 1\n  ")
        window.close()
    }
}
