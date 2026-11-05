import CryptoKit
import Foundation

/// Introspected schemas kept on this Mac, per project and endpoint, so completion works as soon as a request opens,
/// after a relaunch and offline too. Only what introspection returned is kept, with the masked URL it came from:
/// never headers, credentials, or bodies.
///
/// Each entry is one binary property list holding LZFSE-compressed JSON, written under a `.pending-` name and
/// renamed into place, so a reader never sees half of one. Writes and removals run in order on one queue, so removing
/// a project's schemas cannot be undone by a write that was still queued. A project keeps at most
/// `capacityPerProject` entries, dropping the least recently read.
public struct GraphQLSchemaStore: Sendable {
    struct Entry: Codable, Sendable {
        static let currentFormatVersion = 1

        var formatVersion = Self.currentFormatVersion
        let fetchedAt: Date
        let shownURL: String
        let capabilities: GraphQLIntrospection.Capabilities?
        /// The response's `data`, as JSON.
        let introspection: Data
        let issues: [String]
    }

    private static let entryExtension = "schema"
    private static let pendingPrefix = ".pending-"

    public let directory: URL
    let capacityPerProject: Int
    private let queue = DispatchQueue(label: "com.afollestad.reqling.graphql-schema-store")

    public init(directory: URL, capacityPerProject: Int = 8) {
        self.directory = directory
        self.capacityPerProject = capacityPerProject
    }

    /// The hashed file name for an endpoint key, so the key (which may hold a URL) never appears on disk.
    static func fileName(for key: String) -> String {
        SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// The stored entry, marked as just used; nil when there is none or it cannot be read. Blocking: call it off the
    /// main actor.
    func entry(for key: String, in project: ProjectID) -> Entry? {
        let url = entryURL(key, in: project)
        guard let data = try? Data(contentsOf: url),
              var entry = try? PropertyListDecoder().decode(Entry.self, from: data),
              entry.formatVersion == Entry.currentFormatVersion,
              let introspection = try? (entry.introspection as NSData).decompressed(using: .lzfse) as Data else {
            return nil
        }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        entry = Entry(
            fetchedAt: entry.fetchedAt,
            shownURL: entry.shownURL,
            capabilities: entry.capabilities,
            introspection: introspection,
            issues: entry.issues
        )
        return entry
    }

    /// Queues a write replacing any entry for `key`; a failed write only costs a later fetch.
    func store(_ entry: Entry, for key: String, in project: ProjectID) {
        let projectDirectory = projectDirectory(project)
        let target = entryURL(key, in: project)
        let capacity = capacityPerProject
        queue.async {
            guard let compressed = try? (entry.introspection as NSData).compressed(using: .lzfse) as Data else {
                return
            }
            let stored = Entry(
                fetchedAt: entry.fetchedAt,
                shownURL: entry.shownURL,
                capabilities: entry.capabilities,
                introspection: compressed,
                issues: entry.issues
            )
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            guard let data = try? encoder.encode(stored),
                  (try? FileManager.default.createDirectory(at: projectDirectory, withIntermediateDirectories: true)) != nil else {
                return
            }
            let pending = projectDirectory.appendingPathComponent("\(Self.pendingPrefix)\(UUID().uuidString)")
            // `rename` replaces an existing entry atomically, which `FileManager.moveItem` refuses to do.
            if (try? data.write(to: pending)) == nil || rename(pending.path, target.path) != 0 {
                try? FileManager.default.removeItem(at: pending)
            }
            Self.prune(projectDirectory, capacity: capacity)
        }
    }

    /// Queues removing every entry of `project`, after any write already queued.
    func removeAll(in project: ProjectID) {
        let projectDirectory = projectDirectory(project)
        queue.async {
            try? FileManager.default.removeItem(at: projectDirectory)
        }
    }

    /// Waits for every queued write and removal, for tests and before quitting.
    public func flush() {
        queue.sync {}
    }

    private func projectDirectory(_ project: ProjectID) -> URL {
        directory.appendingPathComponent(project.description, isDirectory: true)
    }

    private func entryURL(_ key: String, in project: ProjectID) -> URL {
        projectDirectory(project).appendingPathComponent("\(Self.fileName(for: key)).\(Self.entryExtension)")
    }

    /// Drops entries beyond `capacity`, oldest read first, and any pending file a crashed write left behind.
    private static func prune(_ directory: URL, capacity: Int) {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys)) else {
            return
        }
        for file in files where file.lastPathComponent.hasPrefix(pendingPrefix) {
            try? FileManager.default.removeItem(at: file)
        }
        let entries = files
            .filter { $0.pathExtension == entryExtension }
            .map { ($0, (try? $0.resourceValues(forKeys: keys).contentModificationDate) ?? .distantPast) }
            .sorted { $0.1 > $1.1 }
        for (url, _) in entries.dropFirst(capacity) {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
