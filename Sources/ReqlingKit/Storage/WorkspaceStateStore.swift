import Foundation
import Observation

/// What this Mac remembers about the workspace that does not belong in project files: the active environment,
/// sidebar expansion, the selection, whether run history shows, absolute paths behind `ProjectPathReference.local`, and Keychain identity
/// references. Keeping these out of the project means switching environments never shows up in `git status`.
public struct WorkspaceState: Codable, Equatable, Sendable {
    public var projects: [String: ProjectWorkspaceState] = [:]
    /// Local paths recorded before they were kept per project. `WorkspaceStateStore.reconcileChoices(in:holding:)`
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
    /// The slots each of `localPaths` was chosen for, by `LocalPathID`: it resolves only there, so an edit from another
    /// Mac or a repository that moves its reference into another field finds it missing (`ProjectPathSlot`). A path
    /// with no entry was recorded before slots were, and takes the slots its reference holds when the project next
    /// loads (`WorkspaceStateStore.reconcileChoices(in:holding:)`).
    public var localPathSlots: [String: Set<ProjectPathSlot>] = [:]
    /// Shared paths outside the project's folder and repository that the person chose on this Mac (Shared Path), the
    /// only such paths `ProjectPathResolver` resolves; one anyone else wrote into the project counts as missing.
    public var chosenOutsidePaths: Set<String> = []
    /// The slots each of `chosenOutsidePaths` was chosen for, by path, as `localPathSlots` records local paths'.
    public var chosenOutsideSlots: [String: Set<ProjectPathSlot>] = [:]
    /// The files ever used for a client certificate or key here, by resolved path: only TLS may read them
    /// (`ProjectPathResolver.identityData(for:in:)`), so an edit from another Mac or a repository that points a request
    /// body at one, by any reference, can't send this Mac's private key. Marks are never dropped; they're few, and a
    /// change that removes a certificate entry in the same breath as reusing its file must still find it marked.
    public var identityFiles: Set<String> = []
    /// Whether this project's scripts may run on this Mac.
    public var scriptTrust: ScriptTrust = .unknown

    public init() {}

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        activeEnvironmentID = try container.decodeIfPresent(EnvironmentID.self, forKey: .activeEnvironmentID)
        expandedFolderIDs = try container.decodeIfPresent(Set<RequestNodeID>.self, forKey: .expandedFolderIDs) ?? []
        isCollapsed = try container.decodeIfPresent(Bool.self, forKey: .isCollapsed) ?? false
        localPaths = try container.decodeIfPresent([String: String].self, forKey: .localPaths) ?? [:]
        localPathSlots = Self.slots(in: container, forKey: .localPathSlots, of: localPaths.keys)
        chosenOutsidePaths = try container.decodeIfPresent(Set<String>.self, forKey: .chosenOutsidePaths) ?? []
        chosenOutsideSlots = Self.slots(in: container, forKey: .chosenOutsideSlots, of: chosenOutsidePaths)
        identityFiles = try container.decodeIfPresent(Set<String>.self, forKey: .identityFiles) ?? []
        scriptTrust = (try? container.decodeIfPresent(ScriptTrust.self, forKey: .scriptTrust)) ?? .unknown
    }

    /// The slots recorded for `choices`. One a newer Reqling wrote, which this version can't name, drops alone rather
    /// than failing the whole file; an entry left empty stays, so its choice doesn't read as made before slots were,
    /// which the next load would settle wherever its reference sits. A map that won't read at all records every choice
    /// as made for no slot, for the same reason.
    private static func slots(
        in container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys,
        of choices: some Sequence<String>
    ) -> [String: Set<ProjectPathSlot>] {
        guard container.contains(key) else {
            return [:]
        }
        guard let keys = try? container.decode([String: [String]].self, forKey: key) else {
            return Dictionary(choices.map { ($0, []) }, uniquingKeysWith: { first, _ in first })
        }
        return keys.mapValues { Set($0.compactMap(ProjectPathSlot.init(key:))) }
    }

    private enum CodingKeys: String, CodingKey {
        case activeEnvironmentID
        case expandedFolderIDs
        case isCollapsed
        case localPaths
        case localPathSlots
        case chosenOutsidePaths
        case chosenOutsideSlots
        case identityFiles
        case scriptTrust
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
            if keepingLocalPaths, let current = state.projects[id.description] {
                kept.localPaths = current.localPaths
                kept.localPathSlots = current.localPathSlots
                kept.chosenOutsidePaths = current.chosenOutsidePaths
                kept.chosenOutsideSlots = current.chosenOutsideSlots
                kept.identityFiles = current.identityFiles
            }
            let keepsNothing = kept.localPaths.isEmpty && kept.chosenOutsidePaths.isEmpty && kept.identityFiles.isEmpty
            state.projects[id.description] = keepsNothing ? nil : kept
            if state.selection?.projectID == id {
                state.selection = nil
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
