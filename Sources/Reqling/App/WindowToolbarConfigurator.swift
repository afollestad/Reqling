@preconcurrency import AppKit
import SwiftUI

/// The identifiers of the window toolbar's app-owned items, which `MainToolbar` gives them and the spacer placement
/// finds them by.
enum MainToolbarItemID {
    static let title = "detail-title"
    /// The first trailing item; the flexible space goes just before it.
    static let trailing = "environment"
    static let history = "history"
    static let settings = "settings"
    static let addProject = "add-project"
}

/// Where the window toolbar needs a flexible space: between the title and the trailing items. The removed system title
/// was what filled that gap, and SwiftUI offers no replacement there: `NavigationSplitView` drops a `ToolbarSpacer` and
/// ignores a flexible frame, packing the trailing items against the title. The flexible space it already has, before
/// the sidebar toggle, holds the toggle at the sidebar's trailing edge and must stay.
enum MainToolbarSpacerPlacement {
    /// The index to insert a flexible space at, or `nil` when one already sits between the title and the trailing items
    /// or either is missing.
    static func insertionIndex(in identifiers: [NSToolbarItem.Identifier]) -> Int? {
        guard let titleIndex = identifiers.firstIndex(of: .init(MainToolbarItemID.title)),
              let trailingIndex = identifiers.firstIndex(of: .init(MainToolbarItemID.trailing)),
              titleIndex < trailingIndex,
              !identifiers[titleIndex..<trailingIndex].contains(.flexibleSpace) else {
            return nil
        }
        return trailingIndex
    }
}

/// Keeps a flexible space where `MainToolbarSpacerPlacement` says, re-checking whenever SwiftUI adds or removes an
/// item, and keeps the toolbar uncustomizable: item IDs make it customizable, and a user's arrangement would undo the
/// placement.
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
        if let index = MainToolbarSpacerPlacement.insertionIndex(in: toolbar.items.map(\.itemIdentifier)) {
            toolbar.insertItem(withItemIdentifier: .flexibleSpace, at: index)
        }
    }

    @objc private func toolbarItemsChanged(_: Notification) {
        scheduleUpdate()
    }
}
