import Foundation
import Observation

/// What this Mac remembers about the workspace that does not belong in project files: the active environment,
/// sidebar expansion, the selection, whether run history shows, absolute paths behind `ProjectPathReference.local`, and Keychain identity
/// references. Keeping these out of the project means switching environments never shows up in `git status`.
public struct WorkspaceState: Codable, Equatable, Sendable {
    public var projects: [String: ProjectWorkspaceState] = [:]
    /// Local paths recorded before they were kept per project. `WorkspaceStateStore.reconcileLocalPaths(in:keeping:)`
    /// moves each into the project that references it as that project loads.
    public var unclaimedLocalPaths: [String: String] = [:]
    public var keychainIdentities: [String: Data] = [:]
    public var selection: WorkspaceSelection?
    /// Whether the window shows the inspector beside the selected request's editor. Named for the run history, which
    /// was its only panel; `inspectorPanel` says which shows.
    public var showsRunHistory = false
    /// The inspector panel last chosen. The GraphQL schema shows only beside a GraphQL request; elsewhere the run
    /// history does, and this choice waits for the next GraphQL request.
    public var inspectorPanel: InspectorPanel = .history

    public init() {}

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        projects = try container.decodeIfPresent([String: ProjectWorkspaceState].self, forKey: .projects) ?? [:]
        unclaimedLocalPaths = try container.decodeIfPresent([String: String].self, forKey: .unclaimedLocalPaths) ?? [:]
        keychainIdentities = try container.decodeIfPresent([String: Data].self, forKey: .keychainIdentities) ?? [:]
        selection = try container.decodeIfPresent(WorkspaceSelection.self, forKey: .selection)
        showsRunHistory = try container.decodeIfPresent(Bool.self, forKey: .showsRunHistory) ?? false
        inspectorPanel = (try? container.decodeIfPresent(InspectorPanel.self, forKey: .inspectorPanel)) ?? .history
    }

    private enum CodingKeys: String, CodingKey {
        case projects
        case unclaimedLocalPaths = "localPaths"
        case keychainIdentities
        case selection
        case showsRunHistory
        case inspectorPanel
    }
}

/// What the inspector beside a request shows.
public enum InspectorPanel: String, Codable, Hashable, Sendable, CaseIterable {
    case history
    case graphQLSchema
}

public struct ProjectWorkspaceState: Codable, Equatable, Sendable {
    public var activeEnvironmentID: EnvironmentID?
    public var expandedFolderIDs: Set<RequestNodeID> = []
    public var isCollapsed = false
    /// The absolute paths behind this project's `ProjectPathReference.local` references, by `LocalPathID`. Scoped to
    /// the project so forgetting it forgets them, and so pruning one project's paths never sees another's.
    public var localPaths: [String: String] = [:]

    public init() {}

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        activeEnvironmentID = try container.decodeIfPresent(EnvironmentID.self, forKey: .activeEnvironmentID)
        expandedFolderIDs = try container.decodeIfPresent(Set<RequestNodeID>.self, forKey: .expandedFolderIDs) ?? []
        isCollapsed = try container.decodeIfPresent(Bool.self, forKey: .isCollapsed) ?? false
        localPaths = try container.decodeIfPresent([String: String].self, forKey: .localPaths) ?? [:]
    }

    private enum CodingKeys: String, CodingKey {
        case activeEnvironmentID
        case expandedFolderIDs
        case isCollapsed
        case localPaths
    }
}

public struct WorkspaceSelection: Codable, Equatable, Hashable, Sendable {
    public var projectID: ProjectID
    public var nodeID: RequestNodeID?

    public init(projectID: ProjectID, nodeID: RequestNodeID? = nil) {
        self.projectID = projectID
        self.nodeID = nodeID
    }
}

/// Persists `WorkspaceState` as one JSON file in Application Support, rewritten on every change.
@MainActor
@Observable
public final class WorkspaceStateStore {
    public private(set) var state: WorkspaceState
    @ObservationIgnored private let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
        state = WorkspaceState()
        if let data = try? Data(contentsOf: fileURL) {
            if let decoded = try? ProjectJSON.decode(WorkspaceState.self, from: data) {
                state = decoded
            } else {
                // The next update rewrites the file; keep the local paths and identities it held for repair.
                UndecodableFileBackup.preserve(fileURL)
            }
        }
    }

    public func update(_ transform: (inout WorkspaceState) -> Void) {
        var copy = state
        transform(&copy)
        guard copy != state else {
            return
        }
        state = copy
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try ProjectJSON.encode(copy).write(to: fileURL, options: .atomic)
        } catch {
            // Workspace state is a convenience; losing a write costs a remembered selection, never project data.
        }
    }

    public func projectState(_ id: ProjectID) -> ProjectWorkspaceState {
        state.projects[id.description] ?? ProjectWorkspaceState()
    }

    public func updateProject(_ id: ProjectID, _ transform: (inout ProjectWorkspaceState) -> Void) {
        update { state in
            var projectState = state.projects[id.description] ?? ProjectWorkspaceState()
            transform(&projectState)
            state.projects[id.description] = projectState
        }
    }

    /// Drops what this Mac remembers about a project. Removing it from Reqling keeps its local paths, so adding the
    /// folder back still finds the files chosen for it; deleting it passes `keepingLocalPaths: false`.
    public func forgetProject(_ id: ProjectID, keepingLocalPaths: Bool = true) {
        update { state in
            var kept = ProjectWorkspaceState()
            if keepingLocalPaths {
                kept.localPaths = state.projects[id.description]?.localPaths ?? [:]
            }
            state.projects[id.description] = kept.localPaths.isEmpty ? nil : kept
            if state.selection?.projectID == id {
                state.selection = nil
            }
        }
    }

    // MARK: - Local paths

    public func localPath(_ id: LocalPathID, in project: ProjectID) -> String? {
        projectState(project).localPaths[id.description]
    }

    /// The absolute paths behind `project`'s local references, for its `ProjectPathResolver`.
    public func localPaths(in project: ProjectID) -> [LocalPathID: String] {
        Dictionary(uniqueKeysWithValues: projectState(project).localPaths.compactMap { key, value in
            LocalPathID(string: key).map { ($0, value) }
        })
    }

    /// Records an absolute path for a new this-Mac-only reference in `project` and returns it.
    public func addLocalPath(_ path: String, in project: ProjectID) -> ProjectPathReference {
        let id = LocalPathID()
        updateProject(project) { $0.localPaths[id.description] = path }
        return .local(id)
    }

    /// Keeps exactly the paths `project` references (`ProjectDocument.localPathIDs`): claims any recorded before paths
    /// were kept per project, and deletes the rest, whose references are gone.
    ///
    /// Call it when a project loads (launch, or adding its folder), never after an edit: undo can restore a reference
    /// removed earlier in the session, and its path must still be here when it does.
    public func reconcileLocalPaths(in project: ProjectID, keeping referenced: Set<LocalPathID>) {
        let keys = Set(referenced.map(\.description))
        update { state in
            var projectState = state.projects[project.description] ?? ProjectWorkspaceState()
            for key in keys where projectState.localPaths[key] == nil {
                if let path = state.unclaimedLocalPaths.removeValue(forKey: key) {
                    projectState.localPaths[key] = path
                }
            }
            projectState.localPaths = projectState.localPaths.filter { keys.contains($0.key) }
            if projectState != (state.projects[project.description] ?? ProjectWorkspaceState()) {
                state.projects[project.description] = projectState
            }
        }
    }

    public func keychainIdentity(for entry: CertificateEntryID) -> Data? {
        state.keychainIdentities[entry.description]
    }

    public func setKeychainIdentity(_ reference: Data?, for entry: CertificateEntryID) {
        update { $0.keychainIdentities[entry.description] = reference }
    }
}
