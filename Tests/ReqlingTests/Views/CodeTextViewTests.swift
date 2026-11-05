import AppKit
import ReqlingKit
import XCTest

@testable import Reqling

/// Drives `CodeTextView` directly, unhosted or in an offscreen window; its undo manager comes from the delegate.
@MainActor
final class CodeTextViewTests: XCTestCase {
    private let tokenContext = TemplateTokenContext(entries: ["token": .init(displayValue: "t", sourceName: "Default")])

    // MARK: - Completion

    func testCompletionIsNotOfferedOutsideATemplate() {
        let textView = makeTextView(isSingleLine: true, text: "https://x/to")
        var index = -1

        XCTAssertEqual(textView.rangeForUserCompletion.location, NSNotFound)
        XCTAssertNil(textView.completions(forPartialWordRange: NSRange(location: 10, length: 2), indexOfSelectedItem: &index))
    }

    func testCompletionInsideATemplateOffersNamesAndCloses() throws {
        let textView = makeTextView(isSingleLine: true, text: "x/{{to")
        var index = -1
        let range = textView.rangeForUserCompletion

        XCTAssertEqual(range, NSRange(location: 4, length: 2))
        XCTAssertEqual(try XCTUnwrap(textView.completions(forPartialWordRange: range, indexOfSelectedItem: &index)), ["token"])
        textView.insertCompletion("token", forPartialWordRange: range, movement: NSReturnTextMovement, isFinal: true)
        XCTAssertEqual(textView.string, "x/{{token}}")
    }

    // MARK: - Pills

    /// A field gets its text before its variables are known; the pills must take the later states, not keep the first.
    func testPillsTakeTheTokenStatesSetAfterTheText() throws {
        let textView = CodeTextView.make(isSingleLine: true)
        textView.setInitialText("{{token}}/{{missing}}")
        XCTAssertEqual(pillFills(in: textView), [fill(.unresolved, in: textView), fill(.unresolved, in: textView)])

        textView.tokenContext = tokenContext

        XCTAssertEqual(pillFills(in: textView), [fill(.resolved, in: textView), fill(.unresolved, in: textView)])
    }

    // MARK: - Keys

    func testEscapeGoesUpTheResponderChainInsteadOfCompleting() {
        let textView = makeTextView(isSingleLine: true, text: "{{")
        let probe = CancelProbe()
        textView.nextResponder = probe

        textView.doCommand(by: #selector(NSResponder.cancelOperation(_:)))

        XCTAssertTrue(probe.didCancel)
        XCTAssertEqual(textView.string, "{{")
    }

    func testReturnSubmitsASingleLineField() {
        let textView = makeTextView(isSingleLine: true, text: "a")
        var submitted = false
        textView.onSubmit = { submitted = true }

        textView.insertNewline(nil)

        XCTAssertTrue(submitted)
        XCTAssertEqual(textView.string, "a")
    }

    // MARK: - Single Line

    func testSingleLineFlattensLineBreaks() {
        XCTAssertEqual(CodeTextView.singleLine("a\nb"), "a b")
        XCTAssertEqual(CodeTextView.singleLine("\na\r\n\r\nb\n"), "a b")
        XCTAssertEqual(CodeTextView.singleLine("\n"), "")
    }

    func testSingleLineFieldNeverTakesANewline() {
        let textView = makeTextView(isSingleLine: true, text: "")

        textView.insertText("x\ny\r\nz", replacementRange: NSRange(location: 0, length: 0))
        XCTAssertEqual(textView.string, "x y z")
        textView.insertNewlineIgnoringFieldEditor(nil)
        XCTAssertEqual(textView.string, "x y z")
    }

    func testMultiLineEditorKeepsNewlines() {
        let textView = makeTextView(isSingleLine: false, text: "")

        textView.insertText("x\ny", replacementRange: NSRange(location: 0, length: 0))

        XCTAssertEqual(textView.string, "x\ny")
    }

    // MARK: - Text From Outside

    func testOutsideChangeIsNeverAnUndoStepAndDropsTheEditorsHistory() {
        let host = UndoHost()
        let textView = makeTextView(isSingleLine: false, text: "abc", delegate: host)
        let window = focus(textView)
        defer { window.close() }
        XCTAssertFalse(host.manager.canUndo, "the first content is not an undo step")
        type("d", into: textView, host: host)

        textView.replaceText(with: "{\n}")

        XCTAssertEqual(textView.string, "{\n}")
        XCTAssertFalse(host.manager.canUndo)
    }

    /// The window's one undo manager serves every field; a row shifting into an unfocused field must not become a step
    /// that ⌘Z in the focused field replays.
    func testOutsideChangeToAnUnfocusedEditorLeavesTheFocusedHistoryAlone() {
        let host = UndoHost()
        let focused = makeTextView(isSingleLine: true, text: "a", delegate: host)
        let other = makeTextView(isSingleLine: true, text: "verbose", delegate: host)
        let window = focus(focused, alongside: other)
        defer { window.close() }
        host.manager.beginUndoGrouping()
        focused.insertText("b", replacementRange: NSRange(location: 1, length: 0))
        host.manager.endUndoGrouping()

        other.replaceText(with: "q")
        host.manager.undo()

        XCTAssertEqual(other.string, "q")
        XCTAssertEqual(focused.string, "a")
        XCTAssertFalse(host.manager.canUndo)
    }

    /// ⌘F's find bar, or any SwiftUI field, takes first responder; coming back must still undo.
    func testFocusLeavingForAnotherResponderAndBackKeepsHistory() {
        let host = UndoHost()
        let textView = makeTextView(isSingleLine: true, text: "a", delegate: host)
        let window = focus(textView)
        defer { window.close() }
        let sink = FocusSink(frame: NSRect(x: 0, y: 40, width: 20, height: 20))
        window.contentView?.addSubview(sink)
        type("b", into: textView, host: host)

        XCTAssertTrue(window.makeFirstResponder(sink))
        XCTAssertTrue(window.makeFirstResponder(textView))
        host.manager.undo()

        XCTAssertEqual(textView.string, "a")
    }

    func testFocusingAnotherEditorDropsTheFirstOnesHistory() {
        let host = UndoHost()
        let first = makeTextView(isSingleLine: true, text: "a", delegate: host)
        let second = makeTextView(isSingleLine: true, text: "x", delegate: host)
        let window = focus(first, alongside: second)
        defer { window.close() }
        type("b", into: first, host: host)

        XCTAssertTrue(window.makeFirstResponder(second))

        XCTAssertEqual(first.string, "ab")
        XCTAssertFalse(host.manager.canUndo)
    }

    /// A sheet's window has its own undo manager; focusing an editor there must leave the main window's history alone.
    func testFocusingAnEditorWithAnotherUndoManagerKeepsTheFirstOnesHistory() {
        let mainHost = UndoHost()
        let sheetHost = UndoHost()
        let main = makeTextView(isSingleLine: true, text: "a", delegate: mainHost)
        let sheet = makeTextView(isSingleLine: true, text: "x", delegate: sheetHost)
        let mainWindow = focus(main)
        let sheetWindow = focus(sheet)
        defer {
            mainWindow.close()
            sheetWindow.close()
        }
        type("b", into: main, host: mainHost)

        XCTAssertTrue(sheetWindow.makeFirstResponder(sheet))

        XCTAssertTrue(mainHost.manager.canUndo)
        mainHost.manager.undo()
        XCTAssertEqual(main.string, "a")
    }

    /// Marked text never reaches the binding, so a re-render mid-composition must not delete it under the input method.
    func testOutsideChangeWaitsWhileAnInputMethodIsComposing() {
        let textView = makeTextView(isSingleLine: true, text: "a")
        textView.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: 1, length: 0))
        XCTAssertTrue(textView.hasMarkedText())

        textView.replaceText(with: "a")

        XCTAssertEqual(textView.string, "aか")
        XCTAssertTrue(textView.hasMarkedText())
    }

    /// Clicking into the response to copy from it must not cost the body editor its history.
    func testFocusingTheResponseViewerKeepsTheEditorsHistory() {
        let host = UndoHost()
        let editor = makeTextView(isSingleLine: false, text: "a", delegate: host)
        let window = focus(editor)
        defer { window.close() }
        let viewer = CodeViewerView(frame: NSRect(x: 0, y: 30, width: 300, height: 100))
        viewer.setDocument(TextDocument(text: "response", language: .plainText))
        window.contentView?.addSubview(viewer)
        type("b", into: editor, host: host)

        XCTAssertTrue(window.makeFirstResponder(viewer.documentView))

        XCTAssertTrue(host.manager.canUndo)
    }

    func testAChangeThatWaitedOnACancelledCompositionApplies() {
        let textView = makeTextView(isSingleLine: true, text: "a")
        textView.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: 1, length: 0))
        textView.replaceText(with: "b")
        XCTAssertEqual(textView.string, "aか")

        textView.setMarkedText("", selectedRange: NSRange(location: 0, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))

        XCTAssertFalse(textView.hasMarkedText())
        XCTAssertEqual(textView.string, "b")
    }

    func testACommittedCompositionWinsOverAWaitingChange() {
        let textView = makeTextView(isSingleLine: true, text: "a")
        textView.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: 1, length: 0))
        textView.replaceText(with: "b")

        textView.insertText("漢", replacementRange: textView.markedRange())

        XCTAssertEqual(textView.string, "a漢")
        XCTAssertNil(textView.textWaitingOnComposition)
    }

    /// Beautify is the user's own edit, so unlike an outside change it is one undo step and reaches the binding.
    func testAUserEditFromAButtonIsOneNamedUndoStepAndReachesTheBinding() {
        let host = UndoHost()
        let textView = makeTextView(isSingleLine: false, text: #"{"a":1}"#, delegate: host)
        let window = focus(textView)
        defer { window.close() }

        host.manager.beginUndoGrouping()
        XCTAssertTrue(textView.replaceAllAsUserEdit(with: "{\n  \"a\" : 1\n}", actionName: "Beautify"))
        host.manager.endUndoGrouping()

        XCTAssertEqual(host.reported.last, "{\n  \"a\" : 1\n}")
        XCTAssertEqual(host.manager.undoActionName, "Beautify")
        host.manager.undo()
        XCTAssertEqual(textView.string, #"{"a":1}"#)
    }

    func testFindOpensTheFindBarOnlyInAFocusedMultiLineEditor() {
        let body = makeTextView(isSingleLine: false, text: "needle in a haystack")
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        scrollView.documentView = body
        let window = NSWindow(contentRect: scrollView.frame, styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = scrollView
        defer { window.close() }
        XCTAssertTrue(window.makeFirstResponder(body))

        XCTAssertTrue(CodeTextView.performFind(.showFindInterface, in: window))
        XCTAssertTrue(scrollView.isFindBarVisible)

        let field = makeTextView(isSingleLine: true, text: "needle")
        let fieldWindow = focus(field)
        defer { fieldWindow.close() }
        XCTAssertFalse(CodeTextView.performFind(.showFindInterface, in: fieldWindow))
    }

    /// The find bar's search field takes focus once the bar opens; ⌘G typed there must still reach its editor.
    func testFindNextFromAFieldInsideTheEditorsScrollViewTargetsThatEditor() {
        let body = makeTextView(isSingleLine: false, text: "needle in a haystack")
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        scrollView.documentView = body
        let searchField = NSSearchField(frame: NSRect(x: 0, y: 0, width: 120, height: 22))
        scrollView.addSubview(searchField)
        let window = NSWindow(contentRect: scrollView.frame, styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = scrollView
        defer { window.close() }

        XCTAssertTrue(window.makeFirstResponder(searchField))

        XCTAssertTrue(CodeTextView.findTarget(for: window.firstResponder) === body)
    }

    /// A removed table row or a switched tab takes its editor out of the window.
    func testLeavingTheWindowDropsTheEditorsHistory() {
        let host = UndoHost()
        let textView = makeTextView(isSingleLine: true, text: "a", delegate: host)
        let window = focus(textView)
        defer { window.close() }
        type("b", into: textView, host: host)

        textView.removeFromSuperview()

        XCTAssertFalse(host.manager.canUndo)
    }

    func testOutsideChangeKeepsASelectionOutsideTheChangedSpan() {
        let textView = makeTextView(isSingleLine: true, text: "hello world")

        textView.setSelectedRange(NSRange(location: 9, length: 0))
        textView.replaceText(with: "hello there world")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 15, length: 0))

        textView.setSelectedRange(NSRange(location: 2, length: 0))
        textView.replaceText(with: "hello world")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 2, length: 0))
    }

    /// Puts the views in an offscreen window and focuses the first, as a click into it would.
    private func focus(_ textView: CodeTextView, alongside others: CodeTextView...) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let container = NSView(frame: window.contentLayoutRect)
        for view in [textView] + others {
            view.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
            container.addSubview(view)
        }
        window.contentView = container
        XCTAssertTrue(window.makeFirstResponder(textView))
        return window
    }

    /// Types at the end as one undo step; the host's manager does not group by event.
    private func type(_ text: String, into textView: CodeTextView, host: UndoHost) {
        host.manager.beginUndoGrouping()
        textView.insertText(text, replacementRange: NSRange(location: (textView.string as NSString).length, length: 0))
        host.manager.endUndoGrouping()
        XCTAssertTrue(host.manager.canUndo)
    }

    private func pillFills(in textView: CodeTextView) -> [CGColor] {
        guard let layoutManager = textView.textLayoutManager, let content = layoutManager.textContentManager else {
            return []
        }
        var fills: [CGColor] = []
        layoutManager.enumerateTextLayoutFragments(from: content.documentRange.location, options: [.ensuresLayout]) { fragment in
            fills += (fragment as? TokenLayoutFragment)?.pills.map(\.fill) ?? []
            return true
        }
        return fills
    }

    private func fill(_ state: TemplateTokenState, in textView: CodeTextView) -> CGColor {
        var color = CGColor(gray: 0, alpha: 0)
        textView.effectiveAppearance.performAsCurrentDrawingAppearance {
            color = SyntaxPalette.tokenFill(for: state, accent: textView.accentColor).cgColor
        }
        return color
    }

    private func makeTextView(isSingleLine: Bool, text: String, delegate: (any NSTextViewDelegate)? = nil) -> CodeTextView {
        let textView = CodeTextView.make(isSingleLine: isSingleLine)
        textView.delegate = delegate
        textView.tokenContext = tokenContext
        textView.setInitialText(text)
        textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        return textView
    }
}

/// Supplies the undo manager a window would; grouping is explicit because no run loop turns between steps.
@MainActor
private final class UndoHost: NSObject, NSTextViewDelegate {
    let manager: UndoManager = {
        let manager = UndoManager()
        manager.groupsByEvent = false
        return manager
    }()
    /// The text after each change the view reported, as the binding would receive it.
    private(set) var reported: [String] = []

    func undoManager(for view: NSTextView) -> UndoManager? {
        manager
    }

    func textDidChange(_ notification: Notification) {
        if let textView = notification.object as? NSTextView {
            reported.append(textView.string)
        }
    }
}

/// A responder that is not an editor, standing in for the find bar or a SwiftUI field.
private final class FocusSink: NSView {
    override var acceptsFirstResponder: Bool {
        true
    }
}

private final class CancelProbe: NSResponder {
    private(set) var didCancel = false

    override func cancelOperation(_ sender: Any?) {
        didCancel = true
    }
}
