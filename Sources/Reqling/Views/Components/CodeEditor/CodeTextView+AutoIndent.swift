import AppKit
import ReqlingKit

/// Return in a JSON, JavaScript, GraphQL, or YAML editor indents the new line and closes a bracket left open, and a `}`
/// or `]` typed at the start of its line moves back to its opener's indentation (`CodeIndent`).
extension CodeTextView {
    /// Applies `CodeIndent`'s edit for Return as one typed change; returns false to leave Return to AppKit: in other
    /// languages, with a selection, inside a string, or while an input method is composing.
    func insertIndentedNewline() -> Bool {
        let selection = selectedRange()
        guard isEditable, !hasMarkedText(), selection.length == 0,
              let edit = CodeIndent.newline(in: string, at: selection.location, language: language) else {
            return false
        }
        insertText(edit.replacement, replacementRange: edit.range)
        setSelectedRange(NSRange(location: edit.range.location + edit.caret, length: 0))
        return true
    }

    /// Types `typed` with its line re-indented when `CodeIndent` says so, as one typed change; returns false to type it
    /// as is. Only a single character typed over an empty selection qualifies, so the edit's own insertion never does.
    /// Every keystroke passes through here, so anything but a closer returns before the text is read.
    func insertDedentedCloser(_ typed: String, replacementRange: NSRange) -> Bool {
        guard typed == "}" || typed == "]" else {
            return false
        }
        let selection = selectedRange()
        guard isEditable, !hasMarkedText(), selection.length == 0,
              replacementRange.location == NSNotFound || replacementRange == selection,
              let edit = CodeIndent.typing(typed, in: string, at: selection.location, language: language) else {
            return false
        }
        insertText(edit.replacement, replacementRange: edit.range)
        setSelectedRange(NSRange(location: edit.range.location + edit.caret, length: 0))
        return true
    }
}
