import AppKit

/// Edits and searches the app's menus and buttons ask of an editor: Find in multi-line editors, and whole-text
/// replacements the user asked for (Beautify), which unlike outside changes are undoable.
extension CodeTextView {
    /// Runs a Find menu action in `window`'s focused multi-line editor, returning false when there is none.
    ///
    /// Sent to the editor directly rather than up the responder chain: a single-line field or a SwiftUI text field
    /// would answer with AppKit's old Find panel instead of an in-place find bar.
    @discardableResult
    static func performFind(_ action: NSTextFinder.Action, in window: NSWindow?) -> Bool {
        guard let textView = findTarget(for: window?.firstResponder) else {
            return false
        }
        let sender = NSMenuItem()
        sender.tag = action.rawValue
        textView.performTextFinderAction(sender)
        return true
    }

    /// The multi-line editor a Find action is for: the focused one, or the one whose find bar has focus. The bar's
    /// search field edits through a field editor, so ⌘G from the bar starts at that field and walks up to the scroll
    /// view the bar sits in.
    static func findTarget(for responder: NSResponder?) -> CodeTextView? {
        if let textView = responder as? CodeTextView {
            return textView.usesFindBar ? textView : nil
        }
        let fieldEditor = responder as? NSTextView
        var view = fieldEditor?.isFieldEditor == true ? fieldEditor?.delegate as? NSView : responder as? NSView
        while let current = view {
            if let scrollView = current as? NSScrollView, let textView = scrollView.documentView as? CodeTextView {
                return textView.usesFindBar ? textView : nil
            }
            view = current.superview
        }
        return nil
    }

    /// Replaces the text the way typing would: one undo step, reported through the binding, owning the history, with
    /// a selection outside the changed span kept in place. For edits the user asks for from outside the text view, such
    /// as Beautify; returns false when it can't edit (disabled, or an input method is composing).
    @discardableResult
    func replaceAllAsUserEdit(with newText: String, actionName: String) -> Bool {
        guard isEditable, !hasMarkedText(), let storage = textStorage else {
            return false
        }
        let edit = TextEdit.minimal(from: string as NSString, to: newText as NSString)
        guard edit.range.length > 0 || !edit.replacement.isEmpty else {
            return true
        }
        let selection = edit.mapping(selectedRange())
        breakUndoCoalescing()
        guard shouldChangeText(in: edit.range, replacementString: edit.replacement) else {
            return false
        }
        storage.replaceCharacters(in: edit.range, with: NSAttributedString(string: edit.replacement, attributes: baseAttributes))
        setSelectedRange(selection)
        didChangeText()
        undoManager?.setActionName(actionName)
        breakUndoCoalescing()
        return true
    }
}

/// A handle a view keeps to its `CodeEditor`'s text view, for button actions that edit as the user (Beautify).
@MainActor
final class CodeEditorHandle {
    weak var textView: CodeTextView?

    /// Replaces the editor's text as an undoable user edit, beeping when the editor can't take it right now. Returns
    /// false only when there is no text view yet, so the caller can write the model instead; an editor that refuses
    /// (disabled, mid-composition) must not be bypassed.
    @discardableResult
    func replaceAll(with text: String, actionName: String) -> Bool {
        guard let textView else {
            return false
        }
        if !textView.replaceAllAsUserEdit(with: text, actionName: actionName) {
            NSSound.beep()
        }
        return true
    }
}
