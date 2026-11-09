import Foundation
import ReqlingKit

/// Moving folders and requests, within a project or into another, and reordering projects. A move into another project
/// asks first (`MoveConfirmation`): it rewrites two project folders and sends the old files to the Trash.
extension AppModel {
    /// Moves within a project; `index` is in the destination's children after the item is lifted out. Opens the
    /// project and folders around where it landed, so a drop into a closed one doesn't hide it.
    func move(_ node: RequestNodeID, in project: ProjectID, to parent: RequestNodeID?, at index: Int?) {
        flushPendingEdits()
        let moved: Void? = perform("Couldn't Move the Item") {
            try library.mutate(project) { try $0.moveNode(node, to: parent, at: index) }
        }
        if moved != nil {
            expandAncestors(of: node, in: project)
        }
    }

    /// Whether `node` may move under `parent` (`nil` for the top level) within `project`.
    func canMove(_ node: RequestNodeID, in project: ProjectID, into parent: RequestNodeID?) -> Bool {
        canMoveNode(node, from: project, to: project, into: parent)
    }

    /// Whether `node` may move from `source` under `parent` (`nil` for the top level) of `destination`. Both projects
    /// must be loaded and writable, as `ProjectLifecycle.moveNode` requires before it writes anything, and a folder never
    /// moves into itself or its own descendants.
    func canMoveNode(_ node: RequestNodeID, from source: ProjectID, to destination: ProjectID, into parent: RequestNodeID?) -> Bool {
        guard let origin = library.project(source), !origin.isReadOnly, let document = origin.document, document.node(node) != nil,
              let target = library.project(destination), !target.isReadOnly, let targetDocument = target.document else {
            return false
        }
        guard let parent else {
            return true
        }
        guard targetDocument.folder(parent) != nil else {
            return false
        }
        return source != destination || (parent != node && !document.ancestors(of: parent).contains { $0.id == node })
    }

    /// A drop's move: at once within a project, and only once confirmed into another (`movePending`).
    func requestMove(_ node: RequestNodeID, from source: ProjectID, to destination: ProjectID, into parent: RequestNodeID?, at index: Int?) {
        guard canMoveNode(node, from: source, to: destination, into: parent) else {
            return
        }
        guard source != destination else {
            move(node, in: source, to: parent, at: index)
            return
        }
        movePending = moveConfirmation(MoveConfirmation.Request(
            nodeID: node, source: source, destination: destination, parent: parent, index: index
        ))
    }

    /// Moves a confirmed item into the other project through `ProjectLifecycle.moveNode`, which carries its history and
    /// rebases its file references. An agent or a `git pull` can move or delete the item or its destination while the
    /// confirmation is up; confirming then drops it quietly, as `trash(_:)` does.
    ///
    /// A selection on or inside the item follows it; the item keeps its IDs unless the destination already used one,
    /// and then only its own new ID is known, so a selection inside it lands on the item itself.
    func move(_ confirmation: MoveConfirmation) {
        movePending = nil
        let request = confirmation.request
        guard canMoveNode(request.nodeID, from: request.source, to: request.destination, into: request.parent) else {
            return
        }
        flushPendingEdits()
        let followed = selectionInside(request.nodeID, in: request.source)
        let moved: ProjectNodeMove
        do {
            moved = try lifecycle.moveNode(
                request.nodeID, from: request.source, to: request.destination, into: request.parent, at: request.index
            )
        } catch ProjectMoveError.leftInSource(let error) {
            alert = AppAlert(
                title: "Couldn't Move the Item",
                message: "It was added to “\(confirmation.destinationName)” but couldn't leave “\(confirmation.sourceName)”, so it "
                    + "is in both: \(error.localizedDescription)"
            )
            return
        } catch {
            alert = AppAlert(title: "Couldn't Move the Item", message: error.localizedDescription)
            return
        }
        expandAncestors(of: moved.nodeID, in: request.destination)
        if let followed {
            let landed = moved.nodeID == request.nodeID ? followed : moved.nodeID
            expandAncestors(of: landed, in: request.destination)
            selection = .node(request.destination, landed)
        }
        if !moved.localizedPaths.isEmpty {
            alert = AppAlert(
                title: "Files Now Found on This Mac Only",
                message: "These files are outside “\(confirmation.destinationName)”'s folder and repository, so it now reaches them "
                    + "through paths kept on this Mac only:\n\n" + moved.localizedPaths.joined(separator: "\n")
            )
        }
    }

    /// Puts `project` at `index` among the sidebar's projects, counted without it. The order is this Mac's own.
    func moveProject(_ project: ProjectID, to index: Int) {
        library.moveProject(project, to: index)
    }

    /// The confirmation for `request`, or `nil` when its item or either project is gone.
    private func moveConfirmation(_ request: MoveConfirmation.Request) -> MoveConfirmation? {
        guard let node = library.document(request.source)?.node(request.nodeID),
              let source = library.project(request.source), let destination = library.project(request.destination) else {
            return nil
        }
        return MoveConfirmation(
            request: request,
            name: node.name,
            isFolder: node.isFolder,
            sourceName: source.name,
            destinationName: destination.name,
            syncs: iCloud.sync?.syncs(request.source) ?? false
        )
    }

    /// The selected node when it is `node` or inside it, in `project`.
    private func selectionInside(_ node: RequestNodeID, in project: ProjectID) -> RequestNodeID? {
        guard case .node(project, let selected)? = selection, let document = library.document(project) else {
            return nil
        }
        return selected == node || document.ancestors(of: selected).contains { $0.id == node } ? selected : nil
    }
}
