import AppKit
import ReqlingKit
import ReqlingScriptProtocol
import XCTest

@testable import Reqling

/// The script editor's own completion over a pre-request script, for typing through the text view with its pairs and
/// indentation: `ScriptsEditorModel` shapes the analyzer's lists this same way.
@MainActor
final class ScriptCatalogAssistant: CodeEditorAssistant {
    private let context = ScriptAnalysisContext(phase: .preRequest, protocols: ScriptAnalysisContext.protocols(for: .http))

    func completions(in text: String, cursor: Int) -> CodeCompletionList? {
        ScriptAnalyzer(text: text, context: context).completions(at: cursor).flatMap {
            ScriptsEditorModel.completionList($0, describeVariable: nil)
        }
    }

    func hover(in text: String, at offset: Int) -> CodeHoverContent? {
        nil
    }

    func opensCompletion(_ typed: String, before cursor: Int, in text: NSString) -> Bool {
        ScriptsEditorModel.opensScriptCompletion(typed, before: cursor, in: text)
    }
}

extension CodeTextViewTests {
    /// Types a request's options as the editor leaves them: `(` and `{` paired, Return moving `})` down and indenting,
    /// a key accepted with its colon, and a method picked inside paired quotes.
    func testAnOptionsLiteralTypedThroughPairsAndIndentationCompletesItsKeysAndValues() throws {
        let textView = makeTextView(isSingleLine: false, text: "")
        textView.language = .javascript
        textView.showsTemplateTokens = false
        let presenter = RecordingPopups()
        let assistant = ScriptCatalogAssistant()
        textView.assistance.presenter = presenter
        textView.assistance.assistant = assistant
        retained.append(assistant)
        let window = focus(textView)
        let typeEach = { (text: String) in
            for character in text {
                textView.insertText(String(character), replacementRange: textView.selectedRange())
            }
        }
        let returnKey = { textView.doCommand(by: #selector(NSResponder.insertNewline(_:))) }

        typeEach("rq.sendRequest")
        textView.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        typeEach("({")
        XCTAssertEqual(textView.string, "rq.sendRequest({})")
        returnKey()
        XCTAssertEqual(textView.string, "rq.sendRequest({\n  \n})")
        typeEach("u")
        XCTAssertEqual(presenter.completions?.items.map(\.label), ["url"])
        returnKey()
        typeEach("\"x\",")
        returnKey()
        typeEach("m")
        XCTAssertEqual(presenter.completions?.items.map(\.label), ["method"], "`url` is written already")
        returnKey()
        typeEach("\"p")
        XCTAssertEqual(presenter.completions?.items.map(\.label), ["POST", "PUT", "PATCH"])
        returnKey()

        XCTAssertEqual(textView.string, "rq.sendRequest({\n  url: \"x\",\n  method: \"POST\"\n})")
        let closingQuote = (textView.string as NSString).range(of: "POST").upperBound
        XCTAssertEqual(textView.selectedRange(), NSRange(location: closingQuote, length: 0), "inside the paired quotes")
        window.close()
    }
}
