import Foundation

/// Sends one introspection query. The seam between schema loading and the network: test and screenshot graphs use
/// `OfflineGraphQLIntrospectionFetcher`, so opening a GraphQL request there never sends anything.
public protocol GraphQLIntrospectionFetching: Sendable {
    func send(_ request: PreparedHTTPRequest, tls: TLSContext, on executor: HTTPExecutor) async throws(HTTPExecutionError) -> HTTPResponseRecord
}

/// Sends through the project's executor, as a run does, so introspection shares its connections and cookies.
public struct LiveGraphQLIntrospectionFetcher: GraphQLIntrospectionFetching {
    public init() {}

    public func send(
        _ request: PreparedHTTPRequest,
        tls: TLSContext,
        on executor: HTTPExecutor
    ) async throws(HTTPExecutionError) -> HTTPResponseRecord {
        try await executor.execute(request, tls: tls)
    }
}

/// Refuses every request, for graphs that must stay offline; schema files still load.
public struct OfflineGraphQLIntrospectionFetcher: GraphQLIntrospectionFetching {
    public init() {}

    public func send(
        _ request: PreparedHTTPRequest,
        tls: TLSContext,
        on executor: HTTPExecutor
    ) async throws(HTTPExecutionError) -> HTTPResponseRecord {
        throw .transport("Introspection is turned off here; use a schema file.")
    }
}
