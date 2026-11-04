import AppKit
import SwiftUI

/// `InlineRenameTitle`'s field. AppKit rather than a SwiftUI `TextField`: `FocusState` cannot move focus into a field
/// hosted in the window toolbar, where the title lives, so this one takes first responder itself as it appears, and
/// reports Return, Escape, and focus moving elsewhere straight from its delegate.
struct InlineRenameField: NSViewRepresentable {
    private static let minWidth: CGFloat = 120
    private static let maxWidth: CGFloat = 360

    @Binding var text: String
    let font: NSFont
    let accessibilityLabel: String
    /// Return, or focus moving elsewhere.
    let onCommit: () -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> SelfFocusingTextField {
        let field = SelfFocusingTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.font = font
        field.stringValue = text
        field.setAccessibilityLabel(accessibilityLabel)
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ field: SelfFocusingTextField, context: Context) {
        context.coordinator.parent = self
        if field.currentEditor() == nil, field.stringValue != text {
            field.stringValue = text
        }
    }

    /// As wide as the name being typed, within bounds, so the field grows with it like Finder's.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: SelfFocusingTextField, context: Context) -> CGSize? {
        let textWidth = (text as NSString).size(withAttributes: [.font: font]).width + 8
        return CGSize(width: min(max(textWidth, Self.minWidth), Self.maxWidth), height: ceil(font.ascender - font.descender + font.leading) + 2)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: InlineRenameField
        /// Set by Escape, so the end of editing that removing the field causes does not commit after all.
        private var isCancelled = false

        init(parent: InlineRenameField) {
            self.parent = parent
        }

        func controlTextDidChange(_ notification: Notification) {
            if let field = notification.object as? NSTextField {
                parent.text = field.stringValue
            }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.cancelOperation(_:)):
                isCancelled = true
                parent.onCancel()
                return true
            case #selector(NSResponder.insertNewline(_:)):
                parent.onCommit()
                return true
            default:
                return false
            }
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            if !isCancelled {
                parent.onCommit()
            }
        }
    }
}

/// Takes first responder, with its text selected, once it is in a window, and ends editing on a click anywhere else in
/// it, as Finder's rename does. Without that, a click on something that never takes focus (a list's empty space, the
/// toolbar) would leave the field editing.
final class SelfFocusingTextField: NSTextField {
    private var clickMonitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else {
            return
        }
        // A turn later, so SwiftUI's own focus handling for the update that added the field cannot take it back.
        Task { @MainActor [weak self] in
            guard let self, let window else {
                return
            }
            window.makeFirstResponder(self)
            currentEditor()?.selectAll(nil)
            watchForClicksElsewhere()
        }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            stopWatchingForClicks()
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func textDidEndEditing(_ notification: Notification) {
        stopWatchingForClicks()
        super.textDidEndEditing(notification)
    }

    /// The click still reaches its target after editing ends, so clicking a sidebar row both commits and selects it.
    private func watchForClicksElsewhere() {
        guard clickMonitor == nil else {
            return
        }
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            // Local monitors run on the main thread.
            MainActor.assumeIsolated {
                guard let self, let window = self.window, event.window === window,
                      !self.bounds.contains(self.convert(event.locationInWindow, from: nil)) else {
                    return
                }
                window.makeFirstResponder(nil)
            }
            return event
        }
    }

    private func stopWatchingForClicks() {
        if let clickMonitor {
            NSEvent.removeMonitor(clickMonitor)
            self.clickMonitor = nil
        }
    }
}
