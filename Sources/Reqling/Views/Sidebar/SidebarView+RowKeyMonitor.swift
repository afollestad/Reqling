import AppKit
import SwiftUI

/// What the selected sidebar row's keys ask for: Return renames it, as in Finder, and → and ← open and close folders,
/// which the native table can't, since they are rows of their own rather than outline items (`SidebarNodeRow`).
enum SidebarRowKey {
    case rename
    case expand
    case collapse
}

/// The selected sidebar row's keys. Mounted behind that row's name only, it acts while the `NSTableView` holding the
/// row is first responder: the filter field, the editors, a sheet, and the rename field itself keep their keys.
///
/// A local key monitor rather than `.onKeyPress` on the `List`, because the monitor sees the key before the native
/// table does. Scoping it to the selected row makes the focus check exact (this row's own table, by identity) and means
/// a selected row scrolled out of view never starts a rename no one can see.
struct SidebarRowKeyMonitor: NSViewRepresentable {
    /// Returns whether it handled the key; one it didn't goes on to the table.
    let onKey: @MainActor (SidebarRowKey) -> Bool

    func makeNSView(context: Context) -> SidebarRowKeyMonitorView {
        let view = SidebarRowKeyMonitorView()
        view.onKey = onKey
        return view
    }

    func updateNSView(_ view: SidebarRowKeyMonitorView, context: Context) {
        view.onKey = onKey
    }

    static func dismantleNSView(_ view: SidebarRowKeyMonitorView, coordinator: ()) {
        view.stopMonitoring()
    }
}

final class SidebarRowKeyMonitorView: NSView {
    private static let returnKeyCode: UInt16 = 36
    private static let keypadEnterKeyCode: UInt16 = 76
    private static let leftArrowKeyCode: UInt16 = 123
    private static let rightArrowKeyCode: UInt16 = 124
    /// Any of these makes it a different shortcut; ⌘Return sends the request.
    private static let shortcutModifiers: NSEvent.ModifierFlags = [.command, .control, .option, .shift]

    var onKey: (@MainActor (SidebarRowKey) -> Bool)?
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
            let handled = MainActor.assumeIsolated {
                guard let self, let key = self.key(for: event), let onKey = self.onKey else {
                    return false
                }
                return onKey(key)
            }
            return handled ? nil : event
        }
    }

    private func key(for event: NSEvent) -> SidebarRowKey? {
        let key: SidebarRowKey
        switch event.keyCode {
        case Self.returnKeyCode, Self.keypadEnterKeyCode:
            // Held down, Return would start a rename and then commit it.
            guard !event.isARepeat else {
                return nil
            }
            key = .rename
        case Self.rightArrowKeyCode:
            key = .expand
        case Self.leftArrowKeyCode:
            key = .collapse
        default:
            return nil
        }
        guard event.modifierFlags.isDisjoint(with: Self.shortcutModifiers),
              let window, event.window === window, window.isKeyWindow,
              window.attachedSheet == nil, NSApp.modalWindow == nil,
              !isHiddenOrHasHiddenAncestor,
              let table = enclosingTableView,
              window.firstResponder === table else {
            return nil
        }
        return key
    }
}
