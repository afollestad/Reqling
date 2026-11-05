import Foundation
import Observation
import ReqlingKit

/// What the sidebar can select.
enum SidebarItem: Hashable {
    case project(ProjectID)
    case node(ProjectID, RequestNodeID)

    var projectID: ProjectID {
        switch self {
        case .project(let id), .node(let id, _): id
        }
    }

    var nodeID: RequestNodeID? {
        if case .node(_, let id) = self {
            return id
        }
        return nil
    }
}

enum AppSheet: Identifiable, Hashable {
    case newProject
    case environments(ProjectID)
    case projectSettings(ProjectID)

    var id: Self {
        self
    }
}

struct RenameTarget: Identifiable, Equatable {
    let projectID: ProjectID
    /// `nil` renames the project itself.
    let nodeID: RequestNodeID?
    var name: String

    var id: String {
        "\(projectID)/\(nodeID?.description ?? "")"
    }
}

struct AppAlert: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let message: String
}

/// A request switching protocol; see `AppModel.changeKind(of:in:to:)`.
struct RequestKindChange: Identifiable, Equatable {
    let projectID: ProjectID
    let requestID: RequestNodeID
    let name: String
    let kind: RequestKind.Name

    var id: RequestNodeID {
        requestID
    }
}

struct FolderAuthDraft: Equatable {
    let projectID: ProjectID
    let folderID: RequestNodeID
    var auth: HTTPAuth
}

/// The root coordinator: selection, the settings destination, sheets and alerts, and every command the menus,
/// sidebar, and toolbar invoke. Project data lives in `ProjectLibrary`; this type only routes intent to it.
@MainActor
@Observable
final class AppModel {
    var selection: SidebarItem? {
        didSet {
            if selection != oldValue {
                selectionDidChange(from: oldValue)
            }
        }
    }
    var isShowingSettings = false
    var settingsPage: SettingsPage = .interface
    /// The selection opening Settings cleared, so closing Settings returns to it. Choosing an item while Settings is up
    /// replaces it. Observed, since `activeProjectID` falls back to it.
    private(set) var selectionBeforeSettings: SidebarItem?
    var sheet: AppSheet?
    var alert: AppAlert?
    /// A project awaiting confirmation before its folder moves to the Trash.
    var projectPendingDeletion: ProjectID?
    /// A protocol switch awaiting confirmation because it would discard part of the request.
    var kindChangePending: RequestKindChange?
    /// Run history awaiting confirmation before it is cleared, which cannot be undone.
    var historyClearPending: HistoryClearScope?
    /// The project or item being renamed, with the name typed so far. Dismissing the dialog clears only `isRenaming`,
    /// never this, so its Rename action reads the typed name whichever order SwiftUI runs the dismissal and action in.
    var renaming: RenameTarget?
    /// Drives the rename dialog; `renaming` holds its data.
    var isRenaming = false
    /// The selected request's editor, HTTP or gRPC.
    private(set) var editor: RequestEditor?
    /// A folder's auth while it is edited, so typing a token is not a disk write per keystroke. It saves after the
    /// autosave pause, or sooner through `flushPendingEdits()`.
    private(set) var folderAuthDraft: FolderAuthDraft?
    @ObservationIgnored private var folderAuthSaveTask: Task<Void, Never>?
    /// `tokenContext(for:)`'s memo, per project.
    @ObservationIgnored private var tokenContexts: [ProjectID: (key: TokenContextKey, value: TemplateTokenContext)] = [:]
    @ObservationIgnored private(set) lazy var sidebar = SidebarViewModel(app: self)

    @ObservationIgnored let library: ProjectLibrary
    @ObservationIgnored let workspace: WorkspaceStateStore
    @ObservationIgnored let runner: RequestRunner
    @ObservationIgnored let settings: SettingsStore
    @ObservationIgnored let appInfo: AppInfo
    @ObservationIgnored let keychain: any KeychainIdentityStore
    @ObservationIgnored let pkcs12Probe: any PKCS12ImportProbe
    @ObservationIgnored let system: any SystemIntegration
    /// One workspace per project with proto definitions, kept in step by `syncProtoWorkspaces()`.
    @ObservationIgnored let protoWorkspaces: ProtoWorkspaceStore
    @ObservationIgnored let protocTooling: ProtocToolingModel
    @ObservationIgnored let lifecycle: ProjectLifecycle
    @ObservationIgnored let mcpServer: MCPServerController
    @ObservationIgnored let updates: AppUpdateManager
    /// Set once the user has agreed to quit for an update, so the update's own quit doesn't ask again.
    @ObservationIgnored var isQuittingForUpdate = false
    @ObservationIgnored private(set) lazy var mcpSettings = MCPSettingsModel(server: mcpServer, settings: settings, system: system)
    /// Injected so editor autosave debounces deterministically in tests.
    @ObservationIgnored let sleep: @Sendable (Duration) async throws -> Void

    init(
        library: ProjectLibrary,
        workspace: WorkspaceStateStore,
        runner: RequestRunner,
        settings: SettingsStore,
        appInfo: AppInfo,
        keychain: any KeychainIdentityStore,
        pkcs12Probe: any PKCS12ImportProbe,
        system: any SystemIntegration,
        protoWorkspaces: ProtoWorkspaceStore,
        protocTooling: ProtocToolingModel,
        mcpServer: MCPServerController,
        updates: AppUpdateManager,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.library = library
        self.workspace = workspace
        self.runner = runner
        self.settings = settings
        self.appInfo = appInfo
        self.keychain = keychain
        self.pkcs12Probe = pkcs12Probe
        self.system = system
        self.protoWorkspaces = protoWorkspaces
        self.protocTooling = protocTooling
        self.mcpServer = mcpServer
        self.updates = updates
        self.sleep = sleep
        lifecycle = ProjectLifecycle(library: library, runner: runner, workspace: workspace, protoWorkspaces: protoWorkspaces)
        for project in library.projects {
            lifecycle.reconcileLocalPaths(in: project.id)
        }
        syncProtoWorkspaces()
        mcpServer.host = self
        if let restored = workspace.state.selection, let project = library.project(restored.projectID) {
            selection = Self.restoredSelection(restored, in: project)
            selectionDidChange(from: nil)
        }
    }

    /// The saved selection, or its project when the node is gone (deleted while Reqling was closed) or the project did
    /// not load, so relaunching never selects something the sidebar cannot show.
    private static func restoredSelection(_ saved: WorkspaceSelection, in project: LibraryProject) -> SidebarItem {
        guard let nodeID = saved.nodeID, project.document?.node(nodeID) != nil else {
            return .project(project.id)
        }
        return .node(project.id, nodeID)
    }

    // MARK: - Selection

    /// The project the toolbar and commands act on.
    var activeProjectID: ProjectID? {
        // Settings clears the selection; the toolbar and commands keep acting on the project it was in.
        selection?.projectID ?? selectionBeforeSettings?.projectID ?? library.projects.first?.id
    }

    func selectedNode() -> RequestNode? {
        guard let selection, let nodeID = selection.nodeID else {
            return nil
        }
        return library.document(selection.projectID)?.node(nodeID)
    }

    private func selectionDidChange(from oldValue: SidebarItem?) {
        flushPendingEdits()
        syncEditor()
        if selection != nil {
            isShowingSettings = false
            selectionBeforeSettings = nil
        }
        workspace.update { state in
            // While Settings is up, save the selection it cleared, so quitting there relaunches into that.
            state.selection = (selection ?? selectionBeforeSettings).map { WorkspaceSelection(projectID: $0.projectID, nodeID: $0.nodeID) }
        }
    }

    /// Re-validates the selection after the library changes underneath it (an external delete, say). Only a project
    /// that left the library clears it: one that is listed but failed to load (moved, mid-checkout) keeps the
    /// selection and the editor's draft, which saves once the project loads again.
    func libraryDidChange() {
        syncProtoWorkspaces()
        if let saved = selectionBeforeSettings {
            // Reconciled like the selection, so `activeProjectID` never names a project that left while Settings is up.
            selectionBeforeSettings = listedSelection(saved)
        }
        guard let selection else {
            return
        }
        let listed = listedSelection(selection)
        guard listed == selection else {
            self.selection = listed
            return
        }
        guard library.document(selection.projectID) != nil else {
            return
        }
        syncEditor()
        editor?.adoptExternalChange()
    }

    /// `item` while the library still lists it, its project once only the item is gone, and nil once the project left.
    /// A project that is listed but did not load keeps the item, so an editor's draft there saves once it loads again.
    private func listedSelection(_ item: SidebarItem) -> SidebarItem? {
        guard let project = library.project(item.projectID) else {
            return nil
        }
        if let nodeID = item.nodeID, let document = project.document, document.node(nodeID) == nil {
            return .project(item.projectID)
        }
        return item
    }

    /// Gives the selection the editor it needs: none, or one for the selected request's kind. The current editor stays
    /// while it still fits; one whose request changed kind underneath (a `git pull` turning HTTP into gRPC) is
    /// replaced, since its draft can no longer save. Says so when replacing an editor drops an edit.
    func syncEditor() {
        let previous = editor
        if case .node(let projectID, let nodeID)? = selection, let request = library.document(projectID)?.request(nodeID) {
            if editor?.identity != selection || editor?.kind != request.kind.name {
                editor = RequestEditor(projectID: projectID, requestID: nodeID, kind: request.kind.name, app: self)
            }
        } else {
            editor = nil
        }
        guard let previous, previous != editor else {
            return
        }
        if previous.hasStrandedChanges {
            alert = AppAlert(
                title: "Unsaved Changes Discarded",
                message: "“\(previous.name)” couldn't be saved because its project isn't available."
            )
        } else if previous.identity == editor?.identity, previous.hasUnsavedChanges {
            alert = AppAlert(
                title: "Unsaved Changes Discarded",
                message: "“\(previous.name)” was changed elsewhere into a different kind of request, so your edits to it couldn't be kept."
            )
        }
    }

    // MARK: - Environments

    func activeEnvironmentID(for project: ProjectID) -> EnvironmentID? {
        library.document(project).map { workspace.activeEnvironment(in: $0).id }
    }

    func setActiveEnvironment(_ environment: EnvironmentID, for project: ProjectID) {
        workspace.updateProject(project) { $0.activeEnvironmentID = environment }
    }

    func scope(for project: ProjectID) -> VariableScope {
        guard let document = library.document(project) else {
            return VariableScope()
        }
        return VariableScope(document: document, activeEnvironmentID: activeEnvironmentID(for: project))
    }

    /// What the editors know about the variables in `project`, rebuilt only when its environments or the active one
    /// change. Every `TemplateField` and `CodeEditor` compares this in `updateNSView`, and a request screen re-renders
    /// once per frame of a resize, so building a fresh scope per read multiplied across every field.
    func tokenContext(for project: ProjectID) -> TemplateTokenContext {
        // Read every observable input before consulting the cache, so observation keeps tracking them.
        let document = library.document(project)
        let key = TokenContextKey(
            defaultEnvironment: document?.defaultEnvironment,
            environments: document?.environments ?? [],
            activeEnvironmentID: activeEnvironmentID(for: project)
        )
        if let cached = tokenContexts[project], cached.key == key {
            return cached.value
        }
        let value = TemplateTokenContext(scope: scope(for: project))
        tokenContexts[project] = (key, value)
        return value
    }

    // MARK: - Settings

    /// Shows Settings in place of the selection, which it clears so nothing in the sidebar reads as shown. Choosing a
    /// page while Settings is already up only switches to it, keeping the selection to return to.
    func showSettings(_ page: SettingsPage? = nil) {
        flushPendingEdits()
        if let page {
            settingsPage = page
        }
        guard !isShowingSettings else {
            return
        }
        selectionBeforeSettings = selection
        isShowingSettings = true
        selection = nil
    }

    /// Returns to the selection Settings cleared, or as much of it as the library still lists. Rechecked here because
    /// `libraryDidChange()` only runs while the window is up.
    func closeSettings() {
        guard isShowingSettings else {
            return
        }
        isShowingSettings = false
        let restored = selectionBeforeSettings.flatMap(listedSelection)
        selectionBeforeSettings = nil
        selection = restored
    }

    // MARK: - Pending edits

    /// Saves what can be saved before quitting, then asks first if quitting would still lose an edit stranded on an
    /// unavailable project; returns whether to quit.
    func confirmTermination() -> Bool {
        if !isFolderAuthStranded {
            flushFolderAuth()
        }
        editor?.flush()
        guard !isQuittingForUpdate, isFolderAuthStranded || editor?.hasStrandedChanges == true else {
            return true
        }
        return system.confirmQuitDiscardingUnsavedChanges()
    }

    /// A folder auth edit whose project is listed but did not load, so it has nowhere to save.
    private var isFolderAuthStranded: Bool {
        guard let draft = folderAuthDraft, let project = library.project(draft.projectID) else {
            return false
        }
        return project.document == nil
    }

    /// Saves every edit still waiting on its autosave pause, before anything that could change what it applies to.
    func flushPendingEdits() {
        flushFolderAuth()
        editor?.flush()
    }

    /// The auth a folder's editor shows: its pending draft, else the saved value.
    func folderAuth(_ folder: RequestFolder, in project: ProjectID) -> HTTPAuth {
        guard let draft = folderAuthDraft, draft.projectID == project, draft.folderID == folder.id else {
            return folder.auth
        }
        return draft.auth
    }

    func setAuth(_ auth: HTTPAuth, forFolder folder: RequestNodeID, in project: ProjectID) {
        if let draft = folderAuthDraft, draft.projectID != project || draft.folderID != folder {
            flushFolderAuth()
        }
        folderAuthDraft = FolderAuthDraft(projectID: project, folderID: folder, auth: auth)
        folderAuthSaveTask?.cancel()
        let sleep = self.sleep
        folderAuthSaveTask = Task { [weak self] in
            try? await sleep(RequestEditorViewModel.autosaveDelay)
            guard !Task.isCancelled else {
                return
            }
            self?.flushFolderAuth()
        }
    }

    /// Saves a pending folder auth edit now. A folder or project removed meanwhile has nothing to save into and drops
    /// it silently; a project that is listed but did not load says the edit was discarded.
    private func flushFolderAuth() {
        folderAuthSaveTask?.cancel()
        folderAuthSaveTask = nil
        guard let draft = folderAuthDraft else {
            return
        }
        folderAuthDraft = nil
        guard let project = library.project(draft.projectID) else {
            return
        }
        guard let document = project.document else {
            alert = AppAlert(title: "Unsaved Changes Discarded", message: "The folder's auth couldn't be saved because its project isn't available.")
            return
        }
        guard let folder = document.folder(draft.folderID), folder.auth != draft.auth else {
            return
        }
        perform("Couldn't Save the Folder") {
            try library.mutate(draft.projectID) { try $0.updateFolder(draft.folderID) { $0.auth = draft.auth } }
        }
    }

    // MARK: - Errors

    /// Runs a library edit, turning failures into an alert.
    @discardableResult
    func perform<Result>(_ title: String, _ body: () throws -> Result) -> Result? {
        do {
            return try body()
        } catch {
            alert = AppAlert(title: title, message: error.localizedDescription)
            return nil
        }
    }
}

/// The in-window Settings pages, alphabetical by title; `allCases` drives both the side list and the compact strip.
enum SettingsPage: String, CaseIterable, Identifiable, Hashable {
    case updates
    case grpc
    case history
    case interface
    case mcp
    case requests

    var id: Self {
        self
    }

    var title: String {
        switch self {
        case .updates: "App Updates"
        case .grpc: "gRPC"
        case .history: "History"
        case .interface: "Interface"
        case .mcp: "MCP"
        case .requests: "Requests"
        }
    }

    var systemImage: String {
        switch self {
        case .updates: "arrow.down.circle"
        case .grpc: "point.3.connected.trianglepath.dotted"
        case .history: "clock.arrow.circlepath"
        case .interface: "paintbrush"
        case .mcp: "sparkles"
        case .requests: "arrow.up.arrow.down"
        }
    }

    var description: String {
        switch self {
        case .updates: "New versions of Reqling, downloaded and verified before they install."
        case .grpc: "The protoc that compiles project protos, and defaults for gRPC calls."
        case .history: "Each request's past runs, kept on this Mac and never in the project."
        case .interface: "How Reqling looks."
        case .mcp: "A local server that lets AI agents on this Mac use your projects and send requests."
        case .requests: "Defaults for every request; a request's own options override them."
        }
    }
}

/// Everything `AppModel.tokenContext(for:)` builds from: the project's environments, Default included (the document
/// stores it apart from the others), and which one is active.
private struct TokenContextKey: Equatable {
    let defaultEnvironment: RequestEnvironment?
    let environments: [RequestEnvironment]
    let activeEnvironmentID: EnvironmentID?
}
