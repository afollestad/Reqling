import CryptoKit
import Foundation

/// Every `.proto` file under a set of import roots, as the root-relative paths protoc resolves imports by.
struct ProtoSourceSet {
    struct File: Hashable {
        /// Index into the roots, in `-I` order.
        let root: Int
        let relativePath: String
        /// The root as given plus `relativePath`, the form `resolve` produces, so the two always compare equal.
        let url: URL
    }

    let roots: [URL]
    /// Sorted by root, then path, so the cache key and the argument list never depend on enumeration order.
    let files: [File]

    /// Walks each root, skipping hidden files and packages.
    ///
    /// The walk runs on each root with symlinks resolved: the enumerator does not descend into a root that is itself
    /// a link (`protos -> api/proto`), and under a linked parent (`~/Dropbox`) it hands back resolved paths that no
    /// longer share the given root's prefix. A root nested inside another owns its files: the outer root's walk stops
    /// at it. Otherwise protoc would load `vendor/x.proto` and `x.proto` as two files and report every type in them
    /// as defined twice.
    static func gather(roots: [URL]) -> ProtoSourceSet {
        let standardized = roots.map(\.standardizedFileURL)
        let resolved = standardized.map { $0.resolvingSymlinksInPath() }
        let rootPaths = Set(resolved.map(\.path))
        var files: [File] = []
        for (index, root) in standardized.enumerated() {
            let walkRoot = resolved[index]
            guard let enumerator = FileManager.default.enumerator(
                at: walkRoot,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else {
                continue
            }
            var rootFiles: [File] = []
            for case let url as URL in enumerator {
                let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                if isDirectory {
                    // Resolved the same way as `rootPaths`, which may spell `/private/var` either way.
                    if rootPaths.contains(url.resolvingSymlinksInPath().path) {
                        enumerator.skipDescendants()
                    }
                    continue
                }
                guard url.pathExtension == "proto", let relative = relativePath(of: url, in: walkRoot) else {
                    continue
                }
                rootFiles.append(File(root: index, relativePath: relative, url: root.appendingPathComponent(relative).standardizedFileURL))
            }
            files += rootFiles.sorted { $0.relativePath < $1.relativePath }
        }
        return ProtoSourceSet(roots: standardized, files: files)
    }

    /// Each relative path once, from the first root that has it, matching which copy protoc loads.
    var entryPaths: [String] {
        var seen = Set<String>()
        return files.map(\.relativePath).filter { seen.insert($0).inserted }
    }

    /// Each gathered file's SHA-256, by path, taken before protoc runs so an edit made while it runs can be caught.
    func digests() -> [String: String] {
        var digests: [String: String] = [:]
        for file in files {
            digests[file.url.path] = Self.sha256(of: file.url)
        }
        return digests
    }

    /// The first directory in `searchPath` holding `name`, the copy protoc loads.
    static func resolve(_ name: String, in searchPath: [URL]) -> URL? {
        searchPath
            .map { $0.appendingPathComponent(name).standardizedFileURL }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Lowercase hex SHA-256 of the file's content, read through any symlink; `nil` when it cannot be read.
    static func sha256(of url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else {
            return nil
        }
        return hex(SHA256.hash(data: data))
    }

    static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    /// `url`'s path below the resolved `root`, or `nil` when it lies outside.
    ///
    /// The enumerator spells paths with `root`'s prefix, so the components compare as given; standardizing them
    /// would strip a leading `/private` that `root` may keep. Only a mismatch pays for resolving the parent.
    private static func relativePath(of url: URL, in root: URL) -> String? {
        let rootComponents = root.pathComponents
        var components = url.pathComponents
        if !components.starts(with: rootComponents) {
            components = url.deletingLastPathComponent().resolvingSymlinksInPath().pathComponents + [url.lastPathComponent]
        }
        guard components.count > rootComponents.count, components.starts(with: rootComponents) else {
            return nil
        }
        return components.dropFirst(rootComponents.count).joined(separator: "/")
    }
}
