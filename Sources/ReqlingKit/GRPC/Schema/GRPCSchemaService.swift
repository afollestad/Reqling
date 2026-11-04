import Foundation
import Observation
import Synchronization

/// Resolves the schema a gRPC request uses (its project's compiled protos, server reflection, or a descriptor set
/// file), for both the editor's service and method pickers and the runner, so both always see the same one.
///
/// Reflection results are cached per project, target, and security, so picking a method and sending repeatedly do not
/// refetch; `refreshReflection` drops them. Descriptor set files are cached by path, size, and modification date, so
/// an edited file is reread. `revision` changes whenever a cache does, for views that show a schema.
@MainActor
@Observable
public final class GRPCSchemaService {
    @ObservationIgnored public let workspaces: ProtoWorkspaceStore
    @ObservationIgnored private let reflection: GRPCReflectionClient
    /// Bumped when a reflection result arrives or is dropped.
    public private(set) var revision = 0
    @ObservationIgnored private var reflected: [ReflectionKey: DescriptorRegistry] = [:]
    /// Bumped per project by `refreshReflection`, so a lookup that started before a refresh (or a `forget`) never
    /// caches its now-stale result when it lands.
    @ObservationIgnored private var generations: [ProjectID: Int] = [:]
    @ObservationIgnored private var descriptorSets: [URL: (stamp: FileStamp, registry: DescriptorRegistry)] = [:]

    public init(workspaces: ProtoWorkspaceStore, reflection: GRPCReflectionClient = GRPCReflectionClient()) {
        self.workspaces = workspaces
        self.reflection = reflection
    }

    /// The schema `spec.schema` names. `.automatic` uses the project's protos when its gRPC configuration has any,
    /// otherwise reflection. `reflection` is where reflection connects, resolved from the request; it is only read when
    /// reflection is used, and `nil` there means the request has no usable target.
    public func schema(
        for spec: GRPCRequestSpec,
        in project: ProjectID,
        configuration: ProjectGRPCConfiguration,
        paths: ProjectPathResolver,
        reflection target: GRPCReflectionTarget?
    ) async throws(GRPCSchemaLookupError) -> GRPCSchema {
        switch spec.schema {
        case .automatic where !configuration.isEmpty, .projectProtos:
            return try await projectProtos(in: project, configuration: configuration, paths: paths)
        case .automatic, .reflection:
            guard let target else {
                throw .schema(GRPCSchemaError("Enter a target to read the schema through server reflection."))
            }
            return GRPCSchema(registry: try await reflected(target, in: project), source: .reflection)
        case .descriptorSet(let reference):
            do {
                return GRPCSchema(registry: try descriptorSet(reference, paths: paths), source: .descriptorSet)
            } catch {
                throw .schema(error)
            }
        }
    }

    /// Drops the project's reflection results, so the next lookup asks the server again.
    public func refreshReflection(in project: ProjectID) {
        generations[project, default: 0] += 1
        let before = reflected.count
        reflected = reflected.filter { $0.key.project != project }
        if reflected.count != before {
            revision += 1
        }
    }

    /// Waits for the project's protos to settle, so a run uses the newest compile. A status that leaves no schema
    /// fails; one that leaves part of it (descriptor sets loaded while protoc is missing) returns that part with
    /// `issue` saying why the rest is missing.
    private func projectProtos(
        in project: ProjectID,
        configuration: ProjectGRPCConfiguration,
        paths: ProjectPathResolver
    ) async throws(GRPCSchemaLookupError) -> GRPCSchema {
        let workspace = workspaces.workspace(for: project, configuration: configuration, resolver: paths)
        await Self.settled(workspace)
        if Task.isCancelled {
            throw .cancelled
        }
        let issue: String?
        switch workspace.status {
        case .ready:
            issue = nil
        case .empty:
            issue = "This project has no proto files or descriptor sets; add them in the project's gRPC settings, or use reflection."
        case .compiling:
            issue = "The project's protos are still compiling; try again in a moment."
        case .needsProtoc:
            issue = "Compiling the project's protos needs protoc; install it in Settings → gRPC."
        case .failed(let diagnostics):
            let first = diagnostics.first.map { ": \($0)" } ?? "."
            issue = "The project's protos failed to compile\(first)"
        case .missingPaths(let missing):
            issue = "Some of the project's proto paths are missing: \(missing.joined(separator: ", "))."
        }
        if let issue, workspace.registry.isEmpty {
            throw .schema(GRPCSchemaError(issue))
        }
        return GRPCSchema(registry: workspace.registry, source: .projectProtos, issue: issue)
    }

    private func reflected(_ target: GRPCReflectionTarget, in project: ProjectID) async throws(GRPCSchemaLookupError) -> DescriptorRegistry {
        let key = ReflectionKey(project: project, endpoint: target.cacheKey)
        if let cached = reflected[key] {
            return cached
        }
        let generation = generations[project, default: 0]
        let registry: DescriptorRegistry
        do {
            registry = try await reflection.registry(
                target: target.target,
                security: target.security,
                metadata: target.metadata,
                timeout: target.timeout
            )
        } catch {
            throw .reflection(error)
        }
        if generations[project, default: 0] == generation {
            reflected[key] = registry
            revision += 1
        }
        return registry
    }

    /// Waits for `workspace` to settle, or returns early when the caller is cancelled: `ProtoWorkspace.settled()`
    /// waits out a compile regardless, and a run must stop when its cancel button is pressed. The compile itself keeps
    /// going for the workspace's other users.
    private static func settled(_ workspace: ProtoWorkspace) async {
        let gate = OnceGate()
        Task { @MainActor in
            await workspace.settled()
            gate.open()
        }
        await withTaskCancellationHandler {
            await gate.wait()
        } onCancel: {
            gate.open()
        }
    }

    private func descriptorSet(_ reference: ProjectPathReference, paths: ProjectPathResolver) throws(GRPCSchemaError) -> DescriptorRegistry {
        guard let url = paths.url(for: reference),
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            throw GRPCSchemaError("The descriptor set \(paths.describe(reference)) could not be found on this Mac.")
        }
        let stamp = FileStamp(
            size: (attributes[.size] as? NSNumber)?.intValue ?? -1,
            modified: attributes[.modificationDate] as? Date
        )
        if let cached = descriptorSets[url], cached.stamp == stamp {
            return cached.registry
        }
        let data: Data
        do {
            data = try paths.data(for: reference)
        } catch {
            throw GRPCSchemaError(error.localizedDescription)
        }
        let registry = try DescriptorRegistry(descriptorSet: data)
        descriptorSets[url] = (stamp, registry)
        return registry
    }

    private struct ReflectionKey: Hashable {
        let project: ProjectID
        let endpoint: GRPCReflectionTarget.CacheKey
    }

    private struct FileStamp: Equatable {
        let size: Int
        let modified: Date?
    }
}

/// A schema and where it came from.
public struct GRPCSchema: Sendable {
    public enum Source: String, Hashable, Sendable {
        case projectProtos
        case reflection
        case descriptorSet
    }

    public let registry: DescriptorRegistry
    public let source: Source
    /// Why part of the schema may be missing, such as compile errors while the project's descriptor sets still loaded;
    /// `nil` when it is whole.
    public let issue: String?

    public init(registry: DescriptorRegistry, source: Source, issue: String? = nil) {
        self.registry = registry
        self.source = source
        self.issue = issue
    }
}

/// Where reflection connects, with every template already resolved (`RequestRunner` builds it from the request).
public struct GRPCReflectionTarget: Sendable {
    public var target: GRPCTarget
    public var security: GRPCTransportSecurity
    /// Sent with the reflection call, for servers that authenticate it: the request's auth and metadata.
    public var metadata: [KeyValuePair]
    public var timeout: Duration?

    public init(target: GRPCTarget, security: GRPCTransportSecurity, metadata: [KeyValuePair] = [], timeout: Duration? = nil) {
        self.target = target
        self.security = security
        self.metadata = metadata
        self.timeout = timeout
    }

    /// The target and its TLS policy. Metadata is left out: a schema does not change with credentials, and keying on
    /// them would refetch after every token refresh.
    struct CacheKey: Hashable {
        let target: GRPCTarget
        let tls: Data?
        let verifiesServer: Bool
    }

    var cacheKey: CacheKey {
        switch security {
        case .plaintext:
            CacheKey(target: target, tls: nil, verifiesServer: false)
        case .tls(let context):
            CacheKey(target: target, tls: context.fingerprint, verifiesServer: context.verifiesServer)
        }
    }
}

/// Why no schema could be found for a request.
public enum GRPCSchemaLookupError: Error, Hashable, Sendable, LocalizedError {
    /// The configured source has no usable schema: protoc is missing, a compile failed, a file is missing or unreadable.
    case schema(GRPCSchemaError)
    case reflection(GRPCReflectionError)
    /// The caller was cancelled while waiting for the project's protos to compile.
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .schema(let error): error.message
        case .reflection(let error): error.errorDescription
        case .cancelled: GRPCCallError.cancelled.errorDescription
        }
    }
}

/// Lets one waiter through once `open()` is called, whether that comes before or after `wait()`.
private final class OnceGate: Sendable {
    private struct State {
        var isOpen = false
        var waiter: CheckedContinuation<Void, Never>?
    }

    private let state = Mutex(State())

    func wait() async {
        await withCheckedContinuation { continuation in
            let proceed = state.withLock { state in
                guard !state.isOpen else {
                    return true
                }
                state.waiter = continuation
                return false
            }
            if proceed {
                continuation.resume()
            }
        }
    }

    func open() {
        let waiter = state.withLock { state in
            state.isOpen = true
            defer { state.waiter = nil }
            return state.waiter
        }
        waiter?.resume()
    }
}
