import AppKit
import ReqlingKit

/// Edits and searches the app's menus and buttons ask of an editor: Find in multi-line editors, completion and
/// parameter hints, and edits the user asked for from outside the text view (Beautify, a script snippet), which unlike
/// outside changes are undoable.
extension CodeTextView {
    /// Opens the completion list in `window`'s focused editor, as ⌃Space does (Edit ▸ Show Completions), returning
    /// false when no editor with an assistant has focus. Whichever of the menu and the editor's own key handling sees
    /// ⌃Space first opens the list, once.
    @discardableResult
    static func showCompletions(in window: NSWindow?) -> Bool {
        guard let textView = window?.firstResponder as? CodeTextView, textView.assistance.assistant != nil else {
            return false
        }
        textView.complete(nil)
        return true
    }

    /// Shows parameter hints in `window`'s focused editor (Edit ▸ Show Parameter Hints), returning false when the
    /// focused view is no editor with hints. The editor takes ⇧⌘Space itself while it has focus
    /// (`handleSignatureShortcut`), so the menu's own shortcut reaches here only from anywhere else.
    @discardableResult
    static func showParameterHints(in window: NSWindow?) -> Bool {
        guard let textView = window?.firstResponder as? CodeTextView, textView.signatureAssistant != nil else {
            return false
        }
        textView.showParameterHints()
        return true
    }

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
        return applyUserEdit(edit.range, with: edit.replacement, in: storage, selecting: edit.mapping(selectedRange()), actionName: actionName)
    }

    /// Inserts whole lines of code as typing would, one undo step, placed by `CodeIndent.insertion`: on the cursor's
    /// line when it is blank, otherwise on a new line after it, never over the selection. Selects `placeholder` within
    /// `code`, or puts the cursor after it, and focuses the editor so typing replaces it. Returns false when it can't
    /// edit (disabled, or an input method is composing).
    @discardableResult
    func insertLinesAsUserEdit(_ code: String, placeholder: NSRange?, actionName: String) -> Bool {
        guard isEditable, !hasMarkedText(), let storage = textStorage else {
            return false
        }
        let insertion = CodeIndent.insertion(of: code, placeholder: placeholder, in: string, selection: selectedRange(), language: language)
        let selection = NSRange(location: insertion.range.location + insertion.selection.location, length: insertion.selection.length)
        guard applyUserEdit(insertion.range, with: insertion.replacement, in: storage, selecting: selection, actionName: actionName) else {
            return false
        }
        window?.makeFirstResponder(self)
        scrollRangeToVisible(selection)
        return true
    }

    /// One named undo step, reported through the binding and owning the history (`shouldChangeText` claims it).
    private func applyUserEdit(
        _ range: NSRange,
        with replacement: String,
        in storage: NSTextStorage,
        selecting selection: NSRange,
        actionName: String
    ) -> Bool {
        breakUndoCoalescing()
        guard shouldChangeText(in: range, replacementString: replacement) else {
            return false
        }
        storage.replaceCharacters(in: range, with: NSAttributedString(string: replacement, attributes: baseAttributes))
        setSelectedRange(selection)
        didChangeText()
        undoManager?.setActionName(actionName)
        breakUndoCoalescing()
        return true
    }
}

/// A handle a view keeps to its `CodeEditor`'s text view, for button and menu actions that edit as the user (Beautify,
/// a script snippet).
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

    /// Inserts lines of code as an undoable user edit (`CodeTextView.insertLinesAsUserEdit`), beeping when the editor
    /// can't take it right now. Returns false only when there is no text view yet, as `replaceAll` does.
    @discardableResult
    func insertLines(_ code: String, placeholder: NSRange?, actionName: String) -> Bool {
        guard let textView else {
            return false
        }
        if !textView.insertLinesAsUserEdit(code, placeholder: placeholder, actionName: actionName) {
            NSSound.beep()
        }
        return true
    }

    /// Selects `range`, scrolls it into view, and focuses the editor, as choosing a problem from a list does.
    func reveal(_ range: NSRange) {
        guard let textView else {
            return
        }
        let length = (textView.string as NSString).length
        let clamped = NSRange(location: min(range.location, length), length: min(range.length, max(0, length - range.location)))
        textView.window?.makeFirstResponder(textView)
        textView.setSelectedRange(clamped)
        textView.scrollRangeToVisible(clamped)
    }
}
