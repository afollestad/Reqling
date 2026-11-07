import Foundation
import ReqlingScriptProtocol

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
        guard case .introspection = found.spec.body.graphQL.schema else {
            return try await graphQLSchemaFile(found)
        }
        let (probe, probeTLS) = try graphQLEndpoint(found, project: project, options: Self.probeOptions(options))
        if !refresh, let cached = await found.service.cached(probe, in: project) {
            return cached
        }
        // Asking the server: the pre-request scripts run first, in preview, so a header they compute reaches it. The
        // probe's key stays the cache key, or a query parameter a script changes on each run would refetch every time.
        let session = try await previewScripts(request, in: project, options: options)
        do throws(RunFailure) {
            let scripted = try session.map { session throws(RunFailure) in
                try graphQLContext(request, in: project, options: options, session: session)
            } ?? found
            let endpoint = try graphQLEndpoint(scripted, project: project, options: options, key: probe.key, reusing: probeTLS).endpoint
            do throws(GraphQLSchemaLookupError) {
                return try await found.service.introspected(endpoint, in: project, refresh: refresh)
            } catch {
                throw Self.lookupFailure(error).redacting(scripted.context.redaction)
            }
        } catch {
            throw error.noting(session)
        }
    }

    /// For a lookup that only reads the cache key, so a name only the pre-request scripts define doesn't fail before
    /// they run.
    private static func probeOptions(_ options: RunOptions) -> RunOptions {
        var options = options
        options.allowUnresolved = true
        return options
    }

    private func graphQLSchemaFile(_ found: GraphQLContext) async throws(RunFailure) -> GraphQLSchemaSnapshot {
        guard case .file(let reference) = found.spec.body.graphQL.schema else {
            throw RunFailure(kind: .invalidRequest, message: "The request has no schema file.")
        }
        do throws(GraphQLSchemaLookupError) {
            return try await found.service.file(reference, paths: found.context.paths)
        } catch {
            throw Self.lookupFailure(error).redacting(found.context.redaction)
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
        switch found.spec.body.graphQL.schema {
        case .file(let reference):
            return try? await found.service.file(reference, paths: found.context.paths)
        case .introspection:
            guard let endpoint = try? graphQLEndpoint(found, project: project, options: Self.probeOptions(options)).endpoint else {
                return nil
            }
            return await found.service.cached(endpoint, in: project)
        }
    }

    private func graphQLContext(
        _ request: RequestNodeID,
        in project: ProjectID,
        options: RunOptions,
        session: ScriptSession? = nil
    ) throws(RunFailure) -> GraphQLContext {
        guard let service = graphQLSchemas else {
            throw RunFailure(kind: .invalidRequest, message: "GraphQL schemas are not available here.")
        }
        let context = try runContext(request, in: project, options: options, session: session)
        guard let spec = context.item.kind.httpSpec, spec.body.mode == .graphQL else {
            throw RunFailure(kind: .invalidRequest, message: "“\(context.item.name)” does not send a GraphQL body.")
        }
        // The body policy is the one gate on bodies: a GET in GraphQL mode sends none, so it has no schema to check.
        guard spec.method.bodyPolicy.allowsBody else {
            throw RunFailure(kind: .invalidRequest, message: "\(spec.method.rawValue) requests do not send a GraphQL body; use POST.")
        }
        return GraphQLContext(service: service, context: context, spec: spec, scriptChanges: session?.changes)
    }

    private struct GraphQLContext {
        let service: GraphQLSchemaService
        let context: RunContext
        let spec: HTTPRequestSpec
        /// The pre-request scripts' header and query changes, already in `spec`, for masking; `nil` when none ran.
        let scriptChanges: [ScriptRequestChange]?
    }

    /// The request as introspection sends it: a POST of the query as a GraphQL body, its own query parameters,
    /// headers, and auth kept, and `Content-Type` set even if the request turned the automatic one off. `key`, when
    /// given, replaces the one this request would be cached under, and `earlier` is TLS built for the same lookup.
    private func graphQLEndpoint(
        _ found: GraphQLContext,
        project: ProjectID,
        options: RunOptions,
        key: String? = nil,
        reusing earlier: PreparedTLS? = nil
    ) throws(RunFailure) -> (endpoint: GraphQLEndpoint, tls: PreparedTLS) {
        let (spec, context) = (found.spec, found.context)
        // Takes the runner rather than capturing it, so `send` holds it weakly.
        let prepare = { (runner: RequestRunner, query: String) throws(RunFailure) -> PreparedHTTPRequest in
            var prepared = try runner.preparedHTTP(Self.introspectionSpec(spec, query: query), context: context, options: options)
            if let changes = found.scriptChanges {
                prepared.markScriptChanges(changes, redaction: context.redaction)
            }
            return prepared
        }
        let probe = try prepare(self, GraphQLIntrospection.probeQuery)
        let prepared = try tls(for: probe, project: project, context: context, reusing: earlier)
        let tls = prepared.context
        let isHTTPS = probe.urlRequest.url?.scheme?.lowercased() == "https"
        // The masked URL, so rotating a secret token does not refetch, and the certificates only where they apply.
        let probeKey = [probe.summary.url, probe.verifyTLS ? "verified" : "unverified", isHTTPS ? tls.fingerprint.base64EncodedString() : ""]
            .joined(separator: "\n")
        let executor = executor(for: project)
        let fetcher = found.service.fetcher
        let redaction = context.redaction
        let endpoint = GraphQLEndpoint(
            key: key ?? probeKey,
            shownURL: probe.summary.url,
            send: { [weak self] query throws(RunFailure) in
                guard let self else {
                    throw RunFailure(kind: .cancelled, message: HTTPExecutionError.cancelled.localizedDescription)
                }
                let prepared = query == GraphQLIntrospection.probeQuery ? probe : try prepare(self, query)
                do {
                    return try await fetcher.send(prepared, tls: tls, on: executor)
                } catch {
                    throw Self.failure(for: error).redacting(prepared.redaction)
                }
            },
            mask: { redaction.apply($0) }
        )
        return (endpoint, prepared)
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
