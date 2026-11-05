import Foundation

/// GraphQL schemas for requests, resolved the way their runs are: the request's URL, query parameters, headers, auth
/// (its folders' and project's too), environment, and certificates. Introspection is sent outside run tracking, so it
/// never shows as a run, records history, or counts as in flight; it uses the project's executor, so it shares the
/// project's cookies and connections.
extension RequestRunner {
    /// The schema a GraphQL request's editor, browser, and tools use: from its schema file, or else from the cache or
    /// the server (`GraphQLSchemaService`). `refresh` asks the server even when a schema is cached.
    public func graphQLSchema(
        for request: RequestNodeID,
        in project: ProjectID,
        refresh: Bool = false,
        options: RunOptions = RunOptions()
    ) async throws(RunFailure) -> GraphQLSchemaSnapshot {
        let found = try graphQLContext(request, in: project, options: options)
        let (service, context, spec) = (found.service, found.context, found.spec)
        let endpoint: GraphQLEndpoint?
        if case .introspection = spec.body.graphQL.schema {
            endpoint = try graphQLEndpoint(spec, service: service, context: context, project: project, options: options)
        } else {
            endpoint = nil
        }
        do throws(GraphQLSchemaLookupError) {
            switch spec.body.graphQL.schema {
            case .file(let reference):
                return try await service.file(reference, paths: context.paths)
            case .introspection:
                guard let endpoint else {
                    throw .unreadable("The request has nowhere to ask.")
                }
                return try await service.introspected(endpoint, in: project, refresh: refresh)
            }
        } catch {
            throw Self.lookupFailure(error).redacting(context.redaction)
        }
    }

    /// The schema a GraphQL request would use if it is already at hand (its file, or a cached introspection), without
    /// asking the server.
    public func cachedGraphQLSchema(
        for request: RequestNodeID,
        in project: ProjectID,
        options: RunOptions = RunOptions()
    ) async -> GraphQLSchemaSnapshot? {
        guard let found = try? graphQLContext(request, in: project, options: options) else {
            return nil
        }
        let (service, context, spec) = (found.service, found.context, found.spec)
        switch spec.body.graphQL.schema {
        case .file(let reference):
            return try? await service.file(reference, paths: context.paths)
        case .introspection:
            guard let endpoint = try? graphQLEndpoint(spec, service: service, context: context, project: project, options: options) else {
                return nil
            }
            return await service.cached(endpoint, in: project)
        }
    }

    private func graphQLContext(
        _ request: RequestNodeID,
        in project: ProjectID,
        options: RunOptions
    ) throws(RunFailure) -> GraphQLContext {
        guard let service = graphQLSchemas else {
            throw RunFailure(kind: .invalidRequest, message: "GraphQL schemas are not available here.")
        }
        let context = try runContext(request, in: project, options: options)
        guard let spec = context.item.kind.httpSpec, spec.body.mode == .graphQL else {
            throw RunFailure(kind: .invalidRequest, message: "“\(context.item.name)” does not send a GraphQL body.")
        }
        // The body policy is the one gate on bodies: a GET in GraphQL mode sends none, so it has no schema to check.
        guard spec.method.bodyPolicy.allowsBody else {
            throw RunFailure(kind: .invalidRequest, message: "\(spec.method.rawValue) requests do not send a GraphQL body; use POST.")
        }
        return GraphQLContext(service: service, context: context, spec: spec)
    }

    private struct GraphQLContext {
        let service: GraphQLSchemaService
        let context: RunContext
        let spec: HTTPRequestSpec
    }

    /// The request as introspection sends it: a POST of the query as a GraphQL body, its own query parameters,
    /// headers, and auth kept, and `Content-Type` set even if the request turned the automatic one off.
    private func graphQLEndpoint(
        _ spec: HTTPRequestSpec,
        service: GraphQLSchemaService,
        context: RunContext,
        project: ProjectID,
        options: RunOptions
    ) throws(RunFailure) -> GraphQLEndpoint {
        let probe = try preparedHTTP(Self.introspectionSpec(spec, query: GraphQLIntrospection.probeQuery), context: context, options: options)
        let tls = try tls(for: probe, project: project, context: context)
        let isHTTPS = probe.urlRequest.url?.scheme?.lowercased() == "https"
        // The masked URL, so rotating a secret token does not refetch, and the certificates only where they apply.
        let key = [probe.summary.url, probe.verifyTLS ? "verified" : "unverified", isHTTPS ? tls.fingerprint.base64EncodedString() : ""]
            .joined(separator: "\n")
        let executor = executor(for: project)
        let fetcher = service.fetcher
        let redaction = context.redaction
        return GraphQLEndpoint(
            key: key,
            shownURL: probe.summary.url,
            send: { [weak self] query throws(RunFailure) in
                guard let self else {
                    throw RunFailure(kind: .cancelled, message: HTTPExecutionError.cancelled.localizedDescription)
                }
                let prepared = query == GraphQLIntrospection.probeQuery
                    ? probe
                    : try preparedHTTP(Self.introspectionSpec(spec, query: query), context: context, options: options)
                do {
                    return try await fetcher.send(prepared, tls: tls, on: executor)
                } catch {
                    throw Self.failure(for: error).redacting(prepared.redaction)
                }
            },
            mask: { redaction.apply($0) }
        )
    }

    static func introspectionSpec(_ spec: HTTPRequestSpec, query: String) -> HTTPRequestSpec {
        var spec = spec
        spec.method = .post
        spec.body = HTTPBody(mode: .graphQL, graphQL: GraphQLBody(query: query, operationName: GraphQLIntrospection.operationName))
        spec.disabledAutoHeaders.removeAll { $0.caseInsensitiveCompare("Content-Type") == .orderedSame }
        return spec
    }

    private static func lookupFailure(_ error: GraphQLSchemaLookupError) -> RunFailure {
        switch error {
        case .request(let failure): failure
        case .unreadable(let message): RunFailure(kind: .invalidRequest, message: message)
        case .refused, .introspection: RunFailure(kind: .transport, message: error.localizedDescription)
        }
    }
}
