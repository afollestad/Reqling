import Foundation
import Observation

/// What this Mac remembers about the workspace that does not belong in project files: the active environment,
/// sidebar expansion, the selection, absolute paths behind `ProjectPathReference.local`, and Keychain identity
/// references. Keeping these out of the project means switching environments never shows up in `git status`.
public struct WorkspaceState: Codable, Equatable, Sendable {
    public var projects: [String: ProjectWorkspaceState] = [:]
    public var localPaths: [String: String] = [:]
    public var keychainIdentities: [String: Data] = [:]
    public var selection: WorkspaceSelection?

    public init() {}

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        projects = try container.decodeIfPresent([String: ProjectWorkspaceState].self, forKey: .projects) ?? [:]
        localPaths = try container.decodeIfPresent([String: String].self, forKey: .localPaths) ?? [:]
        keychainIdentities = try container.decodeIfPresent([String: Data].self, forKey: .keychainIdentities) ?? [:]
        selection = try container.decodeIfPresent(WorkspaceSelection.self, forKey: .selection)
    }

    private enum CodingKeys: String, CodingKey {
        case projects
        case localPaths
        case keychainIdentities
        case selection
    }
}

public struct ProjectWorkspaceState: Codable, Equatable, Sendable {
    public var activeEnvironmentID: EnvironmentID?
    public var expandedFolderIDs: Set<RequestNodeID> = []
    public var isCollapsed = false

    public init() {}
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

    public func forgetProject(_ id: ProjectID) {
        update { state in
            state.projects[id.description] = nil
            if state.selection?.projectID == id {
                state.selection = nil
            }
        }
    }

    public func localPath(_ id: LocalPathID) -> String? {
        state.localPaths[id.description]
    }

    /// Records an absolute path for a new this-Mac-only reference and returns it.
    public func addLocalPath(_ path: String) -> ProjectPathReference {
        let id = LocalPathID()
        update { $0.localPaths[id.description] = path }
        return .local(id)
    }

    public func setLocalPath(_ path: String?, for id: LocalPathID) {
        update { $0.localPaths[id.description] = path }
    }

    public func keychainIdentity(for entry: CertificateEntryID) -> Data? {
        state.keychainIdentities[entry.description]
    }

    public func setKeychainIdentity(_ reference: Data?, for entry: CertificateEntryID) {
        update { $0.keychainIdentities[entry.description] = reference }
    }
}
