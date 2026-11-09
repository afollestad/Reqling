import Foundation

/// What changed on this Mac, for `ProjectLibrary.changeObserver`.
public enum LibraryChange: Hashable, Sendable {
    /// A project's document changed: an edit, a reload after an outside change, or one created or added.
    case project(ProjectID)
    /// Removed from Reqling on this Mac only, its folder kept.
    case removed(ProjectID)
    /// Deleted: its folder moved to the Trash.
    case deleted(ProjectID)
    case global
    case currentValues
}

/// The library's side of sync: the entry points that apply another Mac's changes live beside `mutate` in
/// `ProjectLibrary.swift`, since only that file may write `projects`; these need only what it publishes.
extension ProjectLibrary {
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
