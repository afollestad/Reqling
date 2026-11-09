import Foundation

/// A configuration resolved against one project folder and Mac. Comparing plans is how a workspace tells whether a
/// configuration or local-path change alters what it compiles.
struct ProtoWorkspacePlan: Hashable, Sendable {
    struct Path: Hashable, Sendable {
        /// `nil` for a this-Mac-only path recorded on another Mac, or a relative one outside the project that wasn't
        /// chosen on this Mac.
        let url: URL?
        let description: String
    }

    let roots: [Path]
    let files: [String]
    let descriptorSets: [Path]

    init(configuration: ProjectGRPCConfiguration, resolver: ProjectPathResolver) {
        roots = configuration.protoRoots.map { Self.path(for: $0, resolver: resolver) }
        files = configuration.protoFiles
        descriptorSets = configuration.descriptorSets.map { Self.path(for: $0, resolver: resolver) }
    }

    /// A relative path outside the project's folder or repository resolves to `nil` unless the person chose it on this
    /// Mac (`ProjectPathResolver.url(for:)`), so a cloned `../../..` never has Reqling walk, watch, and hash the home
    /// folder.
    private static func path(for reference: ProjectPathReference, resolver: ProjectPathResolver) -> Path {
        Path(url: resolver.url(for: reference), description: resolver.describe(reference))
    }

    var isEmpty: Bool {
        roots.isEmpty && descriptorSets.isEmpty
    }

    var watchedURLs: [URL] {
        roots.compactMap(\.url) + descriptorSets.compactMap(\.url)
    }
}

/// A successful protoc compile and the input that produced it.
struct ProtoWorkspaceCompilation: Sendable {
    let input: ProtocCompileInput
    let registry: DescriptorRegistry
}

/// What one build produced, before the workspace stamps and publishes it.
struct ProtoWorkspaceOutcome: Sendable {
    enum Status: Sendable {
        case empty
        case ready
        case needsProtoc
        case failed([ProtocDiagnostic])
        case missingPaths([String])
    }

    let registry: DescriptorRegistry
    let status: Status
    /// The compile to remember for the next build.
    let compilation: ProtoWorkspaceCompilation?
    /// Gathered files a successful compile skipped.
    let warnings: [ProtocDiagnostic]
}

/// Loads a plan off the main actor: descriptor sets directly, proto roots through protoc.
enum ProtoWorkspaceBuilder {
    /// Builds everything that is present, so one missing root does not hide the services the others define.
    ///
    /// A failed compile of the same input as `previous` keeps `previous`'s services, so a syntax error mid-edit
    /// leaves the method pickers working while the status reports it. Throws only `CancellationError`.
    @concurrent
    static func build(
        _ plan: ProtoWorkspacePlan,
        previous: ProtoWorkspaceCompilation?,
        reusingCache: Bool,
        importer: ProtocImporter,
        locateProtoc: @Sendable () async throws -> ProtocInstallation?
    ) async throws -> ProtoWorkspaceOutcome {
        var missing: [String] = []
        let roots = plan.roots.compactMap { path -> URL? in
            guard let url = path.url, isDirectory(url) else {
                missing.append(path.description)
                return nil
            }
            return url
        }
        var entries = plan.files
        if !entries.isEmpty, !roots.isEmpty {
            let present = entries.filter { file in roots.contains { FileManager.default.fileExists(atPath: $0.appendingPathComponent(file).path) } }
            // Under a missing root its files are missing too; naming the root is enough.
            if missing.isEmpty {
                missing += entries.filter { !present.contains($0) }.map { "“\($0)”" }
            }
            entries = present
        }
        var (sets, diagnostics) = loadDescriptorSets(plan.descriptorSets, missing: &missing)

        var compilation: ProtoWorkspaceCompilation?
        var warnings: [ProtocDiagnostic] = []
        var needsProtoc = false
        // An entry list filtered down to nothing must not turn into "compile everything".
        if !roots.isEmpty, plan.files.isEmpty || !entries.isEmpty {
            let input = ProtocCompileInput(roots: roots, files: entries)
            let result = try await compile(input, previous: previous, reusingCache: reusingCache, importer: importer, locateProtoc: locateProtoc)
            switch result {
            case .compiled(let result, let skipped):
                compilation = result
                warnings = skipped
            case .needsProtoc:
                needsProtoc = true
            case .failed(let failure, let kept):
                diagnostics += failure
                compilation = kept
            }
        }
        sets = (compilation?.registry ?? .empty).merging(sets)

        let status: ProtoWorkspaceOutcome.Status
        if !missing.isEmpty {
            status = .missingPaths(missing)
        } else if !diagnostics.isEmpty {
            status = .failed(diagnostics)
        } else if needsProtoc {
            status = .needsProtoc
        } else {
            status = plan.isEmpty ? .empty : .ready
        }
        return ProtoWorkspaceOutcome(registry: sets, status: status, compilation: compilation, warnings: warnings)
    }

    private enum CompileResult {
        case compiled(ProtoWorkspaceCompilation, warnings: [ProtocDiagnostic])
        case needsProtoc
        /// The diagnostics, and the previous compilation when it had the same input.
        case failed([ProtocDiagnostic], ProtoWorkspaceCompilation?)
    }

    private static func compile(
        _ input: ProtocCompileInput,
        previous: ProtoWorkspaceCompilation?,
        reusingCache: Bool,
        importer: ProtocImporter,
        locateProtoc: @Sendable () async throws -> ProtocInstallation?
    ) async throws -> CompileResult {
        do {
            guard let protoc = try await locateProtoc() else {
                return .needsProtoc
            }
            let result = try await importer.compilation(input, with: protoc, reusingCache: reusingCache)
            return .compiled(ProtoWorkspaceCompilation(input: input, registry: result.registry), warnings: result.warnings)
        } catch is CancellationError {
            throw CancellationError()
        } catch let failure as ProtocImportFailure {
            return .failed(failure.diagnostics, previous?.input == input ? previous : nil)
        } catch {
            return .failed([ProtocDiagnostic(message: error.localizedDescription)], nil)
        }
    }

    /// Descriptor sets merged in order, so a later file's definitions win, plus a diagnostic per unreadable set.
    private static func loadDescriptorSets(
        _ paths: [ProtoWorkspacePlan.Path],
        missing: inout [String]
    ) -> (DescriptorRegistry, [ProtocDiagnostic]) {
        var registry = DescriptorRegistry.empty
        var diagnostics: [ProtocDiagnostic] = []
        for path in paths {
            guard let url = path.url, let data = try? Data(contentsOf: url) else {
                missing.append(path.description)
                continue
            }
            do {
                registry = registry.merging(try DescriptorRegistry(descriptorSet: data))
            } catch {
                diagnostics.append(ProtocDiagnostic(file: url.lastPathComponent, message: error.message, url: url))
            }
        }
        return (registry, diagnostics)
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}
