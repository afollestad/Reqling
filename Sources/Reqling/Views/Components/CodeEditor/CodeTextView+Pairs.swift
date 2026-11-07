import AppKit
import ReqlingKit

/// Brackets and quotes typed in a JavaScript or GraphQL editor pair themselves (`CodePairs`): an opener or quote
/// brings its closer, one typed before the closer already there steps over it, and Backspace between an empty pair
/// removes both. Each edit is one undo step, and reaches the completion list and parameter hints as the key that was
/// typed, so `(` still opens the hints and the arguments' completion, and a quote a script's variable names.
extension CodeTextView {
    /// Types `typed` paired, or steps over its closer, when `CodePairs` says so; returns false to type it as is. Only
    /// a single character typed over an empty selection qualifies. Every keystroke passes through here, so anything but
    /// a bracket or quote returns before the text is read.
    func insertPairedCharacter(_ typed: String, replacementRange: NSRange) -> Bool {
        guard typed.count == 1, Self.pairedCharacters.contains(typed) else {
            return false
        }
        let selection = selectedRange()
        guard isEditable, !hasMarkedText(), selection.length == 0,
              replacementRange.location == NSNotFound || replacementRange == selection,
              let typing = CodePairs.typing(typed, in: string, at: selection.location, language: language) else {
            return false
        }
        switch typing {
        case .pair(let closer):
            applyTypedEdit(NSRange(location: selection.location, length: 0), replacement: typed + closer, caret: typed.utf16.count, typed: typed)
        case .stepOver:
            // A `}` or `]` at the start of its line moves back to its opener's indentation, as one typed there would.
            if let edit = CodeIndent.steppingOver(closerAt: selection.location, in: string, language: language) {
                applyTypedEdit(edit.range, replacement: edit.replacement, caret: edit.caret, typed: typed)
            } else {
                setSelectedRange(NSRange(location: selection.location + 1, length: 0))
            }
        }
        return true
    }

    private static let pairedCharacters = "()[]{}\"'`"

    /// Removes the empty pair around the cursor as Backspace's one step; returns false to delete as usual.
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
