import AppKit

/// Parameter hints, from an assistant that conforms to `CodeEditorSignatureAssistant` (the script editor's): while the
/// cursor is in a call's arguments, the method's signature shows above its line with the parameter being typed set
/// apart.
///
/// Typing `(` or `,` opens them where the assistant knows the call, as do ⇧⌘Space and ⌘P anywhere in one, and
/// accepting a method that takes arguments; clicking into a call doesn't. Once open they follow the cursor, and close
/// when it leaves the call, on Escape (after the completion list, which closes first), on a scroll, and when focus
/// leaves.
extension CodeTextView {
    var isShowingSignatureHelp: Bool {
        assistance.signature != nil
    }

    /// Called after every change: typing `(` or `,` opens the hints; any other change updates open ones.
    func updateSignatureHelp() {
        let opens = assistance.typing == "(" || assistance.typing == ","
        if opens || isShowingSignatureHelp {
            refreshSignatureHelp()
        }
    }

    /// Called after the cursor moves; typing updates the hints in `didChangeText`, once the text has changed.
    func followSignatureHelp() {
        if isShowingSignatureHelp, assistance.typing == nil {
            refreshSignatureHelp()
        }
    }

    /// Shows the hints for where the cursor is, as ⇧⌘Space and ⌘P do; beeps where there are none, or where nothing
    /// could be typed.
    func showParameterHints() {
        guard isEditable, signatureAssistant != nil else {
            NSSound.beep()
            return
        }
        refreshSignatureHelp()
        if !isShowingSignatureHelp {
            NSSound.beep()
        }
    }

    /// ⇧⌘Space and ⌘P show the hints; returns whether it took the press. Every view in the window is offered each key
    /// equivalent, so only the focused editor answers, and only one with hints: anywhere else ⌘P stays File ▸ Print.
    /// In a script editor it takes ⌘P from Print, as IntelliJ does, since printing a script is rarely wanted.
    func handleSignatureShortcut(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        let key = event.charactersIgnoringModifiers?.lowercased()
        guard (modifiers == [.command, .shift] && key == " ") || (modifiers == .command && key == "p"),
              window?.firstResponder === self, signatureAssistant != nil, !hasMarkedText() else {
            return false
        }
        showParameterHints()
        return true
    }

    /// Escape closes the hints, once the completion list (which takes it first) is closed; returns whether it took the
    /// command. Taking it keeps Escape from reaching a sheet's Cancel while the hints show.
    func handleSignatureCommand(_ selector: Selector) -> Bool {
        guard isShowingSignatureHelp, selector == #selector(cancelOperation(_:)) else {
            return false
        }
        hideSignatureHelp()
        return true
    }

    func hideSignatureHelp() {
        guard assistance.signature != nil else {
            return
        }
        assistance.signature = nil
        assistance.presenter.hideSignature()
    }

    /// Asks the assistant again at the cursor and shows what it says, or closes the hints when it says nothing.
    func refreshSignatureHelp() {
        let cursor = selectedRange()
        guard cursor.length == 0, isEditable, !hasMarkedText(), let assistant = signatureAssistant,
              let help = assistant.signatureHelp(in: string, cursor: cursor.location),
              let anchor = signatureAnchor(for: help, cursor: cursor.location) else {
            hideSignatureHelp()
            return
        }
        let previous = assistance.signature
        assistance.signature = help
        assistance.presenter.showSignature(help, above: anchor, from: self)
        if previous?.name != help.name || previous?.activeParameter != help.activeParameter {
            announceSignature(help)
        }
    }

    private var signatureAssistant: (any CodeEditorSignatureAssistant)? {
        assistance.assistant as? any CodeEditorSignatureAssistant
    }

    /// The cursor's line, from the call's `(` when that is on the same line, so the hints sit over the call and stay
    /// put as its arguments are typed.
    private func signatureAnchor(for help: CodeSignatureHelp, cursor: Int) -> NSRect? {
        guard let caret = screenRect(for: NSRange(location: cursor, length: 0)) else {
            return nil
        }
        guard help.anchor <= cursor, let paren = screenRect(for: NSRange(location: help.anchor, length: 0)),
              abs(paren.midY - caret.midY) < max(caret.height, 1) / 2 else {
            return caret
        }
        return NSRect(x: paren.minX, y: caret.minY, width: caret.maxX - paren.minX, height: caret.height)
    }

    /// Such as "RequestCookies.set, parameter 2 of 3, value: any, Its value."
    private func announceSignature(_ help: CodeSignatureHelp) {
        var parts = [help.name]
        if let index = help.activeParameter, let parameter = help.active {
            parts += ["parameter \(index + 1) of \(help.parameters.count)", parameter.label]
            parts += parameter.summary.map { [$0] } ?? []
        }
        let announcement = parts.joined(separator: ", ")
        NSAccessibility.post(element: self, notification: .announcementRequested, userInfo: [.announcement: announcement])
    }
}
