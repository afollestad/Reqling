import AppKit
import ReqlingKit
import SwiftUI
import XCTest

@testable import Reqling

/// Lines of code inserted from outside the text view, as the Scripts pane's snippet menu does.
extension CodeTextViewTests {
    func testInsertedLinesAreOneNamedUndoStepThatReachesTheBindingAndSelectsThePlaceholder() {
        let host = UndoHost()
        let textView = makeTextView(isSingleLine: false, text: "a()", delegate: host)
        textView.language = .javascript
        let window = focus(textView)
        defer { window.close() }
        window.makeFirstResponder(nil)

        let code = #"rq.environment.set("name", "value")"#
        host.manager.beginUndoGrouping()
        XCTAssertTrue(textView.insertLinesAsUserEdit(code, placeholder: NSRange(location: 20, length: 4), actionName: "Insert Snippet"))
        host.manager.endUndoGrouping()

        XCTAssertEqual(textView.string, "a()\n" + code)
        XCTAssertEqual((textView.string as NSString).substring(with: textView.selectedRange()), "name")
        XCTAssertIdentical(window.firstResponder, textView, "focused, so typing replaces the placeholder")
        XCTAssertEqual(host.reported.last, textView.string)
        XCTAssertEqual(host.manager.undoActionName, "Insert Snippet")
        host.manager.undo()
        XCTAssertEqual(textView.string, "a()")
    }

    func testADisabledEditorTakesNoInsertedLines() {
        let textView = makeTextView(isSingleLine: false, text: "a()")
        textView.isEditable = false

        XCTAssertFalse(textView.insertLinesAsUserEdit("b()", placeholder: nil, actionName: "Insert Snippet"))
        XCTAssertEqual(textView.string, "a()")
    }

    /// An editor never clicked into has its cursor after the text, so a snippet goes after the last line.
    func testTheHandleInsertsAfterTheLastLineOfAnEditorNeverFocused() throws {
        let inputs = SnippetEditorInputs()
        let handle = CodeEditorHandle()
        let hosting = NSHostingView(rootView: SnippetEditor(inputs: inputs, handle: handle))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        defer { window.close() }
        hosting.layoutSubtreeIfNeeded()
        _ = try XCTUnwrap(handle.textView)

        XCTAssertTrue(handle.insertLines("c()", placeholder: nil, actionName: "Insert Snippet"))

        XCTAssertEqual(inputs.text, "a()\nb()\nc()")
    }
}

@MainActor
@Observable
private final class SnippetEditorInputs {
    var text = "a()\nb()"
}

private struct SnippetEditor: View {
    @Bindable var inputs: SnippetEditorInputs
    let handle: CodeEditorHandle

    var body: some View {
        CodeEditor(text: $inputs.text, language: .javascript, accessibilityLabel: "Script", handle: handle)
    }
}
