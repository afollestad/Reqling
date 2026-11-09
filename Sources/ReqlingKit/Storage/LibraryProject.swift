import Foundation

/// A project as the library sees it: where it lives, and its document or why it could not be loaded.
public struct LibraryProject: Identifiable, Hashable, Sendable {
    public let id: ProjectID
    public var url: URL
    public var status: Status
    public var issues: [ProjectLoadIssue]
    public var isReadOnly: Bool

    public enum Status: Hashable, Sendable {
        case loaded(ProjectDocument)
        case unavailable(String)
    }

    public init(id: ProjectID, url: URL, status: Status, issues: [ProjectLoadIssue] = [], isReadOnly: Bool = false) {
        self.id = id
        self.url = url
        self.status = status
        self.issues = issues
        self.isReadOnly = isReadOnly
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
