import AppKit
import XCTest

@testable import Reqling

/// Parentheses pairing themselves in a script editor, through the text view; `CodePairsTests` covers when they do.
extension CodeTextViewTests {
    func testTypingAnOpeningParenthesisPairsItAsOneUndoStepAndShowsHints() {
        let host = UndoHost()
        let (textView, presenter) = makeSignatureAssisted(text: "call", delegate: host)
        textView.language = .javascript
        let window = focus(textView)

        typeAtCursor("(", into: textView, host: host)
        XCTAssertEqual(textView.string, "call()")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 5, length: 0), "between them")
        XCTAssertEqual(presenter.signature?.activeParameter, 0, "the hints open as for a typed `(`")

        typeAtCursor("1", into: textView, host: host)
        // Outside an undo group: stepping over changes no text, so it leaves no undo step to group.
        textView.insertText(")", replacementRange: textView.selectedRange())
        XCTAssertEqual(textView.string, "call(1)", "the `)` typed steps over the one already there")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 7, length: 0))
        XCTAssertNil(presenter.signature)

        host.manager.undo()
        host.manager.undo()
        XCTAssertEqual(textView.string, "call", "one step took the pair")
        window.close()
    }

    func testBackspaceBetweenAnEmptyPairRemovesBothAsOneUndoStep() {
        let host = UndoHost()
        let (textView, presenter) = makeSignatureAssisted(text: "call", delegate: host)
        textView.language = .javascript
        let window = focus(textView)
        typeAtCursor("(", into: textView, host: host)

        host.manager.beginUndoGrouping()
        textView.deleteBackward(nil)
        host.manager.endUndoGrouping()
        XCTAssertEqual(textView.string, "call")
        XCTAssertNil(presenter.signature)
        host.manager.undo()
        XCTAssertEqual(textView.string, "call()")
        window.close()
    }

    func testAcceptedMethodsParenthesesAreSteppedOver() {
        let (textView, _) = makeSignatureAssisted(text: "x = ")
        textView.language = .javascript
        let window = focus(textView)
        textView.insertText("a", replacementRange: textView.selectedRange())
        textView.doCommand(by: #selector(NSResponder.insertTab(_:)))
        XCTAssertEqual(textView.string, "x = alpha()")

        textView.insertText(")", replacementRange: textView.selectedRange())
        XCTAssertEqual(textView.string, "x = alpha()")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 11, length: 0))
        window.close()
    }

    func testOtherLanguagesTypeParenthesesAsTheyAre() {
        let textView = makeTextView(isSingleLine: false, text: "field")
        textView.language = .graphQL
        let window = focus(textView)

        textView.insertText("(", replacementRange: textView.selectedRange())
        XCTAssertEqual(textView.string, "field(")
        window.close()
    }

    /// Types `text` where the cursor is, as one undo group.
    private func typeAtCursor(_ text: String, into textView: CodeTextView, host: UndoHost) {
        host.manager.beginUndoGrouping()
        textView.insertText(text, replacementRange: textView.selectedRange())
        host.manager.endUndoGrouping()
    }
}
