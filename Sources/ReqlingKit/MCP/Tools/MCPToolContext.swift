import Foundation
import MCP

/// What only the window can do, which tools reach through the app's root model. `nil` in tests and before the window
/// exists; tools that need it say so instead of failing silently.
@MainActor
public protocol MCPAppHost: AnyObject {
    /// Saves edits still waiting on their autosave pause, so an agent's change lands on top of the user's instead of
    /// being overwritten when their draft saves.
    func flushPendingEdits()
    /// Selects the project, folder, or request in the sidebar and brings the window forward.
    func reveal(_ project: ProjectID, node: RequestNodeID?)
    var selectedItem: (project: ProjectID, node: RequestNodeID?)? { get }
    func protocStatus() async -> MCPProtocStatus
    /// Installs Reqling's own protoc as Settings' Install button does, so its progress shows in the window too.
    func installProtoc() async throws -> ProtocInstallation
}

/// Which protoc compiles project protos, as Settings ▸ gRPC shows it.
public enum MCPProtocStatus: Sendable, Equatable {
    case found(ProtocInstallation)
    case missing
    /// The Settings path does not lead to a working protoc; nothing else is used in its place.
    case invalidOverride(String)
}

/// The stores and services tools act through: the same instances the window uses, so every change an agent makes
/// shows up live and goes through the same saving, secret, and Trash paths.
@MainActor
public final class MCPToolContext {
    let library: ProjectLibrary
    let workspace: WorkspaceStateStore
    let runner: RequestRunner
    /// The one folder or project run at a time, which the window shares.
    let batches: BatchRunner
    let settings: SettingsStore
    let lifecycle: ProjectLifecycle
    let protoWorkspaces: ProtoWorkspaceStore
    let appInfo: AppInfo
    public weak var host: (any MCPAppHost)?
    /// The updater, for the status and check tools; `nil` where updates aren't wired, as in tests.
    public var updates: AppUpdateManager?
    /// The dispatcher serving these tools, for resources, which read through the matching tools.
    weak var dispatcher: MCPToolDispatcher?

    public init(
        library: ProjectLibrary,
        workspace: WorkspaceStateStore,
        runner: RequestRunner,
        batches: BatchRunner,
        settings: SettingsStore,
        protoWorkspaces: ProtoWorkspaceStore,
        appInfo: AppInfo
    ) {
        self.library = library
        self.workspace = workspace
        self.runner = runner
        self.batches = batches
        self.settings = settings
        self.protoWorkspaces = protoWorkspaces
        self.appInfo = appInfo
        lifecycle = ProjectLifecycle(library: library, runner: runner, workspace: workspace, protoWorkspaces: protoWorkspaces)
    }

    // MARK: - Lookups

    /// The project an argument names, by ID or else by exact name (ignoring case when only one matches).
    func project(_ reference: String) throws -> LibraryProject {
        if let id = ProjectID(string: reference), let project = library.project(id) {
            return project
        }
        let exact = library.projects.filter { $0.name == reference }
        let matches = exact.isEmpty ? library.projects.filter { $0.name.caseInsensitiveCompare(reference) == .orderedSame } : exact
        guard matches.count <= 1 else {
            throw MCPToolError("More than one project is named “\(reference)”; pass its ID from list_projects.")
        }
        guard let project = matches.first else {
            throw MCPToolError("No project “\(reference)”; list_projects shows what is open.")
        }
        return project
    }

    /// The loaded document of the project an argument names.
    func document(_ reference: String) throws -> (project: LibraryProject, document: ProjectDocument) {
        let project = try project(reference)
        guard let document = project.document else {
            throw MCPToolError("“\(project.name)” isn't available: \(project.unavailableReason ?? "it did not load").")
        }
        return (project, document)
    }

    /// The project environment an argument names, by ID or name (ignoring case); `nil` names Default. Global is
    /// refused here, since it always applies and is never chosen, renamed, or deleted; `variableTarget` reaches it.
    func environment(_ reference: String?, in document: ProjectDocument) throws -> RequestEnvironment {
        guard let reference else {
            return document.defaultEnvironment
        }
        if Self.namesGlobal(reference) {
            throw MCPToolError(
                "Global applies to every request, beneath each project's Default, so it can't be chosen, renamed, or deleted. "
                    + "Pass environment `Global` to the variable tools to edit its variables."
            )
        }
        if let id = EnvironmentID(string: reference), let environment = document.environment(id) {
            return environment
        }
        let matches = document.allEnvironments.filter { $0.name.caseInsensitiveCompare(reference) == .orderedSame }
        guard matches.count <= 1 else {
            throw MCPToolError("More than one environment is named “\(reference)”; pass its ID from list_environments.")
        }
        guard let environment = matches.first else {
            throw MCPToolError("“\(document.name)” has no environment “\(reference)”; list_environments shows its environments.")
        }
        return environment
    }

    /// Where a variable tool reads and writes: Global, which needs no project, or one of a project's environments.
    func variableTarget(project projectReference: String?, environment reference: String?) throws -> VariableTarget {
        if let reference, Self.namesGlobal(reference) {
            return .global(library.globalEnvironment)
        }
        guard let projectReference else {
            throw MCPToolError("`project` is required unless `environment` is Global.")
        }
        let (project, document) = try document(projectReference)
        return .project(project.id, try environment(reference, in: document))
    }

    /// Whether an argument names Global, by its ID or its name (ignoring case). The name is reserved: a project
    /// environment that already carries it stays reachable by its ID.
    static func namesGlobal(_ reference: String) -> Bool {
        EnvironmentID(string: reference) == RequestEnvironment.globalID || RequestEnvironment.isGlobalName(reference)
    }

    func request(_ reference: String, in document: ProjectDocument) throws -> RequestItem {
        guard let id = RequestNodeID(string: reference), let request = document.request(id) else {
            throw MCPToolError("“\(document.name)” has no request with ID \(reference); list_requests shows its requests.")
        }
        return request
    }

    func folder(_ reference: String, in document: ProjectDocument) throws -> RequestFolder {
        guard let id = RequestNodeID(string: reference), let folder = document.folder(id) else {
            throw MCPToolError("“\(document.name)” has no folder with ID \(reference); get_project shows its folders.")
        }
        return folder
    }

    // MARK: - Paths

    /// A path argument as a reference: shared ones relative to the project folder, this-Mac ones recorded locally (an
    /// already-recorded path keeps its ID, so repeated updates don't pile up entries).
    func pathReference(_ entry: MCPArguments, in project: LibraryProject, existing: [ProjectPathReference]) throws -> ProjectPathReference {
        let path = try entry.string("path")
        if try entry.bool("local", default: false) {
            let url = try MCPProjectTools.absoluteURL(path, field: "\(entry.path).path")
            let resolver = lifecycle.pathResolver(for: project.id)
            if let match = existing.first(where: { if case .local = $0 { resolver?.url(for: $0)?.path == url.path } else { false } }) {
                return match
            }
            return workspace.addLocalPath(url.path, in: project.id)
        }
        let isAbsolute = path.hasPrefix("/") || path.hasPrefix("~")
        let url = isAbsolute
            ? try MCPProjectTools.absoluteURL(path, field: "\(entry.path).path")
            : project.url.appendingPathComponent(path).standardizedFileURL
        // A relative path is checked too: the resolver would treat one that leads out as missing (`url(for:)`), so
        // saving it would only leave a broken reference.
        guard ProjectPathResolver.sharesLocation(url, with: project.url) else {
            throw MCPToolError("\(path) is outside the project's folder and repository, so others couldn't resolve it; pass "
                + "an absolute path with `local: true` to keep it on this Mac only.")
        }
        return .relative(isAbsolute ? ProjectPathResolver.relativePath(from: project.url, to: url) : path)
    }

    /// A reference as tools report it: its path on this Mac, whether it is shared through the project, and whether the
    /// file is there.
    func describePath(_ reference: ProjectPathReference, in project: ProjectID) -> Value {
        let resolver = lifecycle.pathResolver(for: project)
        let url = resolver?.url(for: reference)
        var description: [String: Value] = ["path": .string(url?.path ?? resolver?.describe(reference) ?? "")]
        switch reference {
        case .relative(let relative):
            description["shared"] = true
            description["relativePath"] = .string(relative)
        case .local:
            description["shared"] = false
        }
        description["exists"] = .bool(url.map { FileManager.default.fileExists(atPath: $0.path) } ?? false)
        return .object(description)
    }

    // MARK: - Editing

    /// Applies `body` through `ProjectLibrary.mutate`, turning storage and tree errors into messages an agent can act on.
    /// The window's pending edits were saved before the call began (`MCPToolDispatcher.init(context:sleep:)`).
    @discardableResult
    func mutate<Result>(_ project: ProjectID, _ body: (inout ProjectDocument) throws -> Result) throws -> Result {
        try describingErrors { try library.mutate(project, body) }
    }

    /// Applies `body` through `ProjectLibrary.mutateGlobalEnvironment`, with the same messages as `mutate`.
    @discardableResult
    func mutateGlobalEnvironment<Result>(_ body: (inout RequestEnvironment) throws -> Result) throws -> Result {
        try describingErrors { try library.mutateGlobalEnvironment(body) }
    }

    /// Runs a change made some other way than `mutate`, such as through `ProjectLifecycle`, with the same messages.
    func describingErrors<Result>(_ change: () throws -> Result) throws -> Result {
        do {
            return try change()
        } catch let error as ProjectTreeError {
            throw MCPToolError(Self.describe(error))
        } catch let error as MCPToolError {
            throw error
        } catch {
            throw MCPToolError(error.localizedDescription)
        }
    }

    private static func describe(_ error: ProjectTreeError) -> String {
        switch error {
        case .notFound: "That item is no longer in the project."
        case .duplicateID: "An item with that ID is already in the project."
        case .wouldCreateCycle: "A folder can't move into itself or one of its own folders."
        }
    }
}

extension LibraryProject {
    var unavailableReason: String? {
        if case .unavailable(let reason) = status {
            return reason
        }
        return nil
    }
}

/// The environment a variable tool acts on.
enum VariableTarget {
    case global(RequestEnvironment)
    case project(ProjectID, RequestEnvironment)

    var environment: RequestEnvironment {
        switch self {
        case .global(let environment), .project(_, let environment): environment
        }
    }

    var currentValueScope: CurrentValueScope {
        switch self {
        case .global: .global
        case .project(let project, let environment): .environment(project, environment.id)
        }
    }
}
