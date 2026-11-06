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
            renaming = item
        }
    }

    /// `name` is `nil` to cancel. Ignored unless `item` is still the one being renamed: removing the field ends its
    /// editing once more after Return or a click away already did. An item deleted or made read-only mid-edit (by an
    /// agent, or a `git pull`) drops the name, rather than raising an alert about a row that is gone.
    func endRename(_ item: SidebarItem, to name: String?) {
        guard renaming == item else {
            return
        }
        renaming = nil
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
