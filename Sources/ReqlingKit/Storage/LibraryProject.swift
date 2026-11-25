import Foundation

/// A project as the library sees it: where it lives, and its document or why it could not be loaded.
public struct LibraryProject: Identifiable, Hashable, Sendable {
    public let id: ProjectID
    public var url: URL
    public var status: Status
    public var issues: [ProjectLoadIssue]
    /// Saved by a newer Reqling, whose fields this version would drop by rewriting it.
    public var isNewerFormat: Bool
    /// How this person holds a project someone else shared with them; `nil` for one of their own.
    public var sharing: ProjectSharing?

    public enum Status: Hashable, Sendable {
        case loaded(ProjectDocument)
        case unavailable(String)
    }

    public init(
        id: ProjectID,
        url: URL,
        status: Status,
        issues: [ProjectLoadIssue] = [],
        isNewerFormat: Bool = false,
        sharing: ProjectSharing? = nil
    ) {
        self.id = id
        self.url = url
        self.status = status
        self.issues = issues
        self.isNewerFormat = isNewerFormat
        self.sharing = sharing
    }

    public var isReadOnly: Bool {
        readOnlyReason != nil
    }

    /// Why the project can't be edited, if it can't.
    public var readOnlyReason: ReadOnlyReason? {
        if isNewerFormat {
            return .newerFormat
        }
        return sharing?.permission == .readOnly ? .sharedReadOnly : nil
    }

    public var document: ProjectDocument? {
        if case .loaded(let document) = status {
            return document
        }
        return nil
    }

    public var name: String {
        document?.name ?? url.deletingPathExtension().lastPathComponent
    }
}

/// Why a project can't be edited.
public enum ReadOnlyReason: Hashable, Sendable {
    /// Saved by a newer Reqling (`LibraryProject.isNewerFormat`).
    case newerFormat
    /// Shared with this person to view only.
    case sharedReadOnly
}

/// How this person holds a project someone else owns and shared with them. It lives in the library's list, so the
/// project stays shared, and read-only when it is, while sync is off.
public struct ProjectSharing: Codable, Hashable, Sendable {
    /// The owner's CloudKit user record name, which names their zone in this person's shared database.
    public var owner: String
    public var permission: Permission
    /// Whether this person may invite others, as an administrator.
    public var canInvite: Bool

    public enum Permission: String, Codable, Hashable, Sendable {
        case readOnly
        case readWrite
    }

    public init(owner: String, permission: Permission, canInvite: Bool) {
        self.owner = owner
        self.permission = permission
        self.canInvite = canInvite
    }
}

/// How an edit changes a project's or Global's secret variable values, keyed by `SecretKey`.
struct SecretChanges {
    /// New and changed values, stored before the folder is saved.
    let stored: [String: String]
    /// Keys the edit removed, deleted only after the folder no longer references them.
    let deleted: Set<String>

    init(old: [String: String], new: [String: String]) {
        stored = new.filter { old[$0.key] != $0.value }
        deleted = Set(old.keys).subtracting(new.keys)
    }
}
