import CryptoKit
import Foundation

/// What to compile: import roots in `-I` order and the entry files, each relative to a root.
public struct ProtocCompileInput: Hashable, Sendable {
    public let roots: [URL]
    /// Empty compiles every `.proto` under the roots.
    public let files: [String]

    public init(roots: [URL], files: [String] = []) {
        self.roots = roots
        self.files = files
    }
}

/// A schema and the gathered files it left out because protoc could misread their names.
public struct ProtocCompilation: Sendable {
    public let registry: DescriptorRegistry
    /// One `.warning` per skipped file; the rest of the schema compiled without them.
    public let warnings: [ProtocDiagnostic]
}

/// A compile that produced no schema. Every cause, from a syntax error to a timeout, arrives as diagnostics, so the
/// UI has one shape to show.
public struct ProtocImportFailure: Error, Hashable, Sendable, LocalizedError {
    public let diagnostics: [ProtocDiagnostic]

    public init(_ diagnostics: [ProtocDiagnostic]) {
        self.diagnostics = diagnostics
    }

    init(message: String) {
        self.init([ProtocDiagnostic(message: message)])
    }

    public var errorDescription: String? {
        diagnostics.map(\.description).joined(separator: "\n")
    }
}

/// Compiles `.proto` files into a `DescriptorRegistry` by running
/// `protoc --include_imports --descriptor_set_out=<temp> --proto_path=<roots…> --proto_path=<well-known types> <files>`.
///
/// This is the one place project-controlled paths become protoc arguments, so it is where `ProtocArguments` vets
/// them: opening a shared project compiles automatically, and protoc would take a crafted entry as an option.
/// Entries go to protoc as root-relative virtual paths, with the working directory set to the cache directory (which
/// holds no `.proto` files): protoc tries an input as a disk path relative to its working directory first, so a
/// stray file there could shadow the root's copy.
public struct ProtocImporter: Sendable {
    public static let defaultTimeout: Duration = .seconds(60)
    /// A file outside the pre-launch digests counts as edited mid-compile when modified this close to protoc's launch,
    /// since file-system timestamps can be coarser than the gap.
    static let modificationTolerance: TimeInterval = 2

    private let cache: ProtocCompileCache
    private let runner: any CommandRunning
    private let timeout: Duration

    /// `cacheDirectory` holds compiled descriptor sets across launches; it is created on first use.
    public init(cacheDirectory: URL, runner: any CommandRunning = ProcessCommandRunner(), timeout: Duration = defaultTimeout) {
        cache = ProtocCompileCache(directory: cacheDirectory)
        self.runner = runner
        self.timeout = timeout
    }

    /// The schema `input` defines, imports included; see `compilation(_:with:reusingCache:)`.
    public func compile(_ input: ProtocCompileInput, with protoc: ProtocInstallation, reusingCache: Bool = true) async throws -> DescriptorRegistry {
        try await compilation(input, with: protoc, reusingCache: reusingCache).registry
    }

    /// The schema `input` defines, imports included, and the gathered files skipped for unsafe names.
    ///
    /// Reuses the cached result while every file it was compiled from is unchanged, unless `reusingCache` is false,
    /// as for an explicit Recompile. Throws `ProtocImportFailure`, including for a named entry or folder protoc could
    /// misread, or `CancellationError` after terminating protoc.
    @concurrent
    public func compilation(
        _ input: ProtocCompileInput,
        with protoc: ProtocInstallation,
        reusingCache: Bool = true
    ) async throws -> ProtocCompilation {
        let searchPath = (input.roots + [protoc.includeDirectory].compactMap { $0 }).map(\.standardizedFileURL)
        var rejected = searchPath.compactMap { directory in
            ProtocArguments.problem(withDirectory: directory).map { ProtocArguments.diagnostic(for: directory.path, $0) }
        }
        let sources = ProtoSourceSet.gather(roots: input.roots)
        let selection = Self.entries(for: input, in: sources)
        rejected += selection.rejected
        guard rejected.isEmpty else {
            throw ProtocImportFailure(rejected)
        }
        guard !selection.entries.isEmpty else {
            throw ProtocImportFailure(selection.skipped + [ProtocDiagnostic(message: "No .proto files under the proto folders.")])
        }
        let arguments = searchPath.map(ProtocArguments.protoPath) + selection.entries
        let key = Self.cacheKey(protoc: protoc, arguments: arguments)
        if reusingCache, let entry = cache.entry(for: key), Self.isCurrent(entry.sources, in: searchPath),
           let registry = try? DescriptorRegistry(descriptorSet: entry.descriptorSet) {
            return ProtocCompilation(registry: registry, warnings: selection.skipped)
        }
        try Task.checkCancellation()
        let registry = try await run(protoc, arguments: arguments, searchPath: searchPath, sources: sources, key: key)
        return ProtocCompilation(registry: registry, warnings: selection.skipped)
    }

    private func run(
        _ protoc: ProtocInstallation,
        arguments: [String],
        searchPath: [URL],
        sources: ProtoSourceSet,
        key: String
    ) async throws -> DescriptorRegistry {
        let output: URL
        do {
            output = try cache.temporaryURL()
        } catch {
            throw ProtocImportFailure(message: "Could not create the proto cache: \(error.localizedDescription)")
        }
        defer {
            // Checked first: XCTest reports the last error thrown, even one `try?` swallowed, in place of the real one.
            if FileManager.default.fileExists(atPath: output.path) {
                try? FileManager.default.removeItem(at: output)
            }
        }
        let digestsBefore = sources.digests()
        let launchedAt = Date()
        let result: CommandResult
        do {
            result = try await runner.run(
                protoc.executable,
                arguments: ["--include_imports", ProtocArguments.descriptorSetOut(output)] + arguments,
                currentDirectory: cache.directory,
                timeout: timeout
            )
        } catch let error as CommandError {
            throw ProtocImportFailure(message: error.localizedDescription)
        }
        guard result.exitCode == 0 else {
            let diagnostics = ProtocDiagnostic.parse(result.standardErrorText, roots: searchPath)
            guard !diagnostics.isEmpty else {
                throw ProtocImportFailure(message: "protoc exited with status \(result.exitCode).")
            }
            throw ProtocImportFailure(diagnostics)
        }
        let data: Data
        let registry: DescriptorRegistry
        do {
            data = try Data(contentsOf: output)
            registry = try DescriptorRegistry(descriptorSet: data)
        } catch {
            throw ProtocImportFailure(message: "protoc wrote an unreadable descriptor set: \(error.localizedDescription)")
        }
        if let manifest = Self.manifest(for: registry, in: searchPath),
           Self.isUnchanged(manifest, since: launchedAt, digestsBefore: digestsBefore) {
            cache.store(ProtocCompileCache.Entry(sources: manifest, descriptorSet: data), for: key)
        }
        return registry
    }

    private struct Selection {
        var entries: [String] = []
        /// Named entries that fail the compile.
        var rejected: [ProtocDiagnostic] = []
        /// Gathered files left out with a warning.
        var skipped: [ProtocDiagnostic] = []
    }

    /// The entries to pass.
    ///
    /// Gathered names are vetted too, since a shared repository controls its file names as much as its project
    /// file; an unsafe one is skipped so the rest still compile. An unsafe or unknown named entry fails the compile
    /// instead, because the user asked for that file. A named entry must be one the walk found, so it cannot reach
    /// outside the roots.
    private static func entries(for input: ProtocCompileInput, in sources: ProtoSourceSet) -> Selection {
        let gathered = sources.entryPaths
        let isNamed = !input.files.isEmpty
        let known = Set(gathered)
        var selection = Selection()
        var seen = Set<String>()
        for path in isNamed ? input.files : gathered where seen.insert(path).inserted {
            if let problem = ProtocArguments.problem(withEntry: path) {
                if isNamed {
                    selection.rejected.append(ProtocArguments.diagnostic(for: path, problem))
                } else {
                    selection.skipped.append(ProtocArguments.diagnostic(for: path, problem, severity: .warning))
                }
            } else if !known.contains(path) {
                let problem = "it is not a .proto file under the proto folders (hidden folders and folder links are not searched)"
                selection.rejected.append(ProtocArguments.diagnostic(for: path, problem))
            } else {
                selection.entries.append(path)
            }
        }
        return selection
    }

    /// SHA-256 over protoc's identity and the arguments; file contents are checked through each entry's manifest.
    private static func cacheKey(protoc: ProtocInstallation, arguments: [String]) -> String {
        var hasher = SHA256()
        for part in [protoc.executable.path, protoc.version] + arguments {
            // Length-prefixed, so no two argument lists concatenate to the same bytes.
            withUnsafeBytes(of: UInt64(part.utf8.count).littleEndian) { hasher.update(bufferPointer: $0) }
            hasher.update(data: Data(part.utf8))
        }
        return ProtoSourceSet.hex(hasher.finalize())
    }

    /// Every file the descriptor set names, resolved through the search path; `nil` when one cannot be read.
    private static func manifest(for registry: DescriptorRegistry, in searchPath: [URL]) -> [ProtocCompileCache.Source]? {
        var sources: [ProtocCompileCache.Source] = []
        for file in registry.files {
            guard let url = ProtoSourceSet.resolve(file.name, in: searchPath), let digest = ProtoSourceSet.sha256(of: url) else {
                return nil
            }
            sources.append(ProtocCompileCache.Source(name: file.name, path: url.path, sha256: digest))
        }
        return sources
    }

    /// Whether each source still resolves to the same file with the same content; a file added to an earlier root
    /// shadows the old copy, so the path counts as much as the content.
    private static func isCurrent(_ sources: [ProtocCompileCache.Source], in searchPath: [URL]) -> Bool {
        !sources.isEmpty && sources.allSatisfy { source in
            guard let url = ProtoSourceSet.resolve(source.name, in: searchPath), url.path == source.path else {
                return false
            }
            return ProtoSourceSet.sha256(of: url) == source.sha256
        }
    }

    /// Whether protoc compiled the content the manifest records, rather than a version edited while it ran.
    ///
    /// Gathered files compare against their pre-launch digest. Files outside the walk (folder links, hidden folders,
    /// well-known types) have none, so they must predate the launch instead.
    private static func isUnchanged(_ manifest: [ProtocCompileCache.Source], since launchedAt: Date, digestsBefore: [String: String]) -> Bool {
        let cutoff = launchedAt.addingTimeInterval(-modificationTolerance)
        return manifest.allSatisfy { source in
            if let before = digestsBefore[source.path] {
                return before == source.sha256
            }
            let resolved = URL(fileURLWithPath: source.path).resolvingSymlinksInPath()
            guard let modified = try? FileManager.default.attributesOfItem(atPath: resolved.path)[.modificationDate] as? Date else {
                return false
            }
            return modified < cutoff
        }
    }
}
