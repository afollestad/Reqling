import Foundation

/// Moving folders and requests, including into another project. That move is two saves, one per project folder, and its
/// file references must keep reaching the same files from the new folder.
extension ProjectLifecycle {
    /// Moves a folder or request, with everything inside it, under `parent` (`nil` for the top level) of `destination`
    /// at `index` in its children. Within one project it is `ProjectDocument.moveNode(_:to:at:)`.
    ///
    /// Into another project, it is saved there before it leaves `source`, so a failed save leaves it in both rather than
    /// in neither; leaving `source` sends its old files to the Trash as a delete does. It keeps its IDs unless
    /// `destination` already uses one, as a copied project folder would.
    public func moveNode(
        _ id: RequestNodeID,
        from source: ProjectID,
        to destination: ProjectID,
        into parent: RequestNodeID?,
        at index: Int? = nil
    ) throws -> ProjectNodeMove {
        guard source != destination else {
            try library.mutate(source) { try $0.moveNode(id, to: parent, at: index) }
            return ProjectNodeMove(nodeID: id, localizedPaths: [])
        }
        guard let origin = library.project(source), let node = origin.document?.node(id),
              let target = library.project(destination), let document = target.document,
              parent.map({ document.folder($0) != nil }) ?? true else {
            throw ProjectTreeError.notFound
        }
        // Refused before anything is written: a read-only source could never let go, leaving the item in both, and a
        // read-only destination would refuse it after its local paths were recorded.
        guard !origin.isReadOnly, !target.isReadOnly else {
            throw ProjectStorageError.readOnly
        }
        let fresh = node.subtreeIDs.contains { document.node($0) != nil } ? node.copy() : node
        var localized: [String] = []
        let moved = fresh.mappingPathReferences { reference in
            rebased(reference, from: origin, to: target, localized: &localized)
        }
        try library.mutate(destination) { try $0.insert(moved, into: parent, at: index) }
        do {
            try library.mutate(source) { _ = try $0.removeNode(id) }
        } catch {
            throw ProjectMoveError.leftInSource(error)
        }
        return ProjectNodeMove(nodeID: moved.id, localizedPaths: localized)
    }

    /// `reference` as `destination` reaches the same file. A shared path stays shared while the file is inside the
    /// destination's folder or repository; outside, a path relative to the destination would reach it on this Mac only,
    /// so it becomes a local one and is listed in `localized`. A local path stays local.
    private func rebased(
        _ reference: ProjectPathReference,
        from source: LibraryProject,
        to destination: LibraryProject,
        localized: inout [String]
    ) -> ProjectPathReference {
        // A local path chosen on another Mac has nothing here to carry over, and stays missing.
        guard let url = pathResolver(for: source.id)?.url(for: reference) else {
            return reference
        }
        if case .relative = reference {
            if ProjectPathResolver.sharesLocation(url, with: destination.url) {
                return .relative(ProjectPathResolver.relativePath(from: destination.url, to: url))
            }
            if !localized.contains(url.path) {
                localized.append(url.path)
            }
        }
        if let existing = workspace.localPaths(in: destination.id).first(where: { $0.value == url.path }) {
            return .local(existing.key)
        }
        return workspace.addLocalPath(url.path, in: destination.id)
    }
}

/// Where `ProjectLifecycle.moveNode(_:from:to:into:at:)` put an item.
public struct ProjectNodeMove: Equatable, Sendable {
    /// The item's ID where it landed: its own, or a fresh one when the destination project already used it.
    public let nodeID: RequestNodeID
    /// Files the moved requests use from outside the destination's folder and repository, which it now finds through
    /// paths kept on this Mac only.
    public let localizedPaths: [String]
}

public enum ProjectMoveError: Error {
    /// The item was saved into the destination project but couldn't leave the source, so it is in both.
    case leftInSource(any Error)
}
