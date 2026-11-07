import AppKit
import XCTest

@testable import Reqling

/// Brackets and quotes pairing themselves in a JavaScript editor, through the text view; `CodePairsTests` covers when
/// they do.
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

    func testABracePairedThenReturnOpensAnIndentedLineBetween() {
        let host = UndoHost()
        let textView = makeTextView(isSingleLine: false, text: "if (ok) ", delegate: host)
        textView.language = .javascript
        let window = focus(textView)

        typeAtCursor("{", into: textView, host: host)
        XCTAssertEqual(textView.string, "if (ok) {}")
        host.manager.beginUndoGrouping()
        textView.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        host.manager.endUndoGrouping()
        XCTAssertEqual(textView.string, "if (ok) {\n  \n}")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 12, length: 0))
        window.close()
    }

    func testQuotesPairStepOverAndGoTogether() {
        let host = UndoHost()
        let textView = makeTextView(isSingleLine: false, text: "f()", delegate: host)
        textView.language = .javascript
        let window = focus(textView)
        textView.setSelectedRange(NSRange(location: 2, length: 0))

        typeAtCursor("\"", into: textView, host: host)
        XCTAssertEqual(textView.string, "f(\"\")")
        typeAtCursor("a", into: textView, host: host)
        textView.insertText("\"", replacementRange: textView.selectedRange())
        XCTAssertEqual(textView.string, "f(\"a\")", "the quote typed steps over the closing one")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 5, length: 0))

        textView.replaceText(with: "x = ")
        textView.setSelectedRange(NSRange(location: 4, length: 0))
        typeAtCursor("'", into: textView, host: host)
        host.manager.beginUndoGrouping()
        textView.deleteBackward(nil)
        host.manager.endUndoGrouping()
        XCTAssertEqual(textView.string, "x = ", "Backspace in an empty string removes both quotes")
        window.close()
    }

    /// A paired quote still opens a script's variable names, and the name accepted lands before the closing quote.
    func testAPairedQuoteOpensVariableNamesBetweenTheQuotes() {
        let textView = makeTextView(isSingleLine: false, text: "get()")
        textView.language = .javascript
        let presenter = RecordingPopups()
        let assistant = FakeScriptAssistant()
        textView.assistance.presenter = presenter
        textView.assistance.assistant = assistant
        retained.append(assistant)
        let window = focus(textView)
        textView.setSelectedRange(NSRange(location: 4, length: 0))

        textView.insertText("\"", replacementRange: textView.selectedRange())
        XCTAssertEqual(textView.string, "get(\"\")")
        XCTAssertEqual(presenter.completions?.items.map(\.label), ["api-key", "api-secret"])
        textView.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        XCTAssertEqual(textView.string, "get(\"api-key\")")
        textView.insertText("\"", replacementRange: textView.selectedRange())
        XCTAssertEqual(textView.string, "get(\"api-key\")")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 13, length: 0), "past the closing quote")
        window.close()
    }

    /// A `}` typed before its pair at the start of a line steps over it without doubling it, and moves it back to the
    /// opener's indentation as one undo step.
    func testAClosingBraceBeforeItsPairStepsOverAndReindents() {
        let host = UndoHost()
        let textView = makeTextView(isSingleLine: false, text: "if (ok) {\n  a()\n  }", delegate: host)
        textView.language = .javascript
        let window = focus(textView)
        textView.setSelectedRange(NSRange(location: 18, length: 0))

        typeAtCursor("}", into: textView, host: host)
        XCTAssertEqual(textView.string, "if (ok) {\n  a()\n}")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 17, length: 0), "after the brace")
        host.manager.undo()
        XCTAssertEqual(textView.string, "if (ok) {\n  a()\n  }")
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
