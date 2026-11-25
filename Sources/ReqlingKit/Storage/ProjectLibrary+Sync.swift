import Foundation

/// What changed on this Mac, for `ProjectLibrary.changeObserver`.
public enum LibraryChange: Hashable, Sendable {
    /// A project's document, or its load issues, changed: an edit, a reload after an outside change, or one created or
    /// added.
    case project(ProjectID)
    /// Removed from Reqling on this Mac only, its folder kept.
    case removed(ProjectID)
    /// Deleted: its folder moved to the Trash.
    case deleted(ProjectID)
    case global
    case currentValues
}

/// The library's side of sync, and the folders it names and finds in its projects folder: the entry points that apply
/// another Mac's changes live beside `mutate` in `ProjectLibrary.swift`, since only that file may write `projects`;
/// these need only what it publishes.
extension ProjectLibrary {
    /// `<name>.reqling`, or `<name> 2.reqling` and so on when taken.
    static func availableFolderURL(for name: String, in parent: URL) -> URL {
        let sanitized = name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let base = sanitized.isEmpty || sanitized.hasPrefix(".") ? "Untitled" : sanitized
        var candidate = parent.appendingPathComponent("\(base).reqling", isDirectory: true)
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = parent.appendingPathComponent("\(base) \(suffix).reqling", isDirectory: true)
            suffix += 1
        }
        return candidate
    }

    /// A folder directly in `parent` that no listed project uses and whose `project.json` states `id`.
    func unlistedFolder(with id: ProjectID, in parent: URL) -> URL? {
        let listed = Set(projects.map { $0.url.standardizedFileURL.path })
        let children = (try? FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)) ?? []
        return children.first { folder in
            guard !listed.contains(folder.standardizedFileURL.path),
                  let data = try? Data(contentsOf: folder.appendingPathComponent(ProjectLayout.projectFile)),
                  let file = try? ProjectJSON.decode(ProjectFile.self, from: data) else {
                return false
            }
            return file.id == id
        }
    }
}
