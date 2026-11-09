import Foundation

/// Adding, removing, and deleting projects and items with everything that has to happen alongside the library change:
/// runs cancelled and their history dropped, this Mac's state for the project forgotten, and stale local paths pruned.
/// The window and the MCP server both go through it, so neither leaves the other's bookkeeping behind.
@MainActor
public struct ProjectLifecycle {
    let library: ProjectLibrary
    let runner: RequestRunner
    let workspace: WorkspaceStateStore
    let protoWorkspaces: ProtoWorkspaceStore

    public init(library: ProjectLibrary, runner: RequestRunner, workspace: WorkspaceStateStore, protoWorkspaces: ProtoWorkspaceStore) {
        self.library = library
        self.runner = runner
        self.workspace = workspace
        self.protoWorkspaces = protoWorkspaces
    }

    /// Creates a project, trusting its scripts: whoever creates it writes them.
    @discardableResult
    public func createProject(named name: String, in directory: URL? = nil) throws -> ProjectID {
        let id = try library.createProject(named: name, in: directory)
        workspace.updateProject(id) { $0.scriptTrust = .trusted }
        return id
    }

    @discardableResult
    public func addProjectFolder(_ url: URL) throws -> ProjectID {
        let id = try library.addProjectFolder(url)
        reconcileFileChoices(in: id)
        return id
    }

    /// Forgets the project but leaves its folder, secrets, and chosen local paths, so adding the folder back restores it.
    public func removeProject(_ id: ProjectID) {
        library.removeProject(id)
        runner.forget(id)
        workspace.forgetProject(id)
    }

    /// Moves the folder to the Trash and forgets everything this Mac kept for the project.
    public func deleteProject(_ id: ProjectID) throws {
        try library.deleteProject(id)
        runner.forget(id)
        workspace.forgetProject(id, keepingLocalPaths: false)
    }

    /// Deletes a project another Mac deleted, recoverably: the folder goes to the Trash, and its secrets, current values,
    /// and local paths stay, so Put Back and Add Project Folder restore all of it. Its runs and history go.
    func deleteSyncedProject(_ id: ProjectID) throws {
        try library.deleteSyncedProject(id)
        runner.forget(id)
        workspace.forgetProject(id)
    }

    /// Moves a folder or request to the Trash with its files, as `ProjectDocument.removeNode(_:)` does, and drops the
    /// history of every request inside it. Finder's Put Back restores the files but not the runs.
    public func deleteNode(_ id: RequestNodeID, in project: ProjectID) throws {
        let requests = library.document(project)?.node(id)?.requestIDs ?? []
        try library.mutate(project) { _ = try $0.removeNode(id) }
        for request in requests {
            runner.forget(request, in: project)
        }
    }

    /// Drops the files chosen on this Mac that `project` no longer references, and settles where any chosen before
    /// slots were recorded belong; see `WorkspaceStateStore.reconcileChoices(in:holding:)` for why only a load does this.
    public func reconcileFileChoices(in project: ProjectID) {
        if let document = library.document(project) {
            workspace.reconcileChoices(in: project, holding: document.placedReferences)
            markIdentityFiles(of: document)
        }
    }

    /// Readies `project` for a change another Mac made to it: settles this Mac's file choices against `previous`, its
    /// copy here, so none can be taken from where the change puts it (`WorkspaceStateStore.slotUnslottedChoices`), and
    /// marks its client identity files. With no copy here, the change writes the folder, and choices made before slots
    /// were recorded are forgotten instead.
    func prepareForOutsideChange(to project: ProjectID, from previous: ProjectDocument?) {
        guard let previous else {
            workspace.forgetUnslottedChoices(in: project)
            return
        }
        workspace.slotUnslottedChoices(in: project, holding: previous.placedReferences)
        markIdentityFiles(of: previous)
    }

    /// Copies a folder or request in place, right after it, with `name`, and returns the copy. Each file chosen on this
    /// Mac for the original is chosen for the copy too, the person's own doing; one that wasn't chosen for its place in
    /// the original, as another Mac may have moved it there, stays missing in the copy.
    @discardableResult
    public func duplicateNode(_ id: RequestNodeID, in project: ProjectID, named name: String) throws -> RequestNode {
        guard let document = library.document(project), let original = document.node(id) else {
            throw ProjectTreeError.notFound
        }
        var originals: [RequestNodeID: RequestNodeID] = [:]
        let copy = original.copy(named: name, originals: &originals)
        let parent = document.parentID(of: id)
        let index = (document.children(of: parent) ?? []).firstIndex { $0.id == id }.map { $0 + 1 }
        try library.mutate(project) { try $0.insert(copy, into: parent, at: index) }
        if let resolver = pathResolver(for: project) {
            for placed in copy.placedReferences {
                let original = placed.slot.request.flatMap { originals[$0] }.map(placed.slot.moved(to:)) ?? placed.slot
                if resolver.isChosen(placed.reference, for: original) {
                    workspace.choose(placed.reference, for: placed.slot, in: project)
                }
            }
        }
        return copy
    }

    /// Gives every loaded project with proto definitions a workspace on its current configuration and local paths,
    /// and drops the rest. Cheap enough for every library change: a workspace recompiles only when its configuration
    /// resolves to different paths. Runs after each change, from the window's observer and from MCP tools that need
    /// a project's schema at once.
    ///
    /// A project that is listed but did not load (moved, mid-checkout) keeps the workspace it has, so its schema
    /// survives until the project loads again; one that left the library or cleared its protos loses it.
    public func syncProtoWorkspaces() {
        var keep = Set<ProjectID>()
        for project in library.projects {
            guard let document = project.document else {
                if protoWorkspaces.workspace(for: project.id) != nil {
                    keep.insert(project.id)
                }
                continue
            }
            guard !document.grpc.isEmpty, let resolver = pathResolver(for: project.id) else {
                continue
            }
            protoWorkspaces.workspace(for: project.id, configuration: document.grpc, resolver: resolver)
            keep.insert(project.id)
        }
        protoWorkspaces.retain(only: keep)
    }

    /// Marks the files `document`'s client certificates read as readable only for TLS, so nothing else can send them.
    /// Called on load, when certificates are chosen (window and MCP), and before sync applies another Mac's change.
    public func markIdentityFiles(of document: ProjectDocument) {
        guard let resolver = pathResolver(for: document.id) else {
            return
        }
        workspace.markIdentityFiles(resolver.resolvedPaths(of: document.identityReferences), in: document.id)
    }

    /// The resolver for `project`'s file references: its folder, and this Mac's paths for its local ones.
    public func pathResolver(for project: ProjectID) -> ProjectPathResolver? {
        library.project(project).map { ProjectPathResolver(projectRoot: $0.url, workspace: workspace, project: project) }
    }
}

extension RequestNode {
    /// A deep copy with fresh IDs throughout, so the copy and the original never share files or selection.
    public func copy(named name: String? = nil) -> RequestNode {
        var originals: [RequestNodeID: RequestNodeID] = [:]
        return copy(named: name, originals: &originals)
    }

    /// `copy(named:)`, noting each copied request's original ID under its new one in `originals`, so what the original
    /// keeps by its ID (a file's slot, `ProjectPathSlot.moved(to:)`) can be found for the copy.
    public func copy(named name: String? = nil, originals: inout [RequestNodeID: RequestNodeID]) -> RequestNode {
        switch self {
        case .request(let request):
            let copy = RequestItem(
                name: name ?? request.name,
                kind: request.kind,
                scripts: request.scripts,
                runsInheritedScripts: request.runsInheritedScripts
            )
            originals[copy.id] = request.id
            return .request(copy)
        case .folder(let folder):
            var children: [RequestNode] = []
            for child in folder.children {
                children.append(child.copy(originals: &originals))
            }
            return .folder(RequestFolder(
                name: name ?? folder.name,
                auth: folder.auth,
                scripts: folder.scripts,
                runsInheritedScripts: folder.runsInheritedScripts,
                children: children
            ))
        }
    }
}

extension WorkspaceStateStore {
    /// The environment a run uses when none is named: the one chosen in the window, or Default when that is gone.
    public func activeEnvironment(in document: ProjectDocument) -> RequestEnvironment {
        projectState(document.id).activeEnvironmentID.flatMap { document.environment($0) } ?? document.defaultEnvironment
    }
}
