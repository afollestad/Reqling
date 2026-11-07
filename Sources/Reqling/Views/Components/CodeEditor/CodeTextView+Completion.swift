import AppKit
import ReqlingKit
import ReqlingTemplating

/// Completion from the editor's assistant, in a list of its own beside AppKit's: AppKit's shows only plain words,
/// and suggestions need their kind, type, and description.
///
/// Typing opens it where the assistant has suggestions (`CodeEditorAssistant.opensCompletion`; GraphQL's are a name
/// character, `@`, `$`, `(`, or a space after `:` or `on`); ⌃Space, ⌥Esc, and F5 open it anywhere, with what fits
/// there (⌃Space only where macOS's input source switcher leaves it alone). Pastes, undo, and outside changes never
/// open it. While it is open the text view keeps focus: ↑ and ↓ move the highlight, Return and Tab accept, Escape closes
/// it without reaching a sheet's Cancel, and a ⌘ shortcut closes it and runs. Where the editor shows `{{variables}}`,
/// `{{` still opens AppKit's list of them, which wins: the two are never open together.
extension CodeTextView {
    var isShowingAssistantCompletions: Bool {
        assistance.completion != nil
    }

    /// Called after every change. Only typing at the cursor opens or narrows the list; anything else closes it.
    func updateAssistantCompletion() {
        let typed = assistance.typing
        guard !assistance.isAccepting else {
            return
        }
        guard let typed, isEditable, !hasMarkedText(), !isCompleting, assistance.assistant != nil else {
            dismissCompletions()
            return
        }
        if isInTemplateToken {
            dismissCompletions()
            return
        }
        if let open = assistance.completion, typed.allSatisfy(open.nameCharacters.contains) {
            refreshCompletions(isForced: open.isForced)
        } else {
            dismissCompletions()
            if assistance.assistant?.opensCompletion(typed, before: selectedRange().location, in: string as NSString) == true {
                refreshCompletions(isForced: false)
            }
        }
    }

    /// Backspace narrows the list as typing does.
    override func deleteBackward(_ sender: Any?) {
        assistance.typing = assistance.completion == nil ? nil : ""
        defer { assistance.typing = nil }
        super.deleteBackward(sender)
    }

    /// ⌥Esc and F5 reach here, and ⌃Space through `handleCompletionShortcut`. Inside `{{` they complete variables, as
    /// before; elsewhere they open the assistant's list. A disabled editor beeps: nothing chosen could be inserted.
    override func complete(_ sender: Any?) {
        guard isEditable else {
            NSSound.beep()
            return
        }
        guard assistance.assistant != nil, !isInTemplateToken else {
            super.complete(sender)
            return
        }
        refreshCompletions(isForced: true)
        if assistance.completion == nil {
            NSSound.beep()
        }
    }

    /// The list's keys, before the text view's own; returns whether it took the command.
    func handleCompletionCommand(_ selector: Selector) -> Bool {
        guard let completion = assistance.completion else {
            return false
        }
        switch selector {
        case #selector(moveDown(_:)):
            completion.model.move(by: 1)
        case #selector(moveUp(_:)):
            completion.model.move(by: -1)
        case #selector(pageDown(_:)), #selector(scrollPageDown(_:)):
            completion.model.move(by: CodeCompletionModel.visibleRows)
        case #selector(pageUp(_:)), #selector(scrollPageUp(_:)):
            completion.model.move(by: -CodeCompletionModel.visibleRows)
        case #selector(insertNewline(_:)), #selector(insertTab(_:)):
            if let item = completion.model.highlightedItem {
                accept(item)
            }
        case #selector(cancelOperation(_:)):
            dismissCompletions()
        default:
            dismissCompletions()
            return false
        }
        announceHighlight()
        return true
    }

    /// A ⌘ shortcut closes the list before it runs, unless it shows parameter hints (`handleSignatureShortcut`).
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if handleSignatureShortcut(event) {
            return true
        }
        if event.modifierFlags.contains(.command) {
            dismissCompletions()
        }
        return super.performKeyEquivalent(with: event)
    }

    /// ⌃Space opens the list for where the cursor is, as ⌥Esc does; returns whether it took the press. Called from
    /// `keyDown`, which ⌃Space reaches as an ordinary key press: an override of `performKeyEquivalent` never saw it.
    /// Caps Lock is ignored, and an input method that is composing keeps the key, as does a disabled editor.
    func handleCompletionShortcut(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection([.command, .control, .option, .shift]) == .control,
              event.charactersIgnoringModifiers == " ", !hasMarkedText(), isEditable, assistance.assistant != nil else {
            return false
        }
        complete(nil)
        return true
    }

    /// Moving the cursor out of the name being completed closes the list; parameter hints follow it.
    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        followSignatureHelp()
        guard let completion = assistance.completion, !assistance.isAccepting, assistance.typing == nil else {
            return
        }
        let selection = selectedRange()
        let start = completion.replacementRange.location
        let text = string as NSString
        guard selection.length == 0, selection.location >= start, selection.location <= text.length,
              text.substring(with: NSRange(location: start, length: selection.location - start)).allSatisfy(completion.nameCharacters.contains) else {
            dismissCompletions()
            return
        }
    }

    /// A window that stops being key hides the panels (`hidesOnDeactivate`); close the list and hints too, so their
    /// keys stop.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        assistance.windowObserver.map(NotificationCenter.default.removeObserver)
        assistance.windowObserver = window.map { window in
            NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.dismissCompletions()
                    self?.hideSignatureHelp()
                    self?.hideHover()
                }
            }
        }
    }

    func dismissCompletions() {
        guard assistance.completion != nil else {
            return
        }
        assistance.completion = nil
        assistance.presenter.hideCompletions()
    }

    /// Asks the assistant again at the cursor and shows what it offers, or closes the list when it offers nothing.
    func refreshCompletions(isForced: Bool) {
        let cursor = selectedRange()
        guard cursor.length == 0, let assistant = assistance.assistant,
              let list = assistant.completions(in: string, cursor: cursor.location), !list.items.isEmpty else {
            dismissCompletions()
            return
        }
        let start = list.replacementRange.location
        let typed = (string as NSString).substring(with: NSRange(location: start, length: cursor.location - start))
        // A name typed out in full needs no list, unless it was asked for.
        if !isForced, list.items.count == 1, list.items[0].insertText == typed {
            dismissCompletions()
            return
        }
        let model = assistance.completion?.model ?? CodeCompletionModel()
        let highlightedLabel = model.highlightedItem?.label
        model.items = list.items
        model.highlighted = list.items.firstIndex { $0.label == highlightedLabel } ?? 0
        model.onAccept = { [weak self] item in
            self?.accept(item)
        }
        assistance.completion = CodeEditorAssistance.Completion(
            model: model,
            replacementRange: list.replacementRange,
            isForced: isForced,
            nameCharacters: list.nameCharacters
        )
        if let anchor = screenRect(for: NSRange(location: list.replacementRange.location, length: 0)) {
            assistance.presenter.showCompletions(model, below: anchor, from: self)
        }
        announceHighlight()
    }

    /// Replaces the name being typed with `item`, as one undo step. A method gets its `()`, unless a `(` already
    /// follows: the cursor goes between them, with parameter hints, when it takes arguments, and after them otherwise.
    func accept(_ item: CodeCompletionItem) {
        guard let completion = assistance.completion else {
            return
        }
        let cursor = selectedRange().location
        let start = completion.replacementRange.location
        let range = NSRange(location: start, length: max(completion.replacementRange.length, cursor - start))
        let text = string as NSString
        let isCalled = NSMaxRange(range) < text.length && text.substring(with: NSRange(location: NSMaxRange(range), length: 1)) == "("
        let parentheses = isCalled ? nil : item.parentheses
        dismissCompletions()
        assistance.isAccepting = true
        breakUndoCoalescing()
        insertText(item.insertText + (parentheses == nil ? "" : "()"), replacementRange: range)
        if parentheses == .withArguments {
            setSelectedRange(NSRange(location: selectedRange().location - 1, length: 0))
        }
        breakUndoCoalescing()
        assistance.isAccepting = false
        if parentheses == .withArguments {
            refreshSignatureHelp()
        }
    }

    /// Where `range` sits on screen, for anchoring a panel; nil while the view is in no window.
    func screenRect(for range: NSRange) -> NSRect? {
        guard let window else {
            return nil
        }
        let rects = segmentRects(for: range)
        let rect = rects.first ?? firstRect(forCharacterRange: range, actualRange: nil)
        if rects.isEmpty {
            return rect
        }
        return window.convertToScreen(convert(rect, to: nil))
    }

    private func announceHighlight() {
        guard let item = assistance.completion?.model.highlightedItem else {
            return
        }
        let announcement = [item.label, item.kind.spokenName, item.detail].compactMap { $0 }.joined(separator: ", ")
        NSAccessibility.post(element: self, notification: .announcementRequested, userInfo: [.announcement: announcement])
    }

    /// Inside an unfinished `{{` where the editor shows variables, whose completion is AppKit's; a script's `{{` is
    /// literal text.
    private var isInTemplateToken: Bool {
        showsTemplateTokens && TemplateParser.openTokenRange(in: string as NSString, cursor: selectedRange().location) != nil
    }

    nonisolated static func isNameCharacter(_ character: Character) -> Bool {
        character == "_" || (character.isASCII && (character.isLetter || character.isNumber))
    }

    /// Whether typing `typed` just before `cursor` starts something worth suggesting for.
    static func opensCompletion(_ typed: String, before cursor: Int, in text: NSString) -> Bool {
        guard typed.count == 1, let character = typed.first else {
            return false
        }
        if isNameCharacter(character) {
            // A digit only continues a name; on its own it is a number.
            return !character.isNumber || (cursor >= 2 && isNameCharacter(Character(text.substring(with: NSRange(location: cursor - 2, length: 1)))))
        }
        if "@$(".contains(character) {
            return true
        }
        guard character == " ", cursor >= 2 else {
            return false
        }
        let before = text.substring(to: cursor - 1).trimmingCharacters(in: .whitespaces)
        return before.hasSuffix(":") || before.hasSuffix(" on") || before == "on" || before.hasSuffix("{on")
    }
}
