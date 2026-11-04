import AppKit
import ReqlingKit

/// The text view behind `CodeEditor` and `TemplateField`, on TextKit 2.
///
/// Syntax colors are applied as rendering attributes, which never enter the text storage or the undo stack, and
/// `{{variable}}` pills are drawn by `TokenLayoutFragment`. Both are recomputed from `TemplateParser` and
/// `SyntaxTokenizer`, so what is highlighted is exactly what will be substituted.
///
/// `NSTextLayoutManagerDelegate` predates concurrency annotations; NSTextView calls it on the main thread, which is
/// what the `@preconcurrency` conformance relies on.
final class CodeTextView: NSTextView, @preconcurrency NSTextLayoutManagerDelegate, NSViewToolTipOwner {
    var language: SyntaxLanguage = .plainText {
        didSet {
            if language != oldValue {
                refreshHighlighting()
            }
        }
    }
    var tokenContext: TemplateTokenContext = .empty {
        didSet {
            if tokenContext != oldValue {
                rebuildPills()
            }
        }
    }
    /// What resolved pills draw in: the SwiftUI `appAccent` the hosting representable passes down.
    var accentColor: NSColor = .controlAccentColor {
        didSet {
            if accentColor != oldValue {
                rebuildPills()
            }
        }
    }
    var placeholder = "" {
        didSet { needsDisplay = true }
    }
    var isSingleLine = false
    /// Highlights `{{variable}}` references; off for response bodies.
    var showsTemplateTokens = true
    /// Read-only response text arrives already colored in its storage (`SyntaxPalette.attributedString`), so it skips
    /// rendering-attribute highlighting. Kept apart from `isEditable`, which an editor also loses while its SwiftUI
    /// ancestor is disabled and which must keep highlighting then.
    var isPrecolored = false
    var onSubmit: (() -> Void)?
    /// Returns true when it consumed the pasted text, as the URL bar does for cURL commands.
    var onPaste: ((String) -> Bool)?
    var onFocusChange: ((Bool) -> Void)?

    private(set) var templateTokens: [TemplateToken] = []
    /// What every inserted run carries in storage; colors stay rendering attributes on top.
    private(set) var baseAttributes: [NSAttributedString.Key: Any] = [:]
    /// Set when a width change may have re-wrapped the pills, so `layout()` rebuilds the tooltip rectangles.
    private var needsToolTipRefresh = false
    /// True while the completion list is open: AppKit inserts each highlighted name provisionally, then once finally.
    private var isCompleting = false
    /// An outside change that arrived while an input method was composing; see `replaceText(with:)`.
    var textWaitingOnComposition: String?

    static func make(isSingleLine: Bool) -> CodeTextView {
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        let layoutManager = NSTextLayoutManager()
        layoutManager.textContainer = container
        let contentStorage = NSTextContentStorage()
        contentStorage.addTextLayoutManager(layoutManager)
        let textView = CodeTextView(frame: .zero, textContainer: container)
        layoutManager.delegate = textView
        textView.isSingleLine = isSingleLine
        textView.configure()
        return textView
    }

    private func configure() {
        let font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        self.font = font
        baseAttributes = [.font: font, .foregroundColor: NSColor.labelColor]
        typingAttributes = baseAttributes
        isRichText = false
        importsGraphics = false
        allowsUndo = true
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isContinuousSpellCheckingEnabled = false
        isGrammarCheckingEnabled = false
        smartInsertDeleteEnabled = false
        drawsBackground = false
        textContainerInset = isSingleLine ? NSSize(width: 4, height: 4) : NSSize(width: 6, height: 8)
        if isSingleLine {
            isHorizontallyResizable = true
            isVerticallyResizable = false
            textContainer?.widthTracksTextView = false
            textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            textContainer?.maximumNumberOfLines = 1
            textContainer?.lineBreakMode = .byClipping
            maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        } else {
            isHorizontallyResizable = false
            isVerticallyResizable = true
            textContainer?.widthTracksTextView = true
            autoresizingMask = [.width]
            maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            // ⌘F searches bodies and responses in place, through `CodeTextView.performFind` from the Find menu.
            usesFindBar = true
            isIncrementalSearchingEnabled = true
        }
    }

    // MARK: - Text From Outside

    /// Loads a new editor's first content without an undo step, so ⌘Z cannot empty a body that was just opened.
    func setInitialText(_ text: String) {
        string = text
        refreshHighlighting()
    }

    /// Applies text that changed outside the editor (Beautify, a cURL import, a save from elsewhere), touching only
    /// the span that differs, so a selection outside it keeps its place.
    ///
    /// It is never an undo step, and it drops this editor's history: typing recorded against the old text would replay
    /// stale ranges, and an outside change is not the user's to undo piecemeal (a cURL import rewrites several fields
    /// at once). Beautify losing ⌘Z is the accepted cost. It skips `shouldChangeText`, so the model's own text is
    /// neither flattened nor reported back, and `didChangeText`, so it never opens completion.
    ///
    /// While an input method is composing it waits: marked text never reaches the binding, so a re-render
    /// mid-composition would delete it under the input method. A cancelled composition applies the waiting text; a
    /// committed one is newer and replaces it (`CodeTextView+History`).
    func replaceText(with newText: String) {
        if hasMarkedText() {
            textWaitingOnComposition = newText
            return
        }
        textWaitingOnComposition = nil
        guard string != newText, let storage = textStorage else {
            return
        }
        let edit = TextEdit.minimal(from: string as NSString, to: newText as NSString)
        let selection = edit.mapping(selectedRange())
        breakUndoCoalescing()
        storage.replaceCharacters(in: edit.range, with: NSAttributedString(string: edit.replacement, attributes: baseAttributes))
        dropHistory()
        refreshHighlighting()
        setSelectedRange(selection)
    }

    // MARK: - Highlighting

    /// Re-applies syntax colors and token pills; called after every text change. Colors are rendering attributes, which
    /// never enter the text storage or the undo stack; storage attributes would bleed into newly typed text.
    func refreshHighlighting() {
        guard !isPrecolored, let layoutManager = textLayoutManager, let contentStorage = layoutManager.textContentManager else {
            return
        }
        let documentRange = contentStorage.documentRange
        layoutManager.removeRenderingAttribute(.foregroundColor, for: documentRange)
        let text = string
        for token in SyntaxTokenizer.tokens(in: text, language: language) {
            if let range = textRange(for: token.range) {
                layoutManager.addRenderingAttribute(.foregroundColor, value: SyntaxPalette.color(for: token.role), for: range)
            }
        }
        refreshTokens()
    }

    private func refreshTokens() {
        guard let layoutManager = textLayoutManager, let contentStorage = layoutManager.textContentManager else {
            return
        }
        templateTokens = showsTemplateTokens ? TemplateParser.tokens(in: string) : []
        for token in templateTokens {
            if let range = textRange(for: token.utf16Range) {
                let color = SyntaxPalette.tokenText(for: tokenContext.state(for: token), accent: accentColor)
                layoutManager.addRenderingAttribute(.foregroundColor, value: color, for: range)
            }
        }
        // Text edits recreate the fragments they touch; `rebuildPills` recreates the rest when token states change.
        layoutManager.invalidateLayout(for: contentStorage.documentRange)
        needsDisplay = true
        refreshToolTips()
    }

    func textRange(for range: NSRange) -> NSTextRange? {
        guard let contentStorage = textLayoutManager?.textContentManager,
              let start = contentStorage.location(contentStorage.documentRange.location, offsetBy: range.location),
              let end = contentStorage.location(start, offsetBy: range.length) else {
            return nil
        }
        return NSTextRange(location: start, end: end)
    }

    /// The rectangles a range occupies, in this view's coordinates.
    func segmentRects(for range: NSRange) -> [NSRect] {
        guard let layoutManager = textLayoutManager, let textRange = textRange(for: range) else {
            return []
        }
        var rects: [NSRect] = []
        layoutManager.enumerateTextSegments(in: textRange, type: .standard, options: .rangeNotRequired) { _, frame, _, _ in
            rects.append(frame.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y))
            return true
        }
        return rects
    }

    /// Hands each fragment a snapshot of its pills (ranges relative to its paragraph, colors resolved for the current
    /// appearance), so drawing reads nothing from the view. `rebuildPills` recreates the fragments whenever that
    /// snapshot would change.
    func textLayoutManager(
        _ textLayoutManager: NSTextLayoutManager,
        textLayoutFragmentFor location: any NSTextLocation,
        in textElement: NSTextElement
    ) -> NSTextLayoutFragment {
        let fragment = TokenLayoutFragment(textElement: textElement, range: textElement.elementRange)
        guard let elementRange = textElement.elementRange, let contentStorage = textLayoutManager.textContentManager else {
            return fragment
        }
        let start = contentStorage.offset(from: contentStorage.documentRange.location, to: elementRange.location)
        let end = contentStorage.offset(from: contentStorage.documentRange.location, to: elementRange.endLocation)
        fragment.pills = templateTokens.compactMap { token in
            let overlap = NSIntersectionRange(token.utf16Range, NSRange(location: start, length: end - start))
            guard overlap.length > 0 else {
                return nil
            }
            var color = CGColor(gray: 0, alpha: 0)
            effectiveAppearance.performAsCurrentDrawingAppearance {
                color = SyntaxPalette.tokenFill(for: tokenContext.state(for: token), accent: accentColor).cgColor
            }
            return TokenLayoutFragment.Pill(range: NSRange(location: overlap.location - start, length: overlap.length), fill: color)
        }
        return fragment
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        rebuildPills()
    }

    /// Recreates every layout fragment so each takes a fresh pill snapshot, after the token states or the appearance
    /// change. Invalidating layout is not enough: TextKit reuses the fragments, which keep the fills they were created
    /// with. An attribute-only edit makes the content storage rebuild its paragraphs, and with them the fragments; it
    /// changes no text and records no undo step.
    private func rebuildPills() {
        guard showsTemplateTokens, !isPrecolored else {
            return
        }
        if let storage = textStorage, storage.length > 0 {
            textLayoutManager?.textContentManager?.performEditingTransaction {
                storage.beginEditing()
                storage.edited(.editedAttributes, range: NSRange(location: 0, length: storage.length), changeInLength: 0)
                storage.endEditing()
            }
        }
        refreshHighlighting()
    }

    // MARK: - Tooltips

    private func refreshToolTips() {
        removeAllToolTips()
        for token in templateTokens {
            for rect in segmentRects(for: token.utf16Range) {
                addToolTip(rect, owner: self, userData: nil)
            }
        }
    }

    /// A multi-line editor is created at zero width and re-wraps on every resize, either of which moves the pills off
    /// the rectangles `refreshToolTips` registered; rebuild them once the new width is laid out.
    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = newSize.width != frame.width
        super.setFrameSize(newSize)
        if widthChanged, !templateTokens.isEmpty {
            needsToolTipRefresh = true
            needsLayout = true
        }
    }

    /// Waits out a live resize (a window or split-divider drag), which re-wraps every frame: rebuilding the tooltips lays
    /// out every token's range each time. `viewDidEndLiveResize` catches up once.
    override func layout() {
        super.layout()
        if needsToolTipRefresh, !inLiveResize {
            needsToolTipRefresh = false
            refreshToolTips()
        }
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        if needsToolTipRefresh {
            needsToolTipRefresh = false
            refreshToolTips()
        }
    }

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        let token = templateTokens.first { token in
            segmentRects(for: token.utf16Range).contains { $0.insetBy(dx: -2, dy: -2).contains(point) }
        }
        return token.map(tokenContext.tooltip(for:)) ?? ""
    }

    // MARK: - Editing

    override func didChangeText() {
        super.didChangeText()
        refreshHighlighting()
        offerCompletionAfterOpeningBraces()
    }

    /// Return submits a single-line field. Without a submit action it goes to the window's key equivalents, which is
    /// how a sheet's `.defaultAction` button fires: a text view that is not a field editor claims Return first.
    override func insertNewline(_ sender: Any?) {
        guard isSingleLine else {
            super.insertNewline(sender)
            return
        }
        if let onSubmit {
            onSubmit()
        } else if let event = NSApp.currentEvent, event.type == .keyDown {
            _ = window?.performKeyEquivalent(with: event)
        }
    }

    /// NSTextView turns Escape (`cancelOperation(_:)`, which it does not implement) into word completion, which
    /// swallowed a sheet's Cancel. Outside a completion session, hand it up the responder chain, where SwiftUI's
    /// `.cancelAction` answers; Option-Escape and F5 still invoke `complete(_:)`. During a session AppKit keeps it, so
    /// Escape still dismisses the list.
    override func doCommand(by selector: Selector) {
        if selector == #selector(cancelOperation(_:)), !isCompleting {
            _ = nextResponder?.tryToPerform(selector, with: self)
            return
        }
        super.doCommand(by: selector)
    }

    override func insertTab(_ sender: Any?) {
        if isSingleLine {
            window?.selectNextKeyView(sender)
        } else {
            insertText("  ", replacementRange: selectedRange())
        }
    }

    override func insertBacktab(_ sender: Any?) {
        window?.selectPreviousKeyView(sender)
    }

    override func paste(_ sender: Any?) {
        if let text = NSPasteboard.general.string(forType: .string), onPaste?(text) == true {
            return
        }
        super.paste(sender)
    }

    /// Keeps a single-line field on one line however text arrives (Option-Return, a drop, Paste and Match Style,
    /// Services), since all of them pass through here: the edit is re-issued with its line breaks flattened. With
    /// `maximumNumberOfLines` at 1, a stray newline would hide the rest of a URL or header value.
    override func shouldChangeText(in affectedCharRange: NSRange, replacementString: String?) -> Bool {
        guard isSingleLine, let replacementString, replacementString.contains(where: \.isNewline) else {
            let accepted = super.shouldChangeText(in: affectedCharRange, replacementString: replacementString)
            if accepted {
                claimHistory()
            }
            return accepted
        }
        let flattened = Self.singleLine(replacementString)
        if !flattened.isEmpty || affectedCharRange.length > 0 {
            insertText(flattened, replacementRange: affectedCharRange)
        }
        return false
    }

    /// `text` on one line: each run of line breaks becomes one space, and breaks at either end are dropped.
    static func singleLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).joined(separator: " ")
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted {
            if isEditable {
                // A read-only viewer (the response, the sent body) has no history of its own to protect.
                claimHistory()
            }
            onFocusChange?(true)
        }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted {
            isCompleting = false
            onFocusChange?(false)
        }
        return accepted
    }

    // MARK: - Completion

    /// Typing `{{` opens completion for variable names.
    private func offerCompletionAfterOpeningBraces() {
        guard showsTemplateTokens, isEditable, !hasMarkedText(), !tokenContext.completions(matching: "").isEmpty else {
            return
        }
        let cursor = selectedRange().location
        let text = string as NSString
        guard cursor >= 2, cursor <= text.length, text.substring(with: NSRange(location: cursor - 2, length: 2)) == "{{" else {
            return
        }
        complete(nil)
    }

    /// The partial name inside the nearest `{{` before `cursor` that is still open on its line, or nil outside one.
    static func templateCompletionRange(in text: NSString, cursor: Int) -> NSRange? {
        let cursor = min(max(cursor, 0), text.length)
        let open = text.range(of: "{{", options: .backwards, range: NSRange(location: 0, length: cursor))
        guard open.location != NSNotFound else {
            return nil
        }
        let start = NSMaxRange(open)
        let partial = text.substring(with: NSRange(location: start, length: cursor - start))
        guard !partial.contains("}"), !partial.contains(where: \.isNewline) else {
            return nil
        }
        return NSRange(location: start, length: cursor - start)
    }

    /// Completion only ever names variables, so outside an open `{{` there is nothing to complete; `NSNotFound` keeps
    /// AppKit from offering them as plain words.
    override var rangeForUserCompletion: NSRange {
        guard showsTemplateTokens, let range = Self.templateCompletionRange(in: string as NSString, cursor: selectedRange().location) else {
            return NSRange(location: NSNotFound, length: 0)
        }
        return range
    }

    override func completions(forPartialWordRange charRange: NSRange, indexOfSelectedItem index: UnsafeMutablePointer<Int>) -> [String]? {
        guard showsTemplateTokens, followsOpeningBraces(charRange) else {
            return nil
        }
        let partial = (string as NSString).substring(with: charRange).trimmingCharacters(in: .whitespaces)
        index.pointee = 0
        return tokenContext.completions(matching: partial)
    }

    override func insertCompletion(_ word: String, forPartialWordRange charRange: NSRange, movement: Int, isFinal flag: Bool) {
        isCompleting = !flag
        let closes = flag && movement != NSCancelTextMovement && followsOpeningBraces(charRange) && !followingTextCloses(after: charRange)
        super.insertCompletion(closes ? word + "}}" : word, forPartialWordRange: charRange, movement: movement, isFinal: flag)
    }

    private func followsOpeningBraces(_ range: NSRange) -> Bool {
        let text = string as NSString
        let cursor = NSMaxRange(range)
        return cursor <= text.length && Self.templateCompletionRange(in: text, cursor: cursor)?.location == range.location
    }

    private func followingTextCloses(after range: NSRange) -> Bool {
        let text = string as NSString
        let location = NSMaxRange(range)
        return location + 2 <= text.length && text.substring(with: NSRange(location: location, length: 2)) == "}}"
    }

    // MARK: - Placeholder

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else {
            return
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
            .foregroundColor: NSColor.placeholderTextColor
        ]
        let origin = NSPoint(x: textContainerOrigin.x + 5, y: textContainerOrigin.y)
        (placeholder as NSString).draw(at: origin, withAttributes: attributes)
    }
}
