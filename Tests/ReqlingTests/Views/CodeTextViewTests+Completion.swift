import AppKit
import ReqlingKit
import XCTest

@testable import Reqling

/// The assistant's completion list and hover card, driven by a fake assistant and a presenter that records what it
/// would show, so no panel ever reaches the screen.
extension CodeTextViewTests {
    func testTypingANameCharacterOpensTheListAtTheNameBeingTyped() throws {
        let (textView, presenter) = makeAssisted(text: "{ ")
        let window = focus(textView)

        textView.insertText("n", replacementRange: textView.selectedRange())

        let model = try XCTUnwrap(presenter.completions)
        XCTAssertEqual(model.items.map(\.label), ["name", "nickname"])
        XCTAssertEqual(presenter.completionAnchors.count, 1)
        textView.insertText("i", replacementRange: textView.selectedRange())
        XCTAssertEqual(presenter.completions?.items.map(\.label), ["nickname"], "typing narrows the same list")
        textView.deleteBackward(nil)
        XCTAssertEqual(presenter.completions?.items.map(\.label), ["name", "nickname"], "so does Backspace")
        window.close()
    }

    func testReturnAcceptsTheHighlightedItemAsOneUndoStep() throws {
        let host = UndoHost()
        let (textView, presenter) = makeAssisted(text: "{ ", delegate: host)
        let window = focus(textView)
        type("n", into: textView, host: host)
        type("i", into: textView, host: host)
        XCTAssertNotNil(presenter.completions)

        host.manager.beginUndoGrouping()
        textView.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        host.manager.endUndoGrouping()

        XCTAssertEqual(textView.string, "{ nickname")
        XCTAssertNil(presenter.completions)
        host.manager.undo()
        XCTAssertEqual(textView.string, "{ ni", "one undo brings back what was typed")
        window.close()
    }

    func testArrowsMoveTheHighlightAndTabAccepts() throws {
        let (textView, presenter) = makeAssisted(text: "{ ")
        let window = focus(textView)
        textView.insertText("n", replacementRange: textView.selectedRange())

        textView.doCommand(by: #selector(NSResponder.moveDown(_:)))
        textView.doCommand(by: #selector(NSResponder.moveDown(_:)))
        XCTAssertEqual(presenter.completions?.highlighted, 1, "the highlight stops at the end")
        textView.doCommand(by: #selector(NSResponder.moveUp(_:)))
        textView.doCommand(by: #selector(NSResponder.moveDown(_:)))
        textView.doCommand(by: #selector(NSResponder.insertTab(_:)))

        XCTAssertEqual(textView.string, "{ nickname")
        window.close()
    }

    func testEscapeClosesTheListWithoutReachingASheet() {
        let (textView, presenter) = makeAssisted(text: "{ ")
        let window = focus(textView)
        let probe = CancelProbe()
        textView.insertText("n", replacementRange: textView.selectedRange())
        textView.nextResponder = probe

        textView.doCommand(by: #selector(NSResponder.cancelOperation(_:)))

        XCTAssertNil(presenter.completions)
        XCTAssertFalse(probe.didCancel)
        textView.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        XCTAssertTrue(probe.didCancel, "with the list closed, Escape goes up the chain as before")
        window.close()
    }

    func testAnOpenTemplateKeepsAppKitsVariableCompletion() {
        let (textView, presenter) = makeAssisted(text: "{ x: ")
        let window = focus(textView)

        textView.insertText("{", replacementRange: textView.selectedRange())
        textView.insertText("{", replacementRange: textView.selectedRange())
        textView.insertText("t", replacementRange: textView.selectedRange())

        XCTAssertNil(presenter.completions)
        XCTAssertEqual(textView.rangeForUserCompletion, NSRange(location: 7, length: 1))
        window.close()
    }

    func testCompleteOpensTheListAnywhereAndBeepsOnlyWhereItCannot() throws {
        let (textView, presenter) = makeAssisted(text: "{ ")
        let assistant = try XCTUnwrap(textView.assistance.assistant as? FakeAssistant)
        let window = focus(textView)

        textView.complete(nil)
        XCTAssertEqual(presenter.completions?.items.count, 3, "with nothing typed, every name")
        textView.doCommand(by: #selector(NSResponder.cancelOperation(_:)))

        assistant.refusesEverything = true
        textView.complete(nil)
        XCTAssertNil(presenter.completions)
        window.close()
    }

    func testOnlyTypingOpensTheList() {
        let (textView, presenter) = makeAssisted(text: "{ ")
        let window = focus(textView)

        textView.replaceText(with: "{ n")
        textView.setSelectedRange(NSRange(location: 3, length: 0))
        XCTAssertNil(presenter.completions, "an outside change")
        textView.insertText("nam", replacementRange: textView.selectedRange())
        XCTAssertNil(presenter.completions, "a paste of several characters")
        textView.insertText(" ", replacementRange: textView.selectedRange())
        XCTAssertNil(presenter.completions, "a space after a name")
        window.close()
    }

    func testTheListClosesWhenTheCursorLeavesItsNameOrTheEditorItsFocus() {
        let (textView, presenter) = makeAssisted(text: "{ ")
        let other = makeTextView(isSingleLine: true, text: "")
        let window = focus(textView, alongside: other)

        textView.insertText("n", replacementRange: textView.selectedRange())
        textView.setSelectedRange(NSRange(location: 1, length: 0))
        XCTAssertNil(presenter.completions, "moved before the name")

        textView.setSelectedRange(NSRange(location: 3, length: 0))
        textView.insertText("i", replacementRange: textView.selectedRange())
        XCTAssertNotNil(presenter.completions)
        XCTAssertTrue(window.makeFirstResponder(other))
        XCTAssertNil(presenter.completions, "focus left")

        XCTAssertTrue(window.makeFirstResponder(textView))
        textView.insertText("c", replacementRange: textView.selectedRange())
        textView.setMarkedText("k", selectedRange: NSRange(location: 1, length: 0), replacementRange: textView.selectedRange())
        XCTAssertNil(presenter.completions, "an input method started composing")
        window.close()
    }

    /// Deactivating the app hides the panels; the list closes with them, so its keys stop.
    func testTheListClosesWhenItsWindowStopsBeingKey() {
        let (textView, presenter) = makeAssisted(text: "{ ")
        let window = focus(textView)
        textView.insertText("n", replacementRange: textView.selectedRange())
        XCTAssertNotNil(presenter.completions)

        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)

        XCTAssertNil(presenter.completions)
        textView.doCommand(by: #selector(NSResponder.moveDown(_:)))
        window.close()
    }

    func testAFullyTypedOnlyMatchOpensNothingAndAReadOnlyEditorNever() {
        let (textView, presenter) = makeAssisted(text: "{ nicknam")
        let window = focus(textView)

        textView.insertText("e", replacementRange: textView.selectedRange())
        XCTAssertNil(presenter.completions)

        textView.isEditable = false
        textView.complete(nil)
        textView.isEditable = true
        textView.insertText(" ", replacementRange: textView.selectedRange())
        textView.isEditable = false
        textView.insertText("n", replacementRange: textView.selectedRange())
        XCTAssertNil(presenter.completions)
        window.close()
    }

    func testAClickOnARowAcceptsIt() throws {
        let (textView, presenter) = makeAssisted(text: "{ ")
        let window = focus(textView)
        textView.insertText("n", replacementRange: textView.selectedRange())
        let model = try XCTUnwrap(presenter.completions)

        model.onAccept?(model.items[1])

        XCTAssertEqual(textView.string, "{ nickname")
        window.close()
    }

    // MARK: - Hover

    func testRestingOnANameShowsItsCardWithAnyProblemThere() async throws {
        let (textView, presenter) = makeAssisted(text: "{ name }")
        let window = focus(textView)
        textView.frame = NSRect(x: 0, y: 0, width: 300, height: 60)
        let gate = SleepGate()
        textView.assistance.sleep = { _ in await gate.sleep() }
        textView.diagnostics = CodeDiagnosticSet(text: textView.string, items: [
            CodeDiagnostic(range: NSRange(location: 2, length: 4), message: "Deprecated.", severity: .warning)
        ])
        let point = try XCTUnwrap(textView.segmentRects(for: NSRange(location: 3, length: 1)).first).center

        textView.hoverMoved(to: point)
        XCTAssertNil(presenter.hover, "not before the pointer has rested")
        await waitUntil("the hover delay") { gate.pendingCount == 1 }
        gate.releaseAll()
        await waitUntil("the card") { presenter.hover != nil }

        XCTAssertEqual(presenter.hover?.hover?.signature, "Thing.name: String")
        XCTAssertEqual(presenter.hover?.diagnostics.map(\.message), ["Deprecated."])
        textView.hoverMoved(to: NSPoint(x: point.x + 1, y: point.y))
        XCTAssertNotNil(presenter.hover, "it stays while the pointer stays on the name")
        textView.insertText("x", replacementRange: NSRange(location: 0, length: 0))
        XCTAssertNil(presenter.hover, "an edit hides it")
        window.close()
    }

    // MARK: - Support

    private func makeAssisted(
        text: String,
        delegate: (any NSTextViewDelegate)? = nil
    ) -> (CodeTextView, RecordingPopups) {
        let textView = makeTextView(isSingleLine: false, text: text, delegate: delegate)
        let presenter = RecordingPopups()
        let assistant = FakeAssistant()
        textView.assistance.presenter = presenter
        textView.assistance.assistant = assistant
        retained.append(assistant)
        return (textView, presenter)
    }
}

/// Offers `name`, `nickname`, and `id` for the name before the cursor, ranked by prefix, and describes `name`.
@MainActor
final class FakeAssistant: CodeEditorAssistant {
    var refusesEverything = false
    private let names = ["name", "nickname", "id"]

    func completions(in text: String, cursor: Int) -> CodeCompletionList? {
        guard !refusesEverything else {
            return nil
        }
        let units = Array(text.utf16.prefix(cursor))
        var start = units.count
        while start > 0, let scalar = Unicode.Scalar(units[start - 1]), CharacterSet.letters.contains(scalar) {
            start -= 1
        }
        let typed = String(decoding: units[start...], as: UTF16.self)
        let matching = names.filter { $0.hasPrefix(typed) }.enumerated().map { index, name in
            CodeCompletionItem(id: index, label: name, kind: .field, detail: "String", summary: nil, isDeprecated: false, insertText: name)
        }
        return CodeCompletionList(replacementRange: NSRange(location: start, length: cursor - start), items: matching)
    }

    func hover(in text: String, at offset: Int) -> CodeHoverContent? {
        let range = (text as NSString).range(of: "name")
        guard NSLocationInRange(offset, range) else {
            return nil
        }
        return CodeHoverContent(range: range, signature: "Thing.name: String", summary: nil, deprecationReason: nil)
    }
}

/// Records what would be on screen instead of showing it.
@MainActor
final class RecordingPopups: CodeEditorPopupPresenting {
    private(set) var completions: CodeCompletionModel?
    private(set) var completionAnchors: [NSRect] = []
    private(set) var hover: CodeHoverCardContent?

    func showCompletions(_ model: CodeCompletionModel, below anchor: NSRect, from view: NSView) {
        if completions !== model {
            completionAnchors.append(anchor)
        }
        completions = model
    }

    func hideCompletions() {
        completions = nil
    }

    func showHover(_ content: CodeHoverCardContent, below anchor: NSRect, from view: NSView) {
        hover = content
    }

    func hideHover() {
        hover = nil
    }
}

extension NSRect {
    var center: NSPoint {
        NSPoint(x: midX, y: midY)
    }
}
