import AppKit
import ReqlingKit

/// Parentheses typed in a JavaScript editor pair themselves (`CodePairs`): `(` brings its `)`, a `)` before one that
/// already closes its call steps over it, and Backspace between an empty `()` removes both. Each edit is one undo step,
/// and reaches the completion list and parameter hints as the key that was typed, so `(` still opens the hints.
extension CodeTextView {
    /// Types `typed` paired, or steps over a closer, when `CodePairs` says so; returns false to type it as is. Only a
    /// single character typed over an empty selection qualifies. Every keystroke passes through here, so anything but
    /// a parenthesis returns before the text is read.
    func insertPairedParenthesis(_ typed: String, replacementRange: NSRange) -> Bool {
        guard typed == "(" || typed == ")" else {
            return false
        }
        let selection = selectedRange()
        guard isEditable, !hasMarkedText(), selection.length == 0,
              replacementRange.location == NSNotFound || replacementRange == selection,
              let typing = CodePairs.typing(typed, in: string, at: selection.location, language: language) else {
            return false
        }
        switch typing {
        case .pair:
            applyTypedEdit(NSRange(location: selection.location, length: 0), replacement: "()", caret: 1, typed: typed)
        case .stepOver:
            setSelectedRange(NSRange(location: selection.location + 1, length: 0))
        }
        return true
    }

    /// Removes the empty `()` around the cursor as Backspace's one step; returns false to delete as usual.
    func deleteEmptyPairBackward() -> Bool {
        let selection = selectedRange()
        guard isEditable, !hasMarkedText(), selection.length == 0,
              CodePairs.deletesPair(in: string, at: selection.location, language: language) else {
            return false
        }
        applyTypedEdit(NSRange(location: selection.location - 1, length: 2), replacement: "", caret: 0, typed: assistance.typing)
        return true
    }

    /// Replaces `range` as one undo step, leaving the cursor `caret` units into `replacement`, with `typed` as what
    /// the completion list and parameter hints take to have been typed. The cursor moves before `didChangeText`, so
    /// they read it where it ends up rather than after the closer.
    private func applyTypedEdit(_ range: NSRange, replacement: String, caret: Int, typed: String?) {
        guard let storage = textStorage else {
            return
        }
        breakUndoCoalescing()
        guard shouldChangeText(in: range, replacementString: replacement) else {
            return
        }
        let previous = assistance.typing
        assistance.typing = typed
        defer { assistance.typing = previous }
        storage.replaceCharacters(in: range, with: NSAttributedString(string: replacement, attributes: baseAttributes))
        setSelectedRange(NSRange(location: range.location + caret, length: 0))
        didChangeText()
        breakUndoCoalescing()
    }
}
