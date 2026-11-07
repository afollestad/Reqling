import AppKit
import XCTest

@testable import Reqling

/// An assistant that knows one method, `call(first, second?)`, wherever a `(` is left open before the cursor, and
/// completes the methods `alpha(first)` and `beta()` and the property `gamma` as a name is typed.
@MainActor
final class FakeSignatureAssistant: CodeEditorSignatureAssistant {
    func completions(in text: String, cursor: Int) -> CodeCompletionList? {
        let before = (text as NSString).substring(to: cursor) as NSString
        let separator = before.rangeOfCharacter(from: CharacterSet.letters.inverted, options: .backwards)
        let start = separator.location == NSNotFound ? 0 : NSMaxRange(separator)
        let typed = before.substring(from: start)
        let names: [(String, CodeCompletionItem.Parentheses?)] = [("alpha", .withArguments), ("beta", .withoutArguments), ("gamma", nil)]
        let items = names.filter { $0.0.hasPrefix(typed) }.enumerated().map { index, entry in
            CodeCompletionItem(id: index, label: entry.0, kind: .method, detail: nil, summary: nil, isDeprecated: false, insertText: entry.0,
                               parentheses: entry.1)
        }
        return CodeCompletionList(replacementRange: NSRange(location: start, length: cursor - start), items: items)
    }

    func hover(in text: String, at offset: Int) -> CodeHoverContent? {
        nil
    }

    func signatureHelp(in text: String, cursor: Int) -> CodeSignatureHelp? {
        let before = (text as NSString).substring(to: cursor) as NSString
        let open = before.range(of: "(", options: .backwards).location
        guard open != NSNotFound, !before.substring(from: open).contains(")") else {
            return nil
        }
        let argument = before.substring(from: open).filter { $0 == "," }.count
        return CodeSignatureHelp(
            name: "Thing.call",
            parameters: [
                .init(name: "first", label: "first: string", summary: "The first."),
                .init(name: "second", label: "second?: number", summary: nil)
            ],
            returnType: "void",
            activeParameter: argument < 2 ? argument : nil,
            summary: "Calls the thing.",
            anchor: open
        )
    }
}

extension CodeTextViewTests {
    func testTypingAParenthesisOrCommaShowsTheArgumentBeingTyped() {
        let (textView, presenter) = makeSignatureAssisted(text: "call")
        let window = focus(textView)

        textView.insertText("(", replacementRange: textView.selectedRange())
        XCTAssertEqual(presenter.signature?.activeParameter, 0)
        XCTAssertEqual(presenter.signature?.anchor, 4)
        textView.insertText("1", replacementRange: textView.selectedRange())
        textView.insertText(",", replacementRange: textView.selectedRange())
        XCTAssertEqual(presenter.signature?.activeParameter, 1)
        textView.insertText(")", replacementRange: textView.selectedRange())
        XCTAssertNil(presenter.signature, "closing the call closes the hints")
        window.close()
    }

    func testOpenHintsFollowTheCursorButAClickIntoACallOpensNone() {
        let (textView, presenter) = makeSignatureAssisted(text: "call(1, 2) + 3")
        let window = focus(textView)

        textView.setSelectedRange(NSRange(location: 6, length: 0))
        XCTAssertNil(presenter.signature, "moving into a call opens nothing")
        textView.showParameterHints()
        XCTAssertEqual(presenter.signature?.activeParameter, 0)
        textView.setSelectedRange(NSRange(location: 9, length: 0))
        XCTAssertEqual(presenter.signature?.activeParameter, 1)
        textView.setSelectedRange(NSRange(location: 13, length: 0))
        XCTAssertNil(presenter.signature, "leaving the call closes them")
        window.close()
    }

    func testEscapeClosesTheListThenTheHintsWithoutReachingASheet() {
        let (textView, presenter) = makeSignatureAssisted(text: "call")
        let window = focus(textView)
        let probe = CancelProbe()
        textView.insertText("(", replacementRange: textView.selectedRange())
        textView.insertText("a", replacementRange: textView.selectedRange())
        textView.nextResponder = probe
        XCTAssertNotNil(presenter.completions)
        XCTAssertNotNil(presenter.signature, "both show at once")

        textView.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        XCTAssertNil(presenter.completions)
        XCTAssertNotNil(presenter.signature, "the list closes first")
        textView.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        XCTAssertNil(presenter.signature)
        XCTAssertFalse(probe.didCancel)
        textView.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        XCTAssertTrue(probe.didCancel, "with both closed, Escape goes up the chain")
        window.close()
    }

    /// Sent as the window offers key equivalents, to every view in it.
    func testShortcutsShowHintsInTheFocusedEditorWithAnAssistantThatHasThem() throws {
        let (first, firstPresenter) = makeSignatureAssisted(text: "call(")
        let (focused, focusedPresenter) = makeSignatureAssisted(text: "call(")
        let (graphQL, graphQLPresenter) = makeAssisted(text: "call(")
        let window = focus(focused, alongside: first, graphQL)

        XCTAssertTrue(window.performKeyEquivalent(with: try Self.shortcut("p", modifiers: .command, keyCode: 35, in: window)))
        XCTAssertNotNil(focusedPresenter.signature, "⌘P")
        XCTAssertNil(firstPresenter.signature, "only the focused editor answers")
        focused.hideSignatureHelp()
        XCTAssertTrue(window.performKeyEquivalent(with: try Self.shortcut(" ", modifiers: [.command, .shift], keyCode: 49, in: window)))
        XCTAssertNotNil(focusedPresenter.signature, "⇧⌘Space")

        XCTAssertTrue(window.makeFirstResponder(graphQL))
        XCTAssertFalse(window.performKeyEquivalent(with: try Self.shortcut("p", modifiers: .command, keyCode: 35, in: window)),
                       "an editor without hints leaves ⌘P to Print")
        XCTAssertNil(graphQLPresenter.signature)
        window.close()
    }

    /// Edit ▸ Show Parameter Hints acts on the focused editor, and only one whose assistant has hints.
    func testTheMenuItemShowsHintsInTheFocusedEditorWithHints() {
        let (textView, presenter) = makeSignatureAssisted(text: "call(")
        let (graphQL, _) = makeAssisted(text: "call(")
        let window = focus(textView, alongside: graphQL)

        XCTAssertTrue(CodeTextView.showParameterHints(in: window))
        XCTAssertNotNil(presenter.signature)
        XCTAssertTrue(window.makeFirstResponder(graphQL))
        XCTAssertFalse(CodeTextView.showParameterHints(in: window))
        XCTAssertFalse(CodeTextView.showParameterHints(in: nil))
        window.close()
    }

    func testScrollingOrLosingFocusClosesTheHints() throws {
        let (textView, presenter) = makeSignatureAssisted(text: "call(")
        let window = focus(textView)
        textView.showParameterHints()
        XCTAssertNotNil(presenter.signature)

        let wheel = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -30, wheel2: 0, wheel3: 0))
        textView.scrollWheel(with: try XCTUnwrap(NSEvent(cgEvent: wheel)))
        XCTAssertNil(presenter.signature, "a scroll")
        textView.showParameterHints()
        XCTAssertTrue(window.makeFirstResponder(nil))
        XCTAssertNil(presenter.signature, "focus leaving")
        window.close()
    }

    func testAcceptingAMethodAddsItsParenthesesAndHintsAsOneUndoStep() {
        let host = UndoHost()
        let (textView, presenter) = makeSignatureAssisted(text: "x = ", delegate: host)
        let window = focus(textView)
        type("a", into: textView, host: host)
        type("l", into: textView, host: host)

        host.manager.beginUndoGrouping()
        textView.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        host.manager.endUndoGrouping()

        XCTAssertEqual(textView.string, "x = alpha()")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 10, length: 0), "between the parentheses")
        XCTAssertEqual(presenter.signature?.activeParameter, 0)
        host.manager.undo()
        XCTAssertEqual(textView.string, "x = al")
        window.close()
    }

    func testAcceptingAMethodWithoutArgumentsOrBeforeACallPlacesTheCursorAfter() {
        let (textView, presenter) = makeSignatureAssisted(text: "x = ")
        let window = focus(textView)
        textView.insertText("b", replacementRange: textView.selectedRange())
        textView.doCommand(by: #selector(NSResponder.insertTab(_:)))
        XCTAssertEqual(textView.string, "x = beta()")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 10, length: 0))
        XCTAssertNil(presenter.signature)

        textView.replaceText(with: "x = (1)")
        textView.setSelectedRange(NSRange(location: 4, length: 0))
        textView.insertText("a", replacementRange: textView.selectedRange())
        textView.doCommand(by: #selector(NSResponder.insertTab(_:)))
        XCTAssertEqual(textView.string, "x = alpha(1)", "a `(` already there is the call's")

        textView.replaceText(with: "x = ")
        textView.setSelectedRange(NSRange(location: 4, length: 0))
        textView.insertText("g", replacementRange: textView.selectedRange())
        textView.doCommand(by: #selector(NSResponder.insertTab(_:)))
        XCTAssertEqual(textView.string, "x = gamma", "a property gets none")
        window.close()
    }

    func testADisabledEditorShowsNoHints() {
        let (textView, presenter) = makeSignatureAssisted(text: "call(")
        let window = focus(textView)
        textView.isEditable = false

        textView.showParameterHints()
        XCTAssertNil(presenter.signature)
        window.close()
    }

    func makeSignatureAssisted(text: String, delegate: (any NSTextViewDelegate)? = nil) -> (CodeTextView, RecordingPopups) {
        let textView = makeTextView(isSingleLine: false, text: text, delegate: delegate)
        let presenter = RecordingPopups()
        let assistant = FakeSignatureAssistant()
        textView.assistance.presenter = presenter
        textView.assistance.assistant = assistant
        retained.append(assistant)
        return (textView, presenter)
    }

    private static func shortcut(_ key: String, modifiers: NSEvent.ModifierFlags, keyCode: UInt16, in window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            characters: key,
            charactersIgnoringModifiers: key,
            isARepeat: false,
            keyCode: keyCode
        ))
    }
}
