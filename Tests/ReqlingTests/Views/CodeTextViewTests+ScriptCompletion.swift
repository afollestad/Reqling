import AppKit
import ReqlingKit
import XCTest

@testable import Reqling

/// An assistant with its own triggers (`.`) and a variable-name list, as the script editor's is.
@MainActor
final class FakeScriptAssistant: CodeEditorAssistant {
    func completions(in text: String, cursor: Int) -> CodeCompletionList? {
        let units = Array(text.utf16.prefix(cursor))
        var start = units.count
        while start > 0, let scalar = Unicode.Scalar(units[start - 1]), !"\".".unicodeScalars.contains(scalar) {
            start -= 1
        }
        let typed = String(decoding: units[start...], as: UTF16.self)
        let items = ["api-key", "api-secret"].filter { $0.hasPrefix(typed) }.enumerated().map { index, name in
            CodeCompletionItem(id: index, label: name, kind: .scriptVariable, detail: nil, summary: nil, isDeprecated: false, insertText: name)
        }
        return CodeCompletionList(replacementRange: NSRange(location: start, length: cursor - start), items: items, nameCharacters: .variableName)
    }

    func hover(in text: String, at offset: Int) -> CodeHoverContent? {
        nil
    }

    func opensCompletion(_ typed: String, before cursor: Int, in text: NSString) -> Bool {
        typed == "." || typed == "\""
    }
}

extension CodeTextViewTests {
    /// The script editor's list opens on its own triggers, and a variable name's `-` narrows it rather than closing it.
    func testAnAssistantsOwnTriggersAndNameCharactersApply() throws {
        let textView = makeTextView(isSingleLine: false, text: "get(", delegate: nil)
        let presenter = RecordingPopups()
        let assistant = FakeScriptAssistant()
        textView.assistance.presenter = presenter
        textView.assistance.assistant = assistant
        retained.append(assistant)
        let window = focus(textView)

        textView.insertText("\"", replacementRange: textView.selectedRange())
        XCTAssertEqual(presenter.completions?.items.map(\.label), ["api-key", "api-secret"])
        for character in ["a", "p", "i", "-", "s"] {
            textView.insertText(character, replacementRange: textView.selectedRange())
        }

        XCTAssertEqual(presenter.completions?.items.map(\.label), ["api-secret"], "`-` is part of a variable's name")
        window.close()
    }

    /// Where an editor doesn't show `{{variables}}`, as a script's doesn't, `{{` is plain text and the assistant's list
    /// still opens after it.
    func testBracesAreLiteralWhereTheEditorShowsNoVariables() throws {
        let (textView, presenter) = makeAssisted(text: "{{")
        textView.showsTemplateTokens = false
        let window = focus(textView)

        textView.insertText("n", replacementRange: textView.selectedRange())

        XCTAssertEqual(presenter.completions?.items.map(\.label), ["name", "nickname"])
        window.close()
    }
}
