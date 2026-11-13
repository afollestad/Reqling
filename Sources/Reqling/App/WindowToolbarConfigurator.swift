@preconcurrency import AppKit
import SwiftUI

/// The identifiers of the window toolbar's app-owned items, which `MainToolbar` gives them and the spacer placement
/// finds them by.
enum MainToolbarItemID {
    static let title = "detail-title"
    /// The environment picker, the first trailing item when present; the fixed space goes after it.
    static let trailing = "environment"
    /// Still "history", the inspector's only panel when it was added, so a toolbar layout saved then keeps the item.
    static let inspector = "history"
    static let settings = "settings"
    static let addProject = "add-project"

    /// The detail's trailing items. The picker shows only with a project and the inspector button only beside a request,
    /// and SwiftUI drops an item while it has no content, so the flexible space goes before whichever is present first.
    static let trailingItems = [trailing, inspector, settings]
}

/// Where the window toolbar needs spaces SwiftUI can't place: `NavigationSplitView` drops a `ToolbarSpacer` and ignores
/// a flexible frame. A flexible space goes between the title and the trailing items, a gap the removed system title used
/// to fill, and a fixed one after the environment picker. The flexible space the toolbar already has, before the sidebar
/// toggle, holds the toggle at the sidebar's trailing edge and must stay.
enum MainToolbarSpacerPlacement {
    /// The index to insert a flexible space at, or `nil` when one already sits between the title and the first trailing
    /// item or either is missing.
    static func flexibleSpaceIndex(in identifiers: [NSToolbarItem.Identifier]) -> Int? {
        let trailingItems = Set(MainToolbarItemID.trailingItems.map { NSToolbarItem.Identifier($0) })
        guard let titleIndex = identifiers.firstIndex(of: .init(MainToolbarItemID.title)),
              let trailingIndex = identifiers[titleIndex...].firstIndex(where: trailingItems.contains),
              !identifiers[titleIndex..<trailingIndex].contains(.flexibleSpace) else {
            return nil
        }
        return trailingIndex
    }

    /// The index to insert a fixed space at, just after the environment picker, or `nil` when one is already there or
    /// nothing follows the picker. The space gives the picker its own glass: adjacent items share one capsule, which
    /// made its two-line label read as part of the buttons beside it.
    static func pickerSpaceIndex(in identifiers: [NSToolbarItem.Identifier]) -> Int? {
        guard let trailingIndex = identifiers.firstIndex(of: .init(MainToolbarItemID.trailing)),
              trailingIndex + 1 < identifiers.count,
              identifiers[trailingIndex + 1] != .space else {
            return nil
        }
        return trailingIndex + 1
    }
}

/// Keeps the spaces where `MainToolbarSpacerPlacement` says, re-checking whenever SwiftUI adds or removes an item, and
/// keeps the toolbar uncustomizable: item IDs make it customizable, and a user's arrangement would undo the placement.
struct WindowToolbarConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> WindowToolbarAnchorView {
        WindowToolbarAnchorView()
    }

    func updateNSView(_ nsView: WindowToolbarAnchorView, context: Context) {
        nsView.scheduleUpdate()
    }
}

final class WindowToolbarAnchorView: NSView {
    private weak var observedToolbar: NSToolbar?
    private var isUpdateScheduled = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        scheduleUpdate()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// Deferred a turn, so SwiftUI finishes the toolbar change in progress before the spacer moves.
    func scheduleUpdate() {
        guard !isUpdateScheduled else {
            return
        }
        isUpdateScheduled = true
        Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            isUpdateScheduled = false
            update()
        }
    }

    private func update() {
        guard let toolbar = window?.toolbar else {
            return
        }
        if observedToolbar !== toolbar {
            observedToolbar = toolbar
            let center = NotificationCenter.default
            center.addObserver(self, selector: #selector(toolbarItemsChanged), name: NSToolbar.willAddItemNotification, object: toolbar)
            center.addObserver(self, selector: #selector(toolbarItemsChanged), name: NSToolbar.didRemoveItemNotification, object: toolbar)
        }
        toolbar.allowsUserCustomization = false
        toolbar.allowsDisplayModeCustomization = false
        if let index = MainToolbarSpacerPlacement.flexibleSpaceIndex(in: toolbar.items.map(\.itemIdentifier)) {
            toolbar.insertItem(withItemIdentifier: .flexibleSpace, at: index)
        }
        if let index = MainToolbarSpacerPlacement.pickerSpaceIndex(in: toolbar.items.map(\.itemIdentifier)) {
            toolbar.insertItem(withItemIdentifier: .space, at: index)
        }
    }

    @objc private func toolbarItemsChanged(_: Notification) {
        scheduleUpdate()
    }
}
