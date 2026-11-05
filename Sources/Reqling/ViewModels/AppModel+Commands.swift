import Foundation
import ReqlingKit

/// Project and item commands. Every edit goes through `ProjectLibrary.mutate`, so it is saved before it is shown.
extension AppModel {
    // MARK: - Projects

    func createProject(named name: String, in directory: URL? = nil) {
        guard let id = perform("Couldn't Create the Project", { try library.createProject(named: name, in: directory) }) else {
            return
        }
        selection = .project(id)
    }

    func openProjectFolder() {
        guard let url = system.chooseDirectory(prompt: "Add Project") else {
            return
        }
        guard let id = perform("Couldn't Add the Project", { try lifecycle.addProjectFolder(url) }) else {
            return
        }
        selection = .project(id)
    }

    func removeProject(_ id: ProjectID) {
        if selection?.projectID == id {
            selection = nil
        }
        lifecycle.removeProject(id)
    }

    func deleteProject(_ id: ProjectID) {
        if selection?.projectID == id {
            selection = nil
        }
        perform("Couldn't Delete the Project") { try lifecycle.deleteProject(id) }
    }

    func renameProject(_ id: ProjectID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return
        }
        perform("Couldn't Rename the Project") {
            try library.mutate(id) { $0.name = trimmed }
        }
    }

    func revealProject(_ id: ProjectID) {
        if let url = library.project(id)?.url {
            system.reveal(url)
        }
    }

    // MARK: - Items

    /// Where a new item goes: inside the selected folder, beside the selected request, or at the project root.
    private func insertionPoint(in project: ProjectID) -> (parent: RequestNodeID?, index: Int?) {
        guard selection?.projectID == project, let nodeID = selection?.nodeID, let document = library.document(project) else {
            return (nil, nil)
        }
        if document.folder(nodeID) != nil {
            return (nodeID, nil)
        }
        let parent = document.parentID(of: nodeID)
        let siblings = document.children(of: parent) ?? []
        return (parent, siblings.firstIndex { $0.id == nodeID }.map { $0 + 1 })
    }

    func newRequest(in project: ProjectID? = nil) {
        insertRequest(RequestItem(name: "New Request", kind: .http(HTTPRequestSpec())), in: project)
    }

    private func insertRequest(_ request: RequestItem, in project: ProjectID?) {
        guard let project = project ?? activeProjectID else {
            sheet = .newProject
            return
        }
        let point = insertionPoint(in: project)
        guard perform("Couldn't Add the Request", {
            try library.mutate(project) { try $0.insert(.request(request), into: point.parent, at: point.index) }
        }) != nil else {
            return
        }
        expandAncestors(of: request.id, in: project)
        selection = .node(project, request.id)
    }

    /// Switches a request between HTTP and gRPC in place, asking first through `kindChangePending` when the switch
    /// would discard something. Flushes first, so the conversion starts from the draft rather than the last save. Refused
    /// mid-run: the run belongs to the old protocol, and the editor that could show or cancel it is about to go.
    func changeKind(of request: RequestNodeID, in project: ProjectID, to kind: RequestKind.Name) {
        flushPendingEdits()
        guard !runner.isInFlight(request, in: project), let item = library.document(project)?.request(request), item.kind.name != kind else {
            return
        }
        let change = RequestKindChange(projectID: project, requestID: request, name: item.name, kind: kind)
        if item.kind.losesContent(convertingTo: kind) {
            kindChangePending = change
        } else {
            applyKindChange(change)
        }
    }

    func applyKindChange(_ change: RequestKindChange) {
        kindChangePending = nil
        guard perform("Couldn't Change the Request", {
            try library.mutate(change.projectID) { document in
                try document.updateRequest(change.requestID) { $0.kind = $0.kind.converted(to: change.kind) }
            }
        }) != nil else {
            return
        }
        // Before the new editor exists, so it never shows the old protocol's response.
        runner.forget(change.requestID, in: change.projectID)
        syncEditor()
    }

    func newFolder(in project: ProjectID? = nil) {
        guard let project = project ?? activeProjectID else {
            sheet = .newProject
            return
        }
        let folder = RequestFolder(name: "New Folder")
        let point = insertionPoint(in: project)
        guard perform("Couldn't Add the Folder", {
            try library.mutate(project) { try $0.insert(.folder(folder), into: point.parent, at: point.index) }
        }) != nil else {
            return
        }
        expandAncestors(of: folder.id, in: project)
        selection = .node(project, folder.id)
    }

    func rename(_ node: RequestNodeID, in project: ProjectID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return
        }
        if editor?.identity == .node(project, node) {
            editor?.flush()
        }
        perform("Couldn't Rename the Item") {
            try library.mutate(project) { try $0.updateNode(node) { $0.name = trimmed } }
        }
        editor?.adoptExternalChange()
    }

    func duplicate(_ node: RequestNodeID, in project: ProjectID) {
        flushPendingEdits()
        guard let document = library.document(project), let original = document.node(node) else {
            return
        }
        let copy = original.copy(named: "\(original.name) Copy")
        let parent = document.parentID(of: node)
        let index = (document.children(of: parent) ?? []).firstIndex { $0.id == node }.map { $0 + 1 }
        guard perform("Couldn't Duplicate the Item", {
            try library.mutate(project) { try $0.insert(copy, into: parent, at: index) }
        }) != nil else {
            return
        }
        selection = .node(project, copy.id)
    }

    /// Moves the item to the Trash with its file, dropping its requests' history; Finder's Put Back restores the file.
    /// A selection on or inside the item moves to its parent first, so a pending edit there saves before its file goes
    /// instead of failing after.
    func delete(_ node: RequestNodeID, in project: ProjectID) {
        let document = library.document(project)
        if selection?.projectID == project, let selected = selection?.nodeID,
           selected == node || document?.ancestors(of: selected).contains(where: { $0.id == node }) == true {
            selection = document?.parentID(of: node).map { .node(project, $0) } ?? .project(project)
        }
        perform("Couldn't Delete the Item") {
            try lifecycle.deleteNode(node, in: project)
        }
    }

    /// Moves within a project; `index` is in the destination's children after the item is lifted out.
    func move(_ node: RequestNodeID, in project: ProjectID, to parent: RequestNodeID?, at index: Int?) {
        flushPendingEdits()
        perform("Couldn't Move the Item") {
            try library.mutate(project) { try $0.moveNode(node, to: parent, at: index) }
        }
        if let parent {
            workspace.updateProject(project) { $0.expandedFolderIDs.insert(parent) }
        }
    }

    func beginRename(_ node: RequestNodeID?, in project: ProjectID) {
        let name = node.flatMap { library.document(project)?.node($0)?.name } ?? library.project(project)?.name ?? ""
        renaming = RenameTarget(projectID: project, nodeID: node, name: name)
        isRenaming = true
    }

    func cancelRename() {
        renaming = nil
        isRenaming = false
    }

    func commitRename() {
        guard let renaming else {
            return
        }
        cancelRename()
        if let node = renaming.nodeID {
            rename(node, in: renaming.projectID, to: renaming.name)
        } else {
            renameProject(renaming.projectID, to: renaming.name)
        }
    }

    /// Whether dropping `node` onto `target` is a valid move: same project, and never into itself or a descendant.
    func canMove(_ node: RequestNodeID, in project: ProjectID, into parent: RequestNodeID?) -> Bool {
        guard let document = library.document(project), document.node(node) != nil else {
            return false
        }
        guard let parent else {
            return true
        }
        return parent != node && !document.ancestors(of: parent).contains { $0.id == node }
    }

    // MARK: - Sidebar expansion

    func isExpanded(_ project: ProjectID) -> Bool {
        !workspace.projectState(project).isCollapsed
    }

    func setExpanded(_ isExpanded: Bool, project: ProjectID) {
        workspace.updateProject(project) { $0.isCollapsed = !isExpanded }
    }

    func isExpanded(folder: RequestNodeID, in project: ProjectID) -> Bool {
        workspace.projectState(project).expandedFolderIDs.contains(folder)
    }

    func setExpanded(_ isExpanded: Bool, folder: RequestNodeID, in project: ProjectID) {
        workspace.updateProject(project) { state in
            if isExpanded {
                state.expandedFolderIDs.insert(folder)
            } else {
                state.expandedFolderIDs.remove(folder)
            }
        }
    }

    func expandAncestors(of node: RequestNodeID, in project: ProjectID) {
        let ancestors = library.document(project)?.ancestors(of: node).map(\.id) ?? []
        workspace.updateProject(project) { state in
            state.isCollapsed = false
            state.expandedFolderIDs.formUnion(ancestors)
        }
    }

    // MARK: - Files

    /// Turns a chosen file into a reference: relative when it lives with the project, otherwise as the user picks.
    func reference(for url: URL, in project: ProjectID) -> ProjectPathReference? {
        guard let root = library.project(project)?.url else {
            return nil
        }
        let sharing: PathSharing
        if ProjectPathResolver.sharesLocation(url, with: root) {
            sharing = .shared
        } else {
            guard let choice = system.choosePathSharing(for: url) else {
                return nil
            }
            sharing = choice
        }
        switch sharing {
        case .shared:
            return .relative(ProjectPathResolver.relativePath(from: root, to: url))
        case .thisMacOnly:
            return workspace.addLocalPath(url.path, in: project)
        }
    }

    func pathResolver(for project: ProjectID) -> ProjectPathResolver? {
        lifecycle.pathResolver(for: project)
    }
}
