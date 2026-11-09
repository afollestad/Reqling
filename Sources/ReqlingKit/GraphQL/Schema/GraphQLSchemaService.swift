import Foundation
import Observation

/// Where a request introspects, with every template resolved (`RequestRunner` builds it from the request).
struct GraphQLEndpoint: Sendable {
    /// What one schema is cached under: the masked URL, the TLS policy, and the client certificates, but never the
    /// headers, so a token refresh does not refetch.
    let key: String
    /// The URL to show, with secrets masked.
    let shownURL: String
    /// Sends one query to the endpoint, with the request's headers, auth, and certificates.
    let send: @MainActor (String) async throws(RunFailure) -> HTTPResponseRecord
    /// Masks the request's secrets in what the server says, since servers echo credentials back.
    let mask: @Sendable (String) -> String
}

/// GraphQL schemas for requests, from introspection or a schema file, shared by the editor and the MCP tools so both
/// see the same one.
///
/// Introspected schemas are cached per project and endpoint, in memory for the few most recently used and on disk
/// (`GraphQLSchemaStore`) for the rest, so reopening a request, even after a relaunch, sends nothing. Refresh fetches
/// one endpoint again and, if that fails, keeps the cached schema with the failure as an issue. Schema files are
/// cached by path, size, and modification date, so an edited file is reread. `revision` changes whenever a cached
/// schema does, for views that show one.
@MainActor
@Observable
public final class GraphQLSchemaService {
    public private(set) var revision = 0

    @ObservationIgnored public let store: GraphQLSchemaStore
    @ObservationIgnored let fetcher: any GraphQLIntrospectionFetching
    @ObservationIgnored let now: @Sendable () -> Date
    @ObservationIgnored private var memory: [CacheKey: GraphQLSchemaSnapshot] = [:]
    /// Most recently used last.
    @ObservationIgnored private var memoryOrder: [CacheKey] = []
    /// Bumped per project by `forget`, so a fetch that started before it never caches its result when it lands.
    @ObservationIgnored private var generations: [ProjectID: Int] = [:]
    /// Bumped per endpoint as each fetch starts, so only the newest fetch of an endpoint caches its result.
    @ObservationIgnored private var fetches: [CacheKey: Int] = [:]
    @ObservationIgnored private var files: [URL: (stamp: FileStamp, snapshot: GraphQLSchemaSnapshot)] = [:]

    static let memoryCapacity = 4

    public init(store: GraphQLSchemaStore, fetcher: any GraphQLIntrospectionFetching, now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.fetcher = fetcher
        self.now = now
    }

    /// The cached schema for `endpoint`, from memory or disk, without asking the server.
    func cached(_ endpoint: GraphQLEndpoint, in project: ProjectID) async -> GraphQLSchemaSnapshot? {
        let key = CacheKey(project: project, endpoint: endpoint.key)
        if let snapshot = memory[key] {
            touch(key)
            return snapshot
        }
        let generation = generations[project, default: 0]
        let store = store
        guard let entry = await Task.detached(operation: { store.entry(for: endpoint.key, in: project) }).value,
              let snapshot = try? await Self.decode(entry.introspection, source: .introspection(url: entry.shownURL, fetchedAt: entry.fetchedAt),
                                                    capabilities: entry.capabilities, issues: entry.issues) else {
            return nil
        }
        guard generations[project, default: 0] == generation else {
            return nil
        }
        remember(snapshot, for: key)
        return snapshot
    }

    /// The cached schema for `endpoint`, or else one asked of the server. With `refresh`, the server is always asked;
    /// if that fails while a schema is cached, the cached one comes back with the failure as its first issue.
    func introspected(
        _ endpoint: GraphQLEndpoint,
        in project: ProjectID,
        refresh: Bool
    ) async throws(GraphQLSchemaLookupError) -> GraphQLSchemaSnapshot {
        let cached = await cached(endpoint, in: project)
        if let cached, !refresh {
            return cached
        }
        let key = CacheKey(project: project, endpoint: endpoint.key)
        let generation = generations[project, default: 0]
        fetches[key, default: 0] += 1
        let fetch = fetches[key, default: 0]
        let fetched: (snapshot: GraphQLSchemaSnapshot, entry: GraphQLSchemaStore.Entry)
        do {
            fetched = try await introspect(endpoint)
        } catch {
            if let cached, case .request(let failure) = error, failure.kind == .cancelled {
                return cached
            }
            if let cached {
                return cached.adding(issue: "Refreshing failed, so this is the schema from before: \(error.localizedDescription)")
            }
            throw error
        }
        guard generations[project, default: 0] == generation, fetches[key] == fetch else {
            return fetched.snapshot
        }
        store.store(fetched.entry, for: endpoint.key, in: project)
        remember(fetched.snapshot, for: key)
        return fetched.snapshot
    }

    /// The schema in a file: SDL or saved introspection JSON.
    func file(
        _ reference: ProjectPathReference,
        in slot: ProjectPathSlot,
        paths: ProjectPathResolver
    ) async throws(GraphQLSchemaLookupError) -> GraphQLSchemaSnapshot {
        guard let url = paths.url(for: reference, in: slot), let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            throw .unreadable("The schema file \(paths.describe(reference, in: slot)) could not be found on this Mac.")
        }
        let stamp = FileStamp(size: (attributes[.size] as? NSNumber)?.intValue ?? -1, modified: attributes[.modificationDate] as? Date)
        if let cached = files[url], cached.stamp == stamp {
            return cached.snapshot
        }
        let data: Data
        do {
            data = try paths.data(for: reference, in: slot)
        } catch {
            throw .unreadable(error.localizedDescription)
        }
        let decoded: GraphQLTypeSystem.Decoded
        do {
            decoded = try await GraphQLTypeSystem.loading(schemaFile: data)
        } catch {
            throw .unreadable("\(url.lastPathComponent): \(error.message)")
        }
        let snapshot = GraphQLSchemaSnapshot(
            typeSystem: decoded.typeSystem,
            source: .file(name: url.lastPathComponent),
            capabilities: nil,
            issues: decoded.issues
        )
        files[url] = (stamp, snapshot)
        revision += 1
        return snapshot
    }

    /// Drops a project's schemas, in memory and on disk, as when it is deleted; a fetch still in flight caches nothing.
    public func forget(_ project: ProjectID) {
        generations[project, default: 0] += 1
        let before = memory.count
        memory = memory.filter { $0.key.project != project }
        memoryOrder.removeAll { $0.project == project }
        fetches = fetches.filter { $0.key.project != project }
        store.removeAll(in: project)
        if memory.count != before {
            revision += 1
        }
    }

    private func remember(_ snapshot: GraphQLSchemaSnapshot, for key: CacheKey) {
        memory[key] = snapshot
        touch(key)
        while memoryOrder.count > Self.memoryCapacity {
            memory[memoryOrder.removeFirst()] = nil
        }
        revision += 1
    }

    private func touch(_ key: CacheKey) {
        memoryOrder.removeAll { $0 == key }
        memoryOrder.append(key)
    }

    /// Decodes off the main actor: a large schema takes a while.
    nonisolated static func decode(
        _ introspection: Data,
        source: GraphQLSchemaSnapshot.Source,
        capabilities: GraphQLIntrospection.Capabilities?,
        issues: [String]
    ) async throws(GraphQLSchemaLookupError) -> GraphQLSchemaSnapshot {
        let result = await Task.detached { () -> Result<GraphQLTypeSystem.Decoded, GraphQLSchemaDecodingError> in
            do throws(GraphQLSchemaDecodingError) {
                return .success(try GraphQLTypeSystem.decoding(introspection: introspection))
            } catch {
                return .failure(error)
            }
        }.value
        switch result {
        case .success(let decoded):
            return GraphQLSchemaSnapshot(typeSystem: decoded.typeSystem, source: source, capabilities: capabilities, issues: issues + decoded.issues)
        case .failure(let error):
            throw .unreadable(error.errorDescription ?? "The schema could not be read.")
        }
    }

    private struct CacheKey: Hashable {
        let project: ProjectID
        let endpoint: String
    }

    private struct FileStamp: Equatable {
        let size: Int
        let modified: Date?
    }
}
