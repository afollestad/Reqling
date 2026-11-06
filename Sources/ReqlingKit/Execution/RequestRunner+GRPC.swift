import Foundation

/// gRPC runs: the same entry points, history, and outcome tracking as HTTP (`run`, `cancel`, `forget`), plus live
/// sending on an open client-streaming or bidirectional call. A call's templates resolve once into sent and masked
/// text, auth inherits as for HTTP and travels as metadata, and the schema comes from `GRPCSchemaService`, so the run
/// and the editor's pickers agree on it.
extension RequestRunner {
    /// Sends `json` on the open call of `request`, resolved against the run's environment and encoded as the method's
    /// input type. Fails when no call is open, its request stream has ended, or the message does not fit the schema.
    public func sendMessage(_ json: String, to request: RequestNodeID, in project: ProjectID) throws(RunFailure) {
        let key = RunKey(request, in: project)
        guard let live = liveCalls[key], openStreams.contains(key) else {
            throw RunFailure(kind: .invalidRequest, message: "The call is not open for more messages.")
        }
        try live.send(json)
    }

    /// Closes the request stream of `request`'s open call; the server sees the client finish. Does nothing when no
    /// stream is open.
    public func endStream(_ request: RequestNodeID, in project: ProjectID) {
        let key = RunKey(request, in: project)
        liveCalls[key]?.outbox.finish()
        openStreams.remove(key)
    }

    /// The schema a gRPC request would use, resolved as a run would resolve it (target, auth, TLS), for the editor's
    /// service and method pickers and its Example message. Reflection is asked only when the request's schema source
    /// needs it, and its result is cached by `GRPCSchemaService`.
    public func grpcSchema(
        for request: RequestNodeID,
        in project: ProjectID,
        options: RunOptions = RunOptions()
    ) async throws(RunFailure) -> GRPCSchema {
        let context = try runContext(request, in: project, options: options)
        guard let spec = context.item.kind.grpcSpec else {
            throw RunFailure(kind: .invalidRequest, message: "“\(context.item.name)” is not a gRPC request.")
        }
        let usesReflection = spec.schema == .reflection || (spec.schema == .automatic && context.document.grpc.isEmpty)
        let endpoint = usesReflection ? try connection(for: spec, context: context, project: project, options: options) : nil
        return try await schema(for: spec, context: context, project: project, endpoint: endpoint)
    }

    /// The whole of a gRPC run, inside the run's task so `cancel` and `forget` reach every await.
    /// `id` is the run's, which every partial record it publishes carries.
    func runGRPC(_ request: RequestNodeID, in project: ProjectID, options: RunOptions, id: RunID, startedAt: Date) async -> RequestExchange {
        let key = RunKey(request, in: project)
        let live: GRPCLiveCall
        let call: GRPCCallRequest
        do {
            (live, call) = try await prepareGRPC(request, in: project, options: options, id: id, startedAt: startedAt)
        } catch {
            return failedExchange(request, in: project, startedAt: startedAt, error)
        }
        guard !Task.isCancelled else {
            return failedExchange(request, in: project, startedAt: startedAt, RunFailure(GRPCCallError.cancelled))
        }
        liveCalls[key] = live
        if live.method.kind.clientStreams, options.keepsStreamOpen {
            openStreams.insert(key)
        } else {
            live.outbox.finish()
        }
        let publishes = options.unsaved == nil
        if publishes {
            latest[key] = live.exchange
        }
        let outcome = await GRPCExecutor().execute(call) { event in
            await self.receive(event, on: live, key: key, publishes: publishes)
        }
        if liveCalls[key] === live {
            liveCalls[key] = nil
            openStreams.remove(key)
        }
        return live.finished(outcome)
    }

    /// `publishes` is false for an unsaved run, which records its events without showing them.
    private func receive(_ event: GRPCCallEvent, on live: GRPCLiveCall, key: RunKey, publishes: Bool) {
        // A replaced or forgotten run keeps streaming until its cancellation lands; it must not publish.
        guard liveCalls[key] === live else {
            return
        }
        live.apply(event)
        if publishes {
            publishThrottled(live, key: key) { [weak self] in self?.liveCalls[key] === live }
        }
    }

    private func prepareGRPC(
        _ request: RequestNodeID,
        in project: ProjectID,
        options: RunOptions,
        id: RunID,
        startedAt: Date
    ) async throws(RunFailure) -> (GRPCLiveCall, GRPCCallRequest) {
        let context = try runContext(request, in: project, options: options)
        do throws(RunFailure) {
            guard let spec = context.item.kind.grpcSpec else {
                throw RunFailure(kind: .invalidRequest, message: "The request no longer exists.")
            }
            let endpoint = try connection(for: spec, context: context, project: project, options: options)
            let schema = try await schema(for: spec, context: context, project: project, endpoint: endpoint)
            if Task.isCancelled {
                throw RunFailure(GRPCCallError.cancelled)
            }
            let timeout = GRPCRequestResolution.timeout(
                for: endpoint.resolved,
                kind: schema.registry.method(spec.methodPath)?.kind,
                keepsStreamOpen: options.keepsStreamOpen
            )
            guard !spec.service.isEmpty, !spec.method.isEmpty else {
                throw RunFailure(kind: .invalidRequest, message: "Choose a service and method to call.")
            }
            guard let method = schema.registry.method(spec.methodPath) else {
                throw Self.missingMethod(spec.methodPath, in: schema)
            }
            var templates = endpoint.templates
            let codec = ProtobufJSONCodec(registry: schema.registry)
            let seeds = try Self.seeds(spec, method: method, codec: codec, templates: &templates)
            if !options.allowUnresolved, !templates.unresolved.isEmpty {
                throw RunFailure.undefinedVariables(templates.unresolved)
            }
            let live = GRPCLiveCall(
                context: GRPCLiveCall.Context(
                    runID: id,
                    projectID: project,
                    requestID: request,
                    startedAt: startedAt,
                    environmentName: context.environmentName,
                    unresolvedVariables: templates.unresolved,
                    resolver: context.resolver,
                    redaction: context.redaction,
                    allowUnresolved: options.allowUnresolved
                ),
                method: method,
                endpoint: endpoint.resolved,
                codec: codec,
                seeds: seeds
            )
            return (live, live.request(security: endpoint.security, timeout: timeout))
        } catch {
            throw error.redacting(context.redaction)
        }
    }

    /// The spec's messages for the method's kind, resolved and encoded; an error names the message by position.
    private static func seeds(
        _ spec: GRPCRequestSpec,
        method: GRPCMethodDescriptor,
        codec: ProtobufJSONCodec,
        templates: inout RunTemplates
    ) throws(RunFailure) -> [EncodedMessage] {
        var seeds: [EncodedMessage] = []
        for (index, json) in GRPCRequestResolution.messages(spec, kind: method.kind).enumerated() {
            let text = try templates.resolve(json)
            seeds.append(try GRPCLiveCall.encode(text, as: method.inputType, codec: codec, label: "Message \(index + 1)"))
        }
        return seeds
    }

    /// A request's resolved endpoint with its TLS policy, and the templates it resolved (so its unresolved names
    /// carry into the messages').
    private struct Connection {
        let resolved: GRPCEndpoint
        let security: GRPCTransportSecurity
        let templates: RunTemplates
    }

    /// Fails on unresolved names before any network use, reflection included, as HTTP fails before sending.
    private func connection(
        for spec: GRPCRequestSpec,
        context: RunContext,
        project: ProjectID,
        options: RunOptions
    ) throws(RunFailure) -> Connection {
        do throws(RunFailure) {
            var templates = RunTemplates(resolver: context.resolver)
            let resolved = try GRPCRequestResolution.endpoint(
                spec,
                templates: &templates,
                authChain: context.authChain,
                defaults: settings.settings
            )
            if !options.allowUnresolved, !templates.unresolved.isEmpty {
                throw RunFailure.undefinedVariables(templates.unresolved)
            }
            let security: GRPCTransportSecurity = switch spec.security {
            case .plaintext:
                .plaintext
            case .tls:
                .tls(try tlsContext(
                    host: resolved.target.host,
                    port: resolved.target.port,
                    verifiesServer: resolved.verifiesServer,
                    project: project,
                    context: context
                ))
            }
            return Connection(resolved: resolved, security: security, templates: templates)
        } catch {
            throw error.redacting(context.redaction)
        }
    }

    private func schema(
        for spec: GRPCRequestSpec,
        context: RunContext,
        project: ProjectID,
        endpoint: Connection?
    ) async throws(RunFailure) -> GRPCSchema {
        guard let grpcSchemas else {
            throw RunFailure(kind: .invalidRequest, message: "gRPC schemas are not available here.")
        }
        let reflection = endpoint.map { endpoint in
            GRPCReflectionTarget(
                target: endpoint.resolved.target,
                security: endpoint.security,
                metadata: endpoint.resolved.metadata,
                timeout: endpoint.resolved.requestedTimeout ?? endpoint.resolved.defaultTimeout
            )
        }
        do {
            return try await grpcSchemas.schema(
                for: spec,
                in: project,
                configuration: context.document.grpc,
                paths: context.paths,
                reflection: reflection
            )
        } catch {
            throw Self.failure(for: error).redacting(context.redaction)
        }
    }

    private static func failure(for error: GRPCSchemaLookupError) -> RunFailure {
        switch error {
        case .schema(let schemaError):
            RunFailure(kind: .invalidRequest, message: schemaError.message)
        case .reflection(.call(let callError)):
            RunFailure(callError)
        case .reflection(.unsupported):
            RunFailure(kind: .invalidRequest, message: GRPCReflectionError.unsupported.localizedDescription)
        case .reflection(.status(let status)) where status.code == 4:
            RunFailure(kind: .timedOut, message: "Reading the schema through reflection timed out.")
        case .cancelled:
            RunFailure(GRPCCallError.cancelled)
        case .reflection(let reflectionError):
            RunFailure(kind: .transport, message: reflectionError.localizedDescription)
        }
    }

    private static func missingMethod(_ path: String, in schema: GRPCSchema) -> RunFailure {
        let source = switch schema.source {
        case .projectProtos: "the project's protos"
        case .reflection: "the schema the server reflects"
        case .descriptorSet: "the descriptor set"
        }
        let issue = schema.issue.map { " \($0)" } ?? ""
        return RunFailure(kind: .invalidRequest, message: "“\(path)” is not in \(source).\(issue)")
    }
}

/// What a gRPC request would send, resolved and masked, without asking for its schema or connecting.
public struct GRPCRequestPreview: Sendable {
    public let target: String
    public let methodPath: String
    public let metadata: [KeyValuePair]
    /// Every message in the spec, in order, whatever the method's kind; the call sends only those its kind takes.
    public let messages: [String]
    public let unresolvedVariables: [String]
}

extension RequestRunner {
    /// Resolves a gRPC request's target, metadata (auth included), and messages as a run would, with secrets masked;
    /// unresolved names are listed rather than refused.
    public func previewGRPC(
        _ request: RequestNodeID,
        in project: ProjectID,
        options: RunOptions = RunOptions()
    ) throws(RunFailure) -> GRPCRequestPreview {
        var options = options
        options.allowUnresolved = true
        let context = try runContext(request, in: project, options: options)
        guard let spec = context.item.kind.grpcSpec else {
            throw RunFailure(kind: .invalidRequest, message: "“\(context.item.name)” is not a gRPC request.")
        }
        var templates = RunTemplates(resolver: context.resolver)
        let endpoint = try GRPCRequestResolution.endpoint(spec, templates: &templates, authChain: context.authChain, defaults: settings.settings)
        var messages: [String] = []
        for message in spec.messages {
            messages.append(try templates.resolve(message).shown)
        }
        return GRPCRequestPreview(
            target: endpoint.shownTarget,
            methodPath: spec.methodPath,
            metadata: endpoint.shownMetadata,
            messages: messages,
            unresolvedVariables: templates.unresolved
        )
    }

    /// Masks every secret value the project can resolve, in any environment and from Global, wherever it appears in
    /// `text`, such as a response that echoes a token back. Every environment, not just the run's: a last response may
    /// have come from any of them. Take it before a run starts, so a request deleted meanwhile cannot leave the output
    /// unmasked.
    func maskingSecrets(in project: ProjectID, variableOverrides: [String: String] = [:]) -> @Sendable (String) -> String {
        // Before the values are read, so a secret the run is about to read again is masked as well.
        library.reloadSecretsIfUnread(for: project)
        guard let document = library.document(project) else {
            return { $0 }
        }
        let redactions = document.allEnvironments.map { environment in
            let scope = VariableScope(
                global: library.globalEnvironment,
                document: document,
                activeEnvironmentID: environment.id,
                overrides: variableOverrides
            )
            return SecretRedaction(resolver: TemplateResolver(scope: scope, dynamic: dynamic))
        }
        return { text in redactions.reduce(text) { $1.apply($0) } }
    }
}
