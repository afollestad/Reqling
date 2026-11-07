import AppKit

/// Undo history and input-method composition: which editor's typing the shared undo manager may hold, and outside
/// changes that wait for a composition to finish.
extension CodeTextView {
    /// The one editor whose typing each undo manager may hold.
    ///
    /// Every field in a window shares that window's manager, so history left behind by an editor the user has moved
    /// away from lets ⌘Z in the focused one rewrite it, and history for a field that left the window points at a dead
    /// storage. Focusing an editor, or editing in it, takes ownership of its manager and drops the previous owner's
    /// history; focus moving to anything else (the find bar, a SwiftUI field) keeps it, so ⌘F and back still undoes.
    /// Keyed by manager because a sheet's window has its own, and its editors must not touch the main window's.
    static let historyOwners = NSMapTable<UndoManager, CodeTextView>.weakToWeakObjects()

    /// Removes every undo action this editor registered; NSTextView files them under its text storage, so other
    /// fields keep theirs.
    func dropHistory() {
        if let storage = textStorage {
            undoManager?.removeAllActions(withTarget: storage)
        }
    }

    func claimHistory() {
        guard let manager = undoManager else {
            return
        }
        let owner = Self.historyOwners.object(forKey: manager)
        guard owner !== self else {
            return
        }
        owner?.dropHistory()
        Self.historyOwners.setObject(self, forKey: manager)
    }

    /// A removed row or a switched tab takes its editor out of the window; drop its history while `undoManager` still
    /// reaches the window's manager.
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow !== window {
            dismissCompletions()
            hideHover()
            dropHistory()
            if let manager = undoManager, Self.historyOwners.object(forKey: manager) === self {
                Self.historyOwners.removeObject(forKey: manager)
            }
        }
        super.viewWillMove(toWindow: newWindow)
    }

    // MARK: - Composition

    /// A cancelled composition (marked text set to nothing) left the text as it was before, so the outside change
    /// that waited for it can apply now.
    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        dismissCompletions()
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        if !hasMarkedText(), let waiting = textWaitingOnComposition {
            replaceText(with: waiting)
        }
    }

    /// Committing marked text in place reports it through the binding, which makes it newer than any waiting change.
    override func unmarkText() {
        let wasComposing = hasMarkedText()
        super.unmarkText()
        if wasComposing {
            textWaitingOnComposition = nil
        }
    }

    /// An input method commits by inserting over its marked text; that edit is newer than any waiting change.
    /// Also marks the change as typed, which is what lets it open or narrow the assistant's completion list.
    override func insertText(_ string: Any, replacementRange: NSRange) {
        // Pairs first: a `}` or `]` typed before the closer already there steps over that one, re-indenting it there.
        if let typed = string as? String,
           insertPairedCharacter(typed, replacementRange: replacementRange) || insertDedentedCloser(typed, replacementRange: replacementRange) {
            return
        }
        let wasComposing = hasMarkedText()
        assistance.typing = (string as? String) ?? (string as? NSAttributedString)?.string
        defer { assistance.typing = nil }
        super.insertText(string, replacementRange: replacementRange)
        if wasComposing, !hasMarkedText() {
            textWaitingOnComposition = nil
        }
    }
}
