import Foundation

/// Descriptor sets protoc already produced, keyed by protoc's identity and arguments, each with a manifest of the
/// files it was compiled from.
///
/// The manifest names every file the descriptor set contains, which with `--include_imports` is every file protoc
/// read, resolved through the roots to the copy protoc loaded. An entry is valid only while each of those still
/// resolves to the same path with the same content, so edits reached through hidden folders or folder symlinks
/// (`third_party -> ../vendor`) invalidate it as surely as edits to an entry file.
///
/// Holds at most `capacity` entries, evicting the least recently used. Each is one binary property list, written
/// under a `.pending-` name and renamed into place, so a reader never sees a partial entry.
struct ProtocCompileCache: Sendable {
    struct Source: Codable, Hashable, Sendable {
        /// The name protoc gave the file, relative to its root (`acme/v1/api.proto`).
        let name: String
        /// Where `name` resolved through the roots, in `-I` order.
        let path: String
        let sha256: String
    }

    struct Entry: Codable, Sendable {
        let sources: [Source]
        let descriptorSet: Data
    }

    private static let entryExtension = "entry"
    private static let pendingPrefix = ".pending-"
    /// Long enough that no running compile still owns a pending file; protoc's own timeout is a minute.
    private static let abandonedAge: TimeInterval = 15 * 60

    let directory: URL
    let capacity: Int

    init(directory: URL, capacity: Int = 32) {
        self.directory = directory
        self.capacity = capacity
    }

    /// The stored entry, marked as just used. The caller still validates its sources.
    func entry(for key: String) -> Entry? {
        let url = entryURL(key)
        guard let data = try? Data(contentsOf: url), let entry = try? PropertyListDecoder().decode(Entry.self, from: data) else {
            return nil
        }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        return entry
    }

    /// A fresh path inside the cache for protoc's output.
    func temporaryURL() throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("\(Self.pendingPrefix)\(UUID().uuidString).binpb")
    }

    /// Replaces any entry for `key`; a failed write leaves the cache as it was, costing only a later protoc run.
    func store(_ entry: Entry, for key: String) {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        guard let data = try? encoder.encode(entry), let pending = try? temporaryURL() else {
            return
        }
        // `rename` replaces an existing entry atomically, which `FileManager.moveItem` refuses to do.
        if (try? data.write(to: pending)) == nil || rename(pending.path, entryURL(key).path) != 0 {
            try? FileManager.default.removeItem(at: pending)
        }
        prune()
    }

    private func entryURL(_ key: String) -> URL {
        directory.appendingPathComponent("\(key).\(Self.entryExtension)")
    }

    /// Evicts beyond `capacity`, and removes pending files a crashed or killed compile left behind.
    private func prune() {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys)) else {
            return
        }
        let dated = files.map { ($0, (try? $0.resourceValues(forKeys: keys).contentModificationDate) ?? .distantPast) }
        let abandonedBefore = Date().addingTimeInterval(-Self.abandonedAge)
        for (url, modified) in dated where url.lastPathComponent.hasPrefix(Self.pendingPrefix) && modified < abandonedBefore {
            try? FileManager.default.removeItem(at: url)
        }
        let entries = dated
            .filter { $0.0.pathExtension == Self.entryExtension && !$0.0.lastPathComponent.hasPrefix(".") }
            .sorted { $0.1 > $1.1 }
        for (url, _) in entries.dropFirst(capacity) {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
