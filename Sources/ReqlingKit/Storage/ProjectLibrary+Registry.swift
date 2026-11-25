import Foundation

/// The list of projects Reqling knows about, apart from their folders: each one's path, and how it's shared with this
/// person, if it is. Read at launch (`loadRegistry`), and written on every change to the list.
extension ProjectLibrary {
    func saveRegistry() {
        let registry = Registry(projects: projects.map { RegistryEntry(id: $0.id, path: $0.url.path, sharing: $0.sharing) })
        do {
            try FileManager.default.createDirectory(at: configuration.registryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try ProjectJSON.encode(registry).write(to: configuration.registryURL, options: .atomic)
        } catch {
            // The registry only lists folders; every project's data is already safe in its own folder.
        }
    }
}

struct Registry: Codable {
    var projects: [RegistryEntry]
}

struct RegistryEntry: Codable {
    var id: ProjectID
    var path: String
    var sharing: ProjectSharing?
}
