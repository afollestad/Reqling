import AppKit

/// The hover card: when the pointer rests on a name for `CodeEditorAssistance.hoverDelay`, the assistant's description
/// of it shows beneath, with any problem underlined there. It stays while the pointer stays on that name, and goes on
/// a click, a key, a scroll, an edit, or the pointer leaving. `{{variable}}` pills keep their own tooltips.
extension CodeTextView {
    /// Follows the pointer only while an assistant can describe what is under it.
    func updateHoverTracking() {
        if let area = assistance.trackingArea {
            removeTrackingArea(area)
            assistance.trackingArea = nil
        }
        guard assistance.assistant != nil else {
            return
        }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        assistance.trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        guard assistance.assistant != nil else {
            return
        }
        hoverMoved(to: convert(event.locationInWindow, from: nil))
    }

    /// Restarts the wait whenever the pointer reaches another character, and keeps a shown card while it stays on its
    /// name.
    func hoverMoved(to point: NSPoint) {
        let offset = characterOffset(at: point)
        if let range = assistance.hoverRange, let offset, NSLocationInRange(offset, range) {
            return
        }
        guard offset != assistance.hoverOffset || assistance.hoverRange != nil else {
            return
        }
        hideHover()
        assistance.hoverOffset = offset
        guard let offset else {
            return
        }
        let delay = assistance.hoverDelay
        let sleep = assistance.sleep
        assistance.hoverTask = Task { [weak self] in
            try? await sleep(delay)
            guard !Task.isCancelled, let self, assistance.hoverOffset == offset else {
                return
            }
            showHover(at: offset)
        }
    }

    /// The character whose box holds `point`; nil over margins and past a line's end. The viewport is laid out
    /// first: until it is, `characterIndexForInsertion` answers the end of the text.
    func characterOffset(at point: NSPoint) -> Int? {
        textLayoutManager?.textViewportLayoutController.layoutViewport()
        let index = characterIndexForInsertion(at: point)
        let length = (string as NSString).length
        for candidate in [index, index - 1] where candidate >= 0 && candidate < length {
            if segmentRects(for: NSRange(location: candidate, length: 1)).contains(where: { $0.insetBy(dx: -0.5, dy: 0).contains(point) }) {
                return candidate
            }
        }
        return nil
    }

    func showHover(at offset: Int) {
        guard !isShowingAssistantCompletions, !templateTokens.contains(where: { NSLocationInRange(offset, $0.utf16Range) }) else {
            return
        }
        let hover = assistance.assistant?.hover(in: string, at: offset)
        let diagnostics = diagnostics(at: offset).filter { NSLocationInRange(offset, $0.range) }
        guard let range = hover?.range ?? diagnostics.first?.range, let anchor = screenRect(for: range) else {
            return
        }
        assistance.hoverRange = range
        assistance.presenter.showHover(CodeHoverCardContent(hover: hover, diagnostics: diagnostics), below: anchor, from: self)
    }

    func hideHover() {
        assistance.hoverTask?.cancel()
        assistance.hoverTask = nil
        assistance.hoverOffset = nil
        if assistance.hoverRange != nil {
            assistance.hoverRange = nil
            assistance.presenter.hideHover()
        }
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        hideHover()
    }

    override func mouseDown(with event: NSEvent) {
        hideHover()
        super.mouseDown(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        hideHover()
        dismissCompletions()
        super.scrollWheel(with: event)
    }

    override func keyDown(with event: NSEvent) {
        hideHover()
        if handleCompletionShortcut(event) {
            return
        }
        super.keyDown(with: event)
    }
}
