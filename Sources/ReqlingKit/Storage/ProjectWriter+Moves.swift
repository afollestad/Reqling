import Foundation
import ReqlingScriptProtocol

/// The moving half of a save. Renames run in two phases through `ProjectLayout.syncScratchDirectory`, so swapping two
/// names, or moving an item out of a folder deleted in the same save, never collides or trashes the moved item.
extension ProjectWriter {
    /// An item parked in scratch, with what it takes to put it back if the save fails.
    struct LiftedItem {
        /// The folder the item came out of, followed to wherever that folder is when restoring; `nil` when the item
        /// came straight out of `directory` (the top level, or the environments folder).
        let parentID: RequestNodeID?
        let directory: String
        let name: String
        let scratchPath: String
    }

    /// The items whose own name or parent changed, at their current paths. Descendants of a renamed folder are not
    /// listed: they travel with it.
    func liftedItems(document: ProjectDocument, layout: ProjectSaveLayout, live: LivePaths) -> LivePaths {
        let idsByPath = Dictionary(live.nodes.map { ($0.value, $0.key) }, uniquingKeysWith: { first, _ in first })
        let nodes = live.nodes.filter { id, path in
            guard let desired = layout.nodePaths[id] else {
                return false
            }
            return Self.name(of: path) != Self.name(of: desired) || idsByPath[Self.parent(of: path)] != document.parentID(of: id)
        }
        let environments = live.environments.filter { id, path in layout.environmentPaths[id].map { $0 != path } ?? false }
        return LivePaths(nodes: nodes, environments: environments)
    }

    /// Lifts every item `liftedItems` lists into scratch.
    func liftChangedItems(document: ProjectDocument, layout: ProjectSaveLayout, live: inout LivePaths, lifted: inout [LiftedItem]) throws {
        let idsByPath = Dictionary(live.nodes.map { ($0.value, $0.key) }, uniquingKeysWith: { first, _ in first })
        let changed = liftedItems(document: document, layout: layout, live: live)
        let moved = changed.nodes
        let movedEnvironments = changed.environments
        if !moved.isEmpty {
            try createDirectory(ProjectLayout.scratchRequestsDirectory)
        }
        // Deepest first, so a child is lifted out before its moving parent re-homes it.
        for (id, original) in moved.sorted(by: { Self.depth(of: $0.value) > Self.depth(of: $1.value) }) {
            let path = live.nodes[id] ?? original
            // Requests keep their extension in scratch, so the reader can tell them from folders after a crash.
            let scratchName = isDirectory(path) ? UUID().uuidString : "\(UUID().uuidString).\(ProjectLayout.jsonExtension)"
            let scratchPath = ProjectLayout.join(ProjectLayout.scratchRequestsDirectory, scratchName)
            try move(path, to: scratchPath, live: &live)
            let directory = Self.parent(of: path)
            lifted.append(LiftedItem(parentID: idsByPath[directory], directory: directory, name: Self.name(of: path), scratchPath: scratchPath))
        }
        if !movedEnvironments.isEmpty {
            try createDirectory(ProjectLayout.scratchEnvironmentsDirectory)
        }
        for (id, path) in movedEnvironments {
            let scratchPath = ProjectLayout.join(ProjectLayout.scratchEnvironmentsDirectory, "\(UUID().uuidString).\(ProjectLayout.jsonExtension)")
            try moveEnvironment(id, from: path, to: scratchPath, live: &live)
            lifted.append(LiftedItem(parentID: nil, directory: Self.parent(of: path), name: Self.name(of: path), scratchPath: scratchPath))
        }
    }

    func trashRemovedItems(document: ProjectDocument, live: inout LivePaths) throws {
        // Outermost first: trashing a folder takes its removed descendants with it.
        let removed = live.nodes
            .filter { document.node($0.key) == nil }
            .sorted { Self.depth(of: $0.value) < Self.depth(of: $1.value) }
        for (id, _) in removed {
            // A removed item may sit inside a folder that was lifted into scratch, so use its live path.
            guard let path = live.nodes[id] else {
                continue
            }
            if exists(path) {
                try trasher.trash(url(path))
            }
            for script in Self.scriptPaths(ofRequestAt: path, phases: live.scripts[id]) where exists(script) {
                try trasher.trash(url(script))
            }
            live.scripts[id] = nil
            let prefix = path + "/"
            live.nodes = live.nodes.filter { $0.value != path && !$0.value.hasPrefix(prefix) }
        }
        let validEnvironments = Set(document.allEnvironments.map(\.id))
        for (id, path) in live.environments where !validEnvironments.contains(id) {
            if exists(path) {
                try trasher.trash(url(path))
            }
            live.environments[id] = nil
        }
    }

    /// Pre-order, so every folder is in its final place before its children are moved into it.
    func placeNodes(_ nodes: [RequestNode], layout: ProjectSaveLayout, live: inout LivePaths) throws {
        for node in nodes {
            guard let desired = layout.nodePaths[node.id] else {
                continue
            }
            if let livePath = live.nodes[node.id] {
                if livePath != desired {
                    try move(livePath, to: desired, live: &live)
                }
            } else if node.isFolder {
                try createDirectory(desired)
                live.nodes[node.id] = desired
            }
            if case .folder(let folder) = node {
                try placeNodes(folder.children, layout: layout, live: &live)
            }
        }
    }

    func placeEnvironments(document: ProjectDocument, layout: ProjectSaveLayout, live: inout LivePaths) throws {
        for environment in document.allEnvironments {
            guard let desired = layout.environmentPaths[environment.id],
                  let livePath = live.environments[environment.id],
                  livePath != desired else {
                continue
            }
            try moveEnvironment(environment.id, from: livePath, to: desired, live: &live)
        }
    }

    /// Puts back whatever a failed save left in scratch, newest first, so a lifted folder is home again before the
    /// children lifted out of it return. An item whose folder went to the Trash stays in scratch, where the reader
    /// recovers it; a name taken in the meantime gets a numbered variant rather than being overwritten.
    func restoreFromScratch(_ lifted: [LiftedItem], live: inout LivePaths) {
        for item in lifted.reversed() where exists(item.scratchPath) {
            let directory: String? = if let parentID = item.parentID { live.nodes[parentID] } else { item.directory }
            guard let directory, isDirectory(directory) else {
                continue
            }
            try? move(item.scratchPath, to: ProjectLayout.join(directory, availableName(item.name, in: directory)), live: &live)
        }
    }

    /// Removes the scratch directories once they are empty. One that still holds items after a failed save is kept:
    /// they are the only copy of what was being moved.
    func removeEmptyScratch() {
        let directories = [ProjectLayout.scratchRequestsDirectory, ProjectLayout.scratchEnvironmentsDirectory, ProjectLayout.syncScratchDirectory]
        for directory in directories {
            let path = url(directory).path
            if let names = try? fileManager.contentsOfDirectory(atPath: path), names.isEmpty {
                try? fileManager.removeItem(atPath: path)
            }
        }
    }

    /// Moves a file or folder, a request's scripts with it, and re-points every live node path beneath it.
    private func move(_ source: String, to destination: String, live: inout LivePaths) throws {
        try fileManager.moveItem(at: url(source), to: url(destination))
        if let id = live.nodes.first(where: { $0.value == source })?.key {
            for phase in live.scripts[id] ?? [] {
                let script = ProjectLayout.scriptPath(forRequestAt: source, phase)
                if exists(script) {
                    try fileManager.moveItem(at: url(script), to: url(ProjectLayout.scriptPath(forRequestAt: destination, phase)))
                }
            }
        }
        let prefix = source + "/"
        live.nodes = live.nodes.mapValues { path in
            if path == source {
                return destination
            }
            if path.hasPrefix(prefix) {
                return destination + "/" + path.dropFirst(prefix.count)
            }
            return path
        }
    }

    private func moveEnvironment(_ id: EnvironmentID, from source: String, to destination: String, live: inout LivePaths) throws {
        try fileManager.moveItem(at: url(source), to: url(destination))
        live.environments[id] = destination
    }

    /// `name`, or `<stem>-2.<ext>` and so on when it, or a request's script file beside it, is taken.
    private func availableName(_ name: String, in directory: String) -> String {
        let stem = (name as NSString).deletingPathExtension
        let pathExtension = (name as NSString).pathExtension
        func isTaken(_ candidate: String) -> Bool {
            let path = ProjectLayout.join(directory, candidate)
            guard !exists(path) else {
                return true
            }
            return pathExtension == ProjectLayout.jsonExtension
                && ScriptPhase.allCases.contains { exists(ProjectLayout.scriptPath(forRequestAt: path, $0)) }
        }
        var candidate = name
        var suffix = 2
        while isTaken(candidate) {
            candidate = pathExtension.isEmpty ? "\(stem)-\(suffix)" : "\(stem)-\(suffix).\(pathExtension)"
            suffix += 1
        }
        return candidate
    }

    private static func name(of path: String) -> String {
        (path as NSString).lastPathComponent
    }

    private static func parent(of path: String) -> String {
        (path as NSString).deletingLastPathComponent
    }

    private static func depth(of path: String) -> Int {
        path.split(separator: "/").count
    }
}
