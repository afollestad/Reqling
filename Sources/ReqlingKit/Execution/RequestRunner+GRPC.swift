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
        scriptSessions[key]?.closeStreamSending()
    }

    /// The schema a gRPC request would use, resolved as a run would resolve it (target, auth, TLS), for the editor's
    /// service and method pickers and its Example message. Reflection is asked only when the request's schema source
    /// needs it, and its result is cached by `GRPCSchemaService`.
    ///
    /// Before asking the server, the request's pre-request scripts run in preview, so metadata they compute reaches it.
    /// A cached schema needs none, and scripts can't change what one is cached under: the target and its security.
    public func grpcSchema(
        for request: RequestNodeID,
        in project: ProjectID,
        options: RunOptions = RunOptions()
    ) async throws(RunFailure) -> GRPCSchema {
        let context = try runContext(request, in: project, options: options)
        guard let spec = context.item.kind.grpcSpec else {
            throw RunFailure(kind: .invalidRequest, message: "“\(context.item.name)” is not a gRPC request.")
        }
        guard spec.schema == .reflection || (spec.schema == .automatic && context.document.grpc.isEmpty) else {
            return try await schema(for: spec, context: context, endpoint: nil)
        }
        // Only for the cache key, so a name only the scripts define doesn't fail before they run.
        var probeOptions = options
        probeOptions.allowUnresolved = true
        let probe = try connection(for: spec, context: context, project: project, options: probeOptions)
        if grpcSchemas?.hasReflection(Self.reflectionTarget(probe), in: project) != false {
            return try await schema(for: spec, context: context, endpoint: probe)
        }
        let session = try await previewScripts(request, in: project, options: options)
        do throws(RunFailure) {
            let scripted = try session.map { session throws(RunFailure) in try runContext(request, in: project, options: options, session: session) }
                ?? context
            guard let scriptedSpec = scripted.item.kind.grpcSpec else {
                throw RunFailure(kind: .invalidRequest, message: "“\(context.item.name)” is not a gRPC request.")
            }
            let endpoint = try connection(for: scriptedSpec, context: scripted, project: project, options: options, reusing: probe)
            return try await schema(for: scriptedSpec, context: scripted, endpoint: endpoint)
        } catch {
            throw error.noting(session)
        }
    }

    /// The whole of a gRPC run, inside the run's task so `cancel` and `forget` reach every await: its pre-request
    /// scripts, preparing the call with what they left, and the call. Every partial record it publishes carries the
    /// stamp's run ID.
    func executeGRPC(_ key: RunKey, options: RunOptions, stamp: RunStamp, session: ScriptSession?) async -> RequestExchange {
        let request = key.requestID
        let project = key.projectID
        if let session, let failure = await runPreRequestScripts(session, key: key, options: options) {
            return failedExchange(request, in: project, startedAt: stamp.startedAt, failure)
        }
        let live: GRPCLiveCall
        let call: GRPCCallRequest
        do throws(RunFailure) {
            // Checked first too, so a run replaced while its scripts ran never asks the server for its schema.
            guard !Task.isCancelled else {
                throw RunFailure(GRPCCallError.cancelled)
            }
            (live, call) = try await prepareGRPC(key, options: options, stamp: stamp, session: session)
        } catch {
            return failedExchange(request, in: project, startedAt: stamp.startedAt, error)
        }
        guard !Task.isCancelled else {
            return failedExchange(request, in: project, startedAt: stamp.startedAt, RunFailure(GRPCCallError.cancelled))
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
            await self.receive(event, on: live, key: key, publishes: publishes, session: session)
        }
        session?.closeStreamSending()
        let exchange = live.finished(outcome)
        if liveCalls[key] === live {
            liveCalls[key] = nil
            openStreams.remove(key)
            pendingPostExchanges[key] = exchange
        }
        return exchange
    }

    /// `publishes` is false for an unsaved run, which records its events without showing them.
    private func receive(_ event: GRPCCallEvent, on live: GRPCLiveCall, key: RunKey, publishes: Bool, session: ScriptSession?) {
        // A replaced or forgotten run keeps streaming until its cancellation lands; it must not publish.
        guard liveCalls[key] === live else {
            return
        }
        let received = live.apply(event)
        // Stream scripts start once the server answers: with its metadata, which comes before any message.
        if case .initialMetadata = event {
            startStreamScripts(session, on: live, key: key, publishes: publishes)
        }
        if let received {
            startStreamScripts(session, on: live, key: key, publishes: publishes)
            session?.deliver(.grpcMessage(received), number: live.receivedCount)
        }
        if publishes {
            publishThrottled(live, key: key) { [weak self] in self?.liveCalls[key] === live }
        }
    }

    /// Once: every message received asks, in case the server sent none of its metadata first.
    private func startStreamScripts(_ session: ScriptSession?, on live: GRPCLiveCall, key: RunKey, publishes: Bool) {
        guard let session, session.stream == nil else {
            return
        }
        startStreamScripts(session, key: key, live: live, publishes: publishes, transport: StreamScriptsTransport(
            opening: ScriptInputBuilder.opening(grpcMetadata: live.initialMetadata),
            canSend: openStreams.contains(key),
            isCurrent: { [weak self, weak live] in live != nil && self?.liveCalls[key] === live },
            refresh: { [weak live] resolver, redaction in live?.refresh(resolver: resolver, redaction: redaction) },
            send: { [weak self, weak live] message in
                guard let self, let live, liveCalls[key] === live, openStreams.contains(key) else {
                    return .closed("The call's request stream is closed, so the message wasn't sent.")
                }
                guard case .text(let json) = message else {
                    return .invalid("A gRPC message is JSON, not bytes.")
                }
                return live.send(scriptedJSON: json)
            }
        ))
    }

    private func prepareGRPC(
        _ key: RunKey,
        options: RunOptions,
        stamp: RunStamp,
        session: ScriptSession?
    ) async throws(RunFailure) -> (GRPCLiveCall, GRPCCallRequest) {
        let request = key.requestID
        let project = key.projectID
        let context = try runContext(request, in: project, options: options, session: session)
        do throws(RunFailure) {
            guard let spec = context.item.kind.grpcSpec else {
                throw RunFailure(kind: .invalidRequest, message: "The request no longer exists.")
            }
            var endpoint = try connection(for: spec, context: context, project: project, options: options)
            if let session {
                endpoint.resolved.markScriptChanges(session.changes, redaction: context.redaction)
            }
            let schema = try await schema(for: spec, context: context, endpoint: endpoint)
            if Task.isCancelled {
                throw RunFailure(GRPCCallError.cancelled)
            }
            let method = try Self.method(spec, in: schema)
            let timeout = GRPCRequestResolution.timeout(for: endpoint.resolved, kind: method.kind, keepsStreamOpen: options.keepsStreamOpen)
            var templates = endpoint.templates
            let codec = ProtobufJSONCodec(registry: schema.registry)
            let seeds = try Self.seeds(spec, method: method, codec: codec, templates: &templates)
            if !options.allowUnresolved, !templates.unresolved.isEmpty {
                throw RunFailure.undefinedVariables(templates.unresolved)
            }
            let live = GRPCLiveCall(
                context: GRPCLiveCall.Context(
                    runID: stamp.id,
                    projectID: project,
                    requestID: request,
                    startedAt: stamp.startedAt,
                    environmentName: context.environmentName,
                    unresolvedVariables: templates.unresolved,
                    resolver: context.resolver,
                    redaction: context.redaction,
                    allowUnresolved: options.allowUnresolved,
                    scripts: session
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

    /// The method the spec names, from the schema; its kind decides how the call runs, never the spec.
    private static func method(_ spec: GRPCRequestSpec, in schema: GRPCSchema) throws(RunFailure) -> GRPCMethodDescriptor {
        guard !spec.service.isEmpty, !spec.method.isEmpty else {
            throw RunFailure(kind: .invalidRequest, message: "Choose a service and method to call.")
        }
        guard let method = schema.registry.method(spec.methodPath) else {
            throw missingMethod(spec.methodPath, in: schema)
        }
        return method
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
        var resolved: GRPCEndpoint
        let security: GRPCTransportSecurity
        let templates: RunTemplates
    }

    /// Fails on unresolved names before any network use, reflection included, as HTTP fails before sending. `earlier`'s
    /// TLS is reused when it was built for the same target and verification, as a schema lookup's script-free probe is:
    /// a script can set a variable the target uses, so only an unchanged one shares the certificates read for it.
    private func connection(
        for spec: GRPCRequestSpec,
        context: RunContext,
        project: ProjectID,
        options: RunOptions,
        reusing earlier: Connection? = nil
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
            let security: GRPCTransportSecurity
            if spec.security == .tls, let earlier, case .tls = earlier.security,
               earlier.resolved.target == resolved.target, earlier.resolved.verifiesServer == resolved.verifiesServer {
                security = earlier.security
            } else {
                security = switch spec.security {
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
            }
            return Connection(resolved: resolved, security: security, templates: templates)
        } catch {
            throw error.redacting(context.redaction)
        }
    }

    private func schema(
        for spec: GRPCRequestSpec,
        context: RunContext,
        endpoint: Connection?
    ) async throws(RunFailure) -> GRPCSchema {
        guard let grpcSchemas else {
            throw RunFailure(kind: .invalidRequest, message: "gRPC schemas are not available here.")
        }
        let reflection = endpoint.map(Self.reflectionTarget)
        do {
            return try await grpcSchemas.schema(
                for: spec,
                of: context.item.id,
                in: context.document,
                paths: context.paths,
                reflection: reflection
            )
        } catch {
            throw Self.failure(for: error).redacting(context.redaction)
        }
    }

    private static func reflectionTarget(_ endpoint: Connection) -> GRPCReflectionTarget {
        GRPCReflectionTarget(
            target: endpoint.resolved.target,
            security: endpoint.security,
            metadata: endpoint.resolved.metadata,
            timeout: endpoint.resolved.requestedTimeout ?? endpoint.resolved.defaultTimeout
        )
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
    /// What the pre-request scripts the preview ran did; `nil` when none would run.
    public let scriptReport: ScriptReport?
}

extension RequestRunner {
    /// Resolves a gRPC request's target, metadata (auth included), and messages as a run would, its pre-request scripts
    /// included, with secrets masked; unresolved names are listed rather than refused, and nothing the scripts set is
    /// kept.
    public func previewGRPC(
        _ request: RequestNodeID,
        in project: ProjectID,
        options: RunOptions = RunOptions()
    ) async throws(RunFailure) -> GRPCRequestPreview {
        var options = options
        options.allowUnresolved = true
        // A request that isn't gRPC fails before any script runs.
        let unscripted = try runContext(request, in: project, options: options)
        guard unscripted.item.kind.grpcSpec != nil else {
            throw RunFailure(kind: .invalidRequest, message: "“\(unscripted.item.name)” is not a gRPC request.")
        }
        let session = try await previewScripts(request, in: project, options: options)
        let context = try runContext(request, in: project, options: options, session: session)
        guard let spec = context.item.kind.grpcSpec else {
            throw RunFailure(kind: .invalidRequest, message: "“\(context.item.name)” is not a gRPC request.")
        }
        var templates = RunTemplates(resolver: context.resolver)
        var endpoint = try GRPCRequestResolution.endpoint(spec, templates: &templates, authChain: context.authChain, defaults: settings.settings)
        if let session {
            endpoint.markScriptChanges(session.changes, redaction: context.redaction)
        }
        var messages: [String] = []
        for message in spec.messages {
            messages.append(try templates.resolve(message).shown)
        }
        return GRPCRequestPreview(
            target: endpoint.shownTarget,
            methodPath: spec.methodPath,
            metadata: endpoint.shownMetadata,
            messages: messages,
            unresolvedVariables: templates.unresolved,
            scriptReport: session?.shownReport
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
        let currentValues = library.currentValues.snapshot(for: project)
        let redactions = document.allEnvironments.map { environment in
            let scope = VariableScope(
                global: library.globalEnvironment,
                document: document,
                activeEnvironmentID: environment.id,
                currentValues: currentValues,
                overrides: variableOverrides
            )
            return SecretRedaction(resolver: TemplateResolver(scope: scope, dynamic: dynamic))
        }
        return { text in redactions.reduce(text) { $1.apply($0) } }
    }
}
