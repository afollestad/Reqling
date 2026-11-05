import Foundation

/// Asking a server for its schema: the probe first, then the full query it supports, then graphql-js's default query
/// for servers that refuse anything else. Responses are read off the main actor, since a large schema is many
/// megabytes of JSON, and what the server says is masked before it is shown.
extension GraphQLSchemaService {
    func introspect(
        _ endpoint: GraphQLEndpoint
    ) async throws(GraphQLSchemaLookupError) -> (snapshot: GraphQLSchemaSnapshot, entry: GraphQLSchemaStore.Entry) {
        let attempts: [GraphQLIntrospection.Capabilities]
        switch try await outcome(of: GraphQLIntrospection.probeQuery, endpoint) {
        case .data(let json, _):
            let probe = (try? JSONSerialization.jsonObject(with: json) as? [String: Any]) ?? [:]
            let capabilities = GraphQLIntrospection.capabilities(fromProbe: probe)
            attempts = capabilities == .conservative ? [.conservative] : [capabilities, .conservative]
        case .refused:
            // A server that answers only the queries it expects may still answer graphql-js's own.
            attempts = [.conservative]
        case .failed(let failure):
            throw .introspection(failure)
        }
        var lastError = GraphQLSchemaLookupError.unreadable("The server's response holds no schema.")
        for capabilities in attempts {
            switch try await outcome(of: GraphQLIntrospection.query(capabilities), endpoint) {
            case .data(let json, let errors):
                let fetchedAt = now()
                let issues = errors.map { "The server also reported: \(endpoint.mask($0))" }
                do {
                    let snapshot = try await Self.decode(
                        json,
                        source: .introspection(url: endpoint.shownURL, fetchedAt: fetchedAt),
                        capabilities: capabilities,
                        issues: issues
                    )
                    let entry = GraphQLSchemaStore.Entry(
                        fetchedAt: fetchedAt,
                        shownURL: endpoint.shownURL,
                        capabilities: capabilities,
                        introspection: json,
                        issues: issues
                    )
                    return (snapshot, entry)
                } catch {
                    lastError = error
                }
            case .refused(let messages):
                lastError = .refused(messages.map(endpoint.mask))
            case .failed(let failure):
                throw .introspection(failure)
            }
        }
        throw lastError
    }

    private func outcome(of query: String, _ endpoint: GraphQLEndpoint) async throws(GraphQLSchemaLookupError) -> GraphQLIntrospection.Outcome {
        let response: HTTPResponseRecord
        do {
            response = try await endpoint.send(query)
        } catch {
            throw .request(error)
        }
        let outcome = await Task.detached { GraphQLIntrospection.classify(response) }.value
        if case .failed(.http(let status, let snippet)) = outcome {
            return .failed(.http(status: status, snippet: snippet.map(endpoint.mask)))
        }
        return outcome
    }
}
