import ReqlingKit

/// Renaming a project, folder, or request in place in its sidebar row. The row's field lives only as long as
/// `renaming` names that row, and reports back through `endRename(_:to:)`. The window title renames on its own, through
/// `rename(_:to:)` in `AppModel+DetailTitle.swift`.
extension AppModel {
    /// False for a project that did not load or is read-only, and for an item that no longer exists, where a rename
    /// could only raise an alert. The title bar's pencil and the sidebar's Rename both follow it.
    func canRename(_ item: SidebarItem) -> Bool {
        guard let project = library.project(item.projectID), let document = project.document, !project.isReadOnly else {
            return false
        }
        return item.nodeID.map { document.node($0) != nil } ?? true
    }

    func beginRename(_ item: SidebarItem) {
        if canRename(item) {
            renameSession += 1
            renaming = item
        }
    }

    /// Only where the sidebar shows the new row: one the filter hides has no field, and `renaming` would linger until a
    /// filter change showed the row, whose field would then take the keyboard from whatever had it.
    func beginRenameOfNewItem(_ item: SidebarItem) {
        if sidebar.shows(item) {
            beginRename(item)
        }
    }

    /// `name` is `nil` to cancel. Each field reports its end once. A rename that a newer one replaced (⌘N mid-edit
    /// starts another) still lands on `item` as its field goes, and leaves the newer one going. An item deleted or made
    /// read-only mid-edit (by an agent, or a `git pull`) drops the name, rather than raising an alert about a row that
    /// is gone.
    func endRename(_ item: SidebarItem, to name: String?) {
        if renaming == item {
            renaming = nil
        }
        guard let name, canRename(item) else {
            return
        }
        switch item {
        case .project(let project):
            renameProject(project, to: name)
        case .node(let project, let node):
            rename(node, in: project, to: name)
        }
    }
}
