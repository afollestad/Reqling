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
        reconcileLocalPaths(in: id)
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

    /// Moves a folder or request to the Trash with its files, as `ProjectDocument.removeNode(_:)` does, and drops the
    /// history of every request inside it. Finder's Put Back restores the files but not the runs.
    public func deleteNode(_ id: RequestNodeID, in project: ProjectID) throws {
        let requests = library.document(project)?.node(id)?.requestIDs ?? []
        try library.mutate(project) { _ = try $0.removeNode(id) }
        for request in requests {
            runner.forget(request, in: project)
        }
    }

    /// Drops the stored paths `project` no longer references; see `WorkspaceStateStore.reconcileLocalPaths(in:keeping:)`
    /// for why only a load does this.
    public func reconcileLocalPaths(in project: ProjectID) {
        if let document = library.document(project) {
            workspace.reconcileLocalPaths(in: project, keeping: document.localPathIDs)
            workspace.reconcileChosenOutsidePaths(in: project, keeping: document.relativePaths)
        }
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

    /// The resolver for `project`'s file references: its folder, and this Mac's paths for its local ones.
    public func pathResolver(for project: ProjectID) -> ProjectPathResolver? {
        library.project(project).map { ProjectPathResolver(projectRoot: $0.url, workspace: workspace, project: project) }
    }
}

extension RequestNode {
    /// A deep copy with fresh IDs throughout, so the copy and the original never share files or selection.
    public func copy(named name: String? = nil) -> RequestNode {
        switch self {
        case .request(let request):
            return .request(RequestItem(
                name: name ?? request.name,
                kind: request.kind,
                scripts: request.scripts,
                runsInheritedScripts: request.runsInheritedScripts
            ))
        case .folder(let folder):
            return .folder(RequestFolder(
                name: name ?? folder.name,
                auth: folder.auth,
                scripts: folder.scripts,
                runsInheritedScripts: folder.runsInheritedScripts,
                children: folder.children.map { $0.copy() }
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
