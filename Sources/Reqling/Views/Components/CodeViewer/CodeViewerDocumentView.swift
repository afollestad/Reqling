import AppKit

/// The scroll view's document view in `CodeViewerView`: as tall as every row, drawing nothing, and taking the mouse,
/// the keyboard, focus, Copy, and Find for the viewer.
final class CodeViewerDocumentView: NSView, InPlaceFindTarget, NSMenuItemValidation {
    weak var owner: CodeViewerView?
    var label = ""

    override var isFlipped: Bool {
        true
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    override func becomeFirstResponder() -> Bool {
        owner?.canvas.needsDisplay = true
        return super.becomeFirstResponder()
    }

    override func resignFirstResponder() -> Bool {
        owner?.canvas.needsDisplay = true
        return super.resignFirstResponder()
    }

    override func resetCursorRects() {
        addCursorRect(visibleRect, cursor: .iBeam)
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        owner?.beginSelection(at: point, clickCount: event.clickCount, extending: event.modifierFlags.contains(.shift))
    }

    override func mouseDragged(with event: NSEvent) {
        autoscroll(with: event)
        guard let owner else {
            return
        }
        owner.extendSelection(to: owner.byteOffset(at: convert(event.locationInWindow, from: nil)))
    }

    /// Targets this view: a right-click doesn't move focus, so untargeted items would act on whatever has it.
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        for (title, action) in [("Copy", #selector(copy(_:))), ("Select All", #selector(selectAll(_:))), ("Find…", #selector(showFind(_:)))] {
            if action == #selector(showFind(_:)) {
                menu.addItem(.separator())
            }
            menu.addItem(withTitle: title, action: action, keyEquivalent: "").target = self
        }
        return menu
    }

    // MARK: - Commands

    @objc func copy(_ sender: Any?) {
        owner?.copySelection()
    }

    override func selectAll(_ sender: Any?) {
        owner?.selectAllText()
    }

    @objc private func showFind(_ sender: Any?) {
        performFind(.showFindInterface)
    }

    func performFind(_ action: NSTextFinder.Action) {
        owner?.onFind?(action)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        menuItem.action == #selector(copy(_:)) ? owner?.hasSelection == true : true
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        interpretKeyEvents([event])
    }

    override func moveUp(_ sender: Any?) {
        owner?.scroll(by: -(owner?.metrics.rowHeight ?? 0))
    }

    override func moveDown(_ sender: Any?) {
        owner?.scroll(by: owner?.metrics.rowHeight ?? 0)
    }

    override func scrollPageUp(_ sender: Any?) {
        owner?.scroll(by: -pageHeight)
    }

    override func scrollPageDown(_ sender: Any?) {
        owner?.scroll(by: pageHeight)
    }

    override func pageUp(_ sender: Any?) {
        scrollPageUp(sender)
    }

    override func pageDown(_ sender: Any?) {
        scrollPageDown(sender)
    }

    override func scrollToBeginningOfDocument(_ sender: Any?) {
        owner?.scroll(by: -frame.height)
    }

    override func scrollToEndOfDocument(_ sender: Any?) {
        owner?.scroll(by: frame.height)
    }

    override func moveToBeginningOfDocument(_ sender: Any?) {
        scrollToBeginningOfDocument(sender)
    }

    override func moveToEndOfDocument(_ sender: Any?) {
        scrollToEndOfDocument(sender)
    }

    private var pageHeight: CGFloat {
        max((enclosingScrollView?.contentView.bounds.height ?? 0) - (owner?.metrics.rowHeight ?? 0) * 2, 0)
    }

    // MARK: - Accessibility

    override func isAccessibilityElement() -> Bool {
        true
    }

    override func accessibilityRole() -> NSAccessibility.Role? {
        .textArea
    }

    override func accessibilityLabel() -> String? {
        label
    }

    /// The rows in view: the whole text can be far too large to hand VoiceOver, which reads the tree mode in full.
    override func accessibilityValue() -> Any? {
        owner?.visibleText
    }

    override func accessibilitySelectedText() -> String? {
        owner?.selectedTextPrefix
    }
}
