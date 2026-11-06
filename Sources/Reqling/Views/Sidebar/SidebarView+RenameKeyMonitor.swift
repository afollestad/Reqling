import AppKit
import SwiftUI

/// Return on the selected sidebar row renames it, as in Finder. Mounted behind that row's name only, it acts while the
/// `NSTableView` holding the row is first responder: the filter field, the editors, a sheet, and the rename field itself
/// keep their Return.
///
/// A local key monitor rather than `.onKeyPress` on the `List`, because the monitor sees the key before the native
/// table does. Scoping it to the selected row makes the focus check exact (this row's own table, by identity) and means
/// a selected row scrolled out of view never starts a rename no one can see.
struct SidebarRenameKeyMonitor: NSViewRepresentable {
    let onReturn: @MainActor () -> Void

    func makeNSView(context: Context) -> SidebarRenameKeyMonitorView {
        let view = SidebarRenameKeyMonitorView()
        view.onReturn = onReturn
        return view
    }

    func updateNSView(_ view: SidebarRenameKeyMonitorView, context: Context) {
        view.onReturn = onReturn
    }

    static func dismantleNSView(_ view: SidebarRenameKeyMonitorView, coordinator: ()) {
        view.stopMonitoring()
    }
}

final class SidebarRenameKeyMonitorView: NSView {
    private static let returnKeyCode: UInt16 = 36
    private static let keypadEnterKeyCode: UInt16 = 76
    /// Any of these makes it a different shortcut; ⌘Return sends the request.
    private static let shortcutModifiers: NSEvent.ModifierFlags = [.command, .control, .option, .shift]

    var onReturn: (@MainActor () -> Void)?
    private var keyMonitor: Any?

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Clicks, drags, and the context menu go to the row as before.
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            stopMonitoring()
        } else {
            startMonitoring()
        }
    }

    func stopMonitoring() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }

    private func startMonitoring() {
        guard keyMonitor == nil else {
            return
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Local monitors run on the main thread.
            let renamed = MainActor.assumeIsolated {
                guard let self, self.shouldRename(on: event), let onReturn = self.onReturn else {
                    return false
                }
                onReturn()
                return true
            }
            return renamed ? nil : event
        }
    }

    private func shouldRename(on event: NSEvent) -> Bool {
        guard event.keyCode == Self.returnKeyCode || event.keyCode == Self.keypadEnterKeyCode,
              !event.isARepeat,
              event.modifierFlags.isDisjoint(with: Self.shortcutModifiers),
              let window, event.window === window, window.isKeyWindow,
              window.attachedSheet == nil, NSApp.modalWindow == nil,
              !isHiddenOrHasHiddenAncestor,
              let table = enclosingTableView else {
            return false
        }
        return window.firstResponder === table
    }
}
