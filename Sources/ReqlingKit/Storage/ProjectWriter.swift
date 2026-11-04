import Foundation

/// Saves a `ProjectDocument` by reconciling the folder against the last-known `ProjectDiskIndex`: renamed and moved
/// items are moved on disk (so git sees renames, not delete-and-add), removed items go to the Trash, and only files
/// whose content changed are rewritten.
///
/// Every check that can refuse a save runs before the first disk change: no target may be, or sit inside, an entry the
/// reader could not load; no file about to be overwritten may differ from the bytes last read; and no new file's path
/// may be taken by anything this save does not move away. Moves are two-phase (`ProjectWriter+Moves.swift`), and a
/// save that fails part-way puts its scratch items back before rethrowing.
struct ProjectWriter {
    let root: URL
    let trasher: any FileTrashing
    let fileManager = FileManager.default

    init(root: URL, trasher: any FileTrashing) {
        self.root = root
        self.trasher = trasher
    }

    /// Writes `document` and returns the index describing the folder afterwards.
    func save(_ document: ProjectDocument, previous: ProjectDiskIndex) throws -> ProjectDiskIndex {
        var layout = ProjectSaveLayout(previous: previous)
        let requests = ProjectLayout.requestsDirectory
        let rootOrder = layout.assignChildren(document.items, parentPath: requests, previousPath: requests)
        layout.assignEnvironments(document.environments, defaultID: document.defaultEnvironment.id)
        let files = try plannedFiles(document, layout: layout, rootOrder: rootOrder, previous: previous)
        let untracked = layout.projectedUntrackedPaths()
        try checkTargets(files, layout: layout, untracked: untracked)
        try checkUnchangedOnDisk(files, previous: previous)
        try checkNewFilesHaveRoom(files, vacating: vacatedPaths(document: document, layout: layout, previous: previous), previous: previous)

        var live = LivePaths(nodes: previous.nodePaths, environments: previous.environmentPaths)
        var lifted: [LiftedItem] = []
        defer {
            removeEmptyScratch()
        }
        do {
            try liftChangedItems(document: document, layout: layout, live: &live, lifted: &lifted)
            try trashRemovedItems(document: document, live: &live)
            try createDirectory(ProjectLayout.requestsDirectory)
            try createDirectory(ProjectLayout.environmentsDirectory)
            try placeNodes(document.items, layout: layout, live: &live)
            try placeEnvironments(document: document, layout: layout, live: &live)
        } catch {
            restoreFromScratch(lifted, live: &live)
            throw error
        }
        var next = try write(files, layout: layout, previous: previous, untracked: untracked)
        next.orders[ProjectLayout.requestsDirectory] = rootOrder
        for (folderID, order) in layout.childOrder {
            if let path = layout.nodePaths[folderID] {
                next.orders[path] = order
            }
        }
        return next
    }

    // MARK: - Planning

    private func plannedFiles(
        _ document: ProjectDocument,
        layout: ProjectSaveLayout,
        rootOrder: [String],
        previous: ProjectDiskIndex
    ) throws -> [PlannedFile] {
        let projectFile = ProjectFile(
            formatVersion: document.formatVersion,
            id: document.id,
            name: document.name,
            environmentOrder: document.environments.map(\.id),
            rootOrder: rootOrder,
            auth: document.auth,
            tls: document.tls
        )
        var files = [PlannedFile(path: ProjectLayout.projectFile, data: try ProjectJSON.encode(projectFile), source: ProjectLayout.projectFile)]
        var defaultEnvironment = document.defaultEnvironment
        defaultEnvironment.name = RequestEnvironment.defaultName
        for environment in [defaultEnvironment] + document.environments {
            guard let path = layout.environmentPaths[environment.id] else {
                continue
            }
            files.append(PlannedFile(path: path, data: try ProjectJSON.encode(environment), source: previous.environmentPaths[environment.id]))
        }
        try appendNodeFiles(document.items, layout: layout, previous: previous, to: &files)
        return files
    }

    private func appendNodeFiles(
        _ nodes: [RequestNode],
        layout: ProjectSaveLayout,
        previous: ProjectDiskIndex,
        to files: inout [PlannedFile]
    ) throws {
        for node in nodes {
            guard let path = layout.nodePaths[node.id] else {
                continue
            }
            let source = previous.nodePaths[node.id]
            switch node {
            case .request(let request):
                files.append(PlannedFile(path: path, data: try ProjectJSON.encode(request), source: source))
            case .folder(let folder):
                let folderFile = FolderFile(id: folder.id, name: folder.name, order: layout.childOrder[folder.id] ?? [], auth: folder.auth)
                files.append(PlannedFile(
                    path: ProjectLayout.join(path, ProjectLayout.folderFile),
                    data: try ProjectJSON.encode(folderFile),
                    source: source.map { ProjectLayout.join($0, ProjectLayout.folderFile) }
                ))
                try appendNodeFiles(folder.children, layout: layout, previous: previous, to: &files)
            }
        }
    }

    // MARK: - Checks

    /// Refuses to write over, or into, an entry the reader could not load. Compared case-insensitively, as the default
    /// APFS volume resolves names, against where those entries will be after this save's folder moves.
    private func checkTargets(_ files: [PlannedFile], layout: ProjectSaveLayout, untracked: Set<String>) throws {
        let folded = untracked.map { (path: $0, folded: $0.lowercased()) }
        for target in files.map(\.path) + layout.nodePaths.values {
            let foldedTarget = target.lowercased()
            if let blocking = folded.first(where: { foldedTarget == $0.folded || foldedTarget.hasPrefix($0.folded + "/") }) {
                throw ProjectStorageError.unreadableFileInTheWay(blocking.path)
            }
        }
    }

    /// Refuses to overwrite a file whose bytes changed since they were read: the change monitor has not delivered that
    /// edit yet, and the reload that follows the failed save picks it up instead of losing it.
    private func checkUnchangedOnDisk(_ files: [PlannedFile], previous: ProjectDiskIndex) throws {
        for file in files where !file.isUnchanged(in: previous) {
            guard let source = file.source, let expected = previous.diskContents[source] else {
                continue
            }
            guard (try? Data(contentsOf: url(source))) == expected else {
                throw ProjectStorageError.changedOnDisk(source)
            }
        }
    }

    /// Refuses a new file whose path is already taken, unless what is there is tracked and this save moves it away or
    /// trashes it: anything else arrived after the last read, and an atomic write would replace it.
    private func checkNewFilesHaveRoom(_ files: [PlannedFile], vacating vacated: [String], previous: ProjectDiskIndex) throws {
        for file in files where !file.isUnchanged(in: previous) && file.source.flatMap({ previous.diskContents[$0] }) == nil {
            guard exists(file.path) else {
                continue
            }
            let folded = file.path.lowercased()
            guard vacated.contains(where: { folded == $0 || folded.hasPrefix($0 + "/") }) else {
                throw ProjectStorageError.changedOnDisk(file.path)
            }
        }
    }

    /// The current, lower-cased paths of every tracked item this save lifts out or trashes; their contents go with them.
    private func vacatedPaths(document: ProjectDocument, layout: ProjectSaveLayout, previous: ProjectDiskIndex) -> [String] {
        let live = LivePaths(nodes: previous.nodePaths, environments: previous.environmentPaths)
        let lifted = liftedItems(document: document, layout: layout, live: live)
        let removedNodes = previous.nodePaths.filter { document.node($0.key) == nil }.values
        let validEnvironments = Set(document.allEnvironments.map(\.id))
        let removedEnvironments = previous.environmentPaths.filter { !validEnvironments.contains($0.key) }.values
        return (Array(lifted.nodes.values) + Array(lifted.environments.values) + removedNodes + removedEnvironments).map { $0.lowercased() }
    }

    // MARK: - Writing

    private func write(
        _ files: [PlannedFile],
        layout: ProjectSaveLayout,
        previous: ProjectDiskIndex,
        untracked: Set<String>
    ) throws -> ProjectDiskIndex {
        var next = ProjectDiskIndex(nodePaths: layout.nodePaths, environmentPaths: layout.environmentPaths, untrackedPaths: untracked)
        for file in files {
            next.contents[file.path] = file.data
            let tracked = file.source.flatMap { previous.diskContents[$0] }
            if file.isUnchanged(in: previous) {
                next.diskContents[file.path] = tracked
                continue
            }
            // Checked up front already; this catches only a file that appeared while the save was moving items.
            if tracked == nil, exists(file.path) {
                throw ProjectStorageError.changedOnDisk(file.path)
            }
            try file.data.write(to: url(file.path), options: .atomic)
            next.diskContents[file.path] = file.data
        }
        return next
    }

    // MARK: - Paths

    func createDirectory(_ relativePath: String) throws {
        try fileManager.createDirectory(at: url(relativePath), withIntermediateDirectories: true)
    }

    func isDirectory(_ relativePath: String) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url(relativePath).path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    func exists(_ relativePath: String) -> Bool {
        fileManager.fileExists(atPath: url(relativePath).path)
    }

    func url(_ relativePath: String) -> URL {
        root.appendingPathComponent(relativePath)
    }
}

/// A file a save produces, and where its current version is before anything moves (`nil` for a new file).
struct PlannedFile {
    let path: String
    let data: Data
    let source: String?

    /// Whether the file's content matches what was read, so writing it would change nothing that Reqling models.
    func isUnchanged(in previous: ProjectDiskIndex) -> Bool {
        source.map { previous.contents[$0] == data } ?? false
    }
}

/// Where each tracked item is on disk at this point of a save, updated as items move.
struct LivePaths {
    var nodes: [RequestNodeID: String]
    var environments: [EnvironmentID: String]
}
