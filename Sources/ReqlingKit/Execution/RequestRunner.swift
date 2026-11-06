import Foundation
import Observation

/// Options for one run, mostly used by agents through MCP.
public struct RunOptions: Sendable {
    /// `nil` uses the project's active environment.
    public var environmentID: EnvironmentID?
    /// One-run values that beat every environment.
    public var variableOverrides: [String: String]
    /// Replaces the saved spec for this run only, such as with an extra header or other messages; the saved template is
    /// untouched. Its protocol must match the request's.
    public var spec: RequestKind?
    /// Send even when some `{{variables}}` cannot be resolved; they go out verbatim.
    public var allowUnresolved: Bool
    /// For client-streaming and bidirectional gRPC calls: leave the request stream open after the request's own
    /// messages, for `RequestRunner.sendMessage` and `endStream`. The editor sets it; agents and tests leave it off, so
    /// a call runs to completion unattended.
    public var keepsStreamOpen: Bool

    public init(
        environmentID: EnvironmentID? = nil,
        variableOverrides: [String: String] = [:],
        spec: RequestKind? = nil,
        allowUnresolved: Bool = false,
        keepsStreamOpen: Bool = false
    ) {
        self.environmentID = environmentID
        self.variableOverrides = variableOverrides
        self.spec = spec
        self.allowUnresolved = allowUnresolved
        self.keepsStreamOpen = keepsStreamOpen
    }

    /// Set by `RequestRunner.runUnsaved`: the request to run in place of a saved one. Its run is never recorded, so it
    /// neither shows in the window nor lands in the history.
    var unsaved: RequestItem?
}

/// One request in one project. Runs are tracked by this, never by request ID alone: a request file copied between
/// projects keeps its ID, and keying by that alone let sending one cancel the other and share its in-flight state.
public struct RunKey: Hashable, Sendable {
    public let projectID: ProjectID
    public let requestID: RequestNodeID

    public init(_ requestID: RequestNodeID, in projectID: ProjectID) {
        self.projectID = projectID
        self.requestID = requestID
    }
}

/// Runs saved requests: resolves them against the project and environment, sends them, and records each run in
/// `history`, keeping the latest exchange per request at hand. The UI and the MCP server share it, so a run started by
/// an agent shows up in the window.
@MainActor
@Observable
public final class RequestRunner {
    public internal(set) var inFlight: Set<RunKey> = []
    /// The latest exchange per run; an open gRPC call publishes partial ones (status still `nil`) as it goes.
    public internal(set) var latest: [RunKey: RequestExchange] = [:]
    /// gRPC calls whose request stream is open for `sendMessage`; `endStream` closes one.
    public internal(set) var openStreams: Set<RunKey> = []

    @ObservationIgnored let library: ProjectLibrary
    @ObservationIgnored let workspace: WorkspaceStateStore
    @ObservationIgnored let settings: SettingsStore
    @ObservationIgnored private let keychain: any KeychainIdentityStore
    /// Checks PKCS#12 files before they open; its first check of a file blocks `tlsContext` for one helper launch.
    @ObservationIgnored private let pkcs12Probe: any PKCS12ImportProbe
    /// Every recorded run. Only `record` adds to it; clearing goes through this runner too, so `latest` never shows a
    /// run its history no longer has.
    @ObservationIgnored public let history: RunHistory
    @ObservationIgnored private let userAgent: String
    @ObservationIgnored let dynamic: DynamicVariables
    @ObservationIgnored private let makeExecutor: @MainActor () -> HTTPExecutor
    /// `nil` only where gRPC is never run; its requests then fail with an explanation. Public so the editor's Refresh
    /// drops the same reflection cache runs use.
    @ObservationIgnored public let grpcSchemas: GRPCSchemaService?
    /// `nil` only where GraphQL schemas are never loaded; schema lookups then fail with an explanation.
    @ObservationIgnored public let graphQLSchemas: GraphQLSchemaService?
    @ObservationIgnored private var executors: [ProjectID: HTTPExecutor] = [:]
    @ObservationIgnored private var tasks: [RunKey: Task<RequestExchange, Never>] = [:]
    /// Each running gRPC call's timeline and outbox, by run. A run only touches its own entry (checked by identity),
    /// so a replaced or forgotten run's late events never reach the newer one.
    @ObservationIgnored var liveCalls: [RunKey: GRPCLiveCall] = [:]

    public init(
        library: ProjectLibrary,
        workspace: WorkspaceStateStore,
        settings: SettingsStore,
        keychain: any KeychainIdentityStore,
        pkcs12Probe: any PKCS12ImportProbe,
        history: RunHistory,
        userAgent: String,
        dynamic: DynamicVariables = .live,
        grpcSchemas: GRPCSchemaService? = nil,
        graphQLSchemas: GraphQLSchemaService? = nil,
        makeExecutor: @escaping @MainActor () -> HTTPExecutor = { HTTPExecutor() }
    ) {
        self.library = library
        self.workspace = workspace
        self.settings = settings
        self.keychain = keychain
        self.pkcs12Probe = pkcs12Probe
        self.history = history
        self.userAgent = userAgent
        self.dynamic = dynamic
        self.grpcSchemas = grpcSchemas
        self.graphQLSchemas = graphQLSchemas
        self.makeExecutor = makeExecutor
        history.onPrune = { [weak self] removal in
            self?.dropPruned(removal)
        }
    }

    /// The latest exchange: from this session, or else the newest in the history.
    public func exchange(for request: RequestNodeID, in project: ProjectID) -> RequestExchange? {
        let key = RunKey(request, in: project)
        if let exchange = latest[key] {
            return exchange
        }
        guard let stored = history.latest(for: request, in: project) else {
            return nil
        }
        latest[key] = stored
        return stored
    }

    /// Waits for every run still being written to the history. Call it before quitting, and in tests that read a run's
    /// files.
    public func flushHistory() {
        history.flush()
    }

    /// How the request's latest run went; `.notSent` when it has none on this Mac.
    public func outcome(for request: RequestNodeID, in project: ProjectID) -> RunOutcomeKind {
        history.outcome(for: request, in: project)
    }

    /// Builds an HTTP request exactly as a run would, without sending it; a gRPC request fails.
    public func prepare(
        _ request: RequestNodeID,
        in project: ProjectID,
        options: RunOptions = RunOptions()
    ) throws(RunFailure) -> PreparedHTTPRequest {
        try prepareRun(request, in: project, options: options).prepared
    }

    /// Runs a saved request and waits for the result. Starting a run of a request that is already in flight in the
    /// same project cancels the earlier one. Cancelling the task awaiting this cancels the run, even one cancelled
    /// before it started, which `cancel(_:in:)` cannot see yet.
    @discardableResult
    public func run(_ request: RequestNodeID, in project: ProjectID, options: RunOptions = RunOptions()) async -> RequestExchange {
        let key = RunKey(request, in: project)
        // Detach the earlier run before anything can fail, so its late completion can never overwrite this one.
        tasks.removeValue(forKey: key)?.cancel()
        inFlight.remove(key)
        liveCalls[key] = nil
        openStreams.remove(key)
        let item = item(request, in: project, options: options)
        let environment = library.document(project).flatMap { runEnvironment(in: $0, project: project, options: options) }
        let stamp = RunStamp(id: RunID(), startedAt: Date(), spec: item?.kind, environment: environment)
        let task: Task<RequestExchange, Never>
        if item?.kind.grpcSpec != nil {
            // Inside the task, unlike HTTP's preparation: finding the schema can compile protos or ask the server, so
            // it must count as in flight and be cancellable.
            task = Task { await self.runGRPC(request, in: project, options: options, id: stamp.id, startedAt: stamp.startedAt) }
        } else {
            let preparation: PreparedRun
            do {
                preparation = try prepareRun(request, in: project, options: options)
            } catch {
                let failed = stamp.applied(to: failedExchange(request, in: project, startedAt: stamp.startedAt, error))
                return options.unsaved == nil ? record(failed) : failed
            }
            task = httpTask(preparation, request: request, in: project, startedAt: stamp.startedAt)
        }
        tasks[key] = task
        inFlight.insert(key)
        // The run is an unstructured task, so it outlives a replaced caller; the caller's cancellation is forwarded.
        let exchange = stamp.applied(to: await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        })
        // A newer run may have replaced this one, or `forget` dropped it; only the current run publishes.
        guard tasks[key] == task else {
            return exchange
        }
        tasks[key] = nil
        inFlight.remove(key)
        return options.unsaved == nil ? record(exchange) : exchange
    }

    /// Runs `item` as though it were saved at the top of `project`, resolving against the project's environments and
    /// auth, without recording it: the window never shows the run and nothing reaches the history. `item.id` must not be
    /// a saved request's, or the two would share run tracking.
    public func runUnsaved(_ item: RequestItem, in project: ProjectID, options: RunOptions = RunOptions()) async -> RequestExchange {
        var options = options
        options.unsaved = item
        return await run(item.id, in: project, options: options)
    }

    /// The request a run sends: the unsaved one, or the saved one with any one-run spec in place of its own.
    func item(_ request: RequestNodeID, in project: ProjectID, options: RunOptions) -> RequestItem? {
        guard var item = options.unsaved ?? library.document(project)?.request(request) else {
            return nil
        }
        if let spec = options.spec {
            item.kind = spec
        }
        return item
    }

    func failedExchange(_ request: RequestNodeID, in project: ProjectID, startedAt: Date, _ failure: RunFailure) -> RequestExchange {
        RequestExchange(
            projectID: project,
            requestID: request,
            startedAt: startedAt,
            environmentName: nil,
            request: nil,
            outcome: .failure(failure)
        )
    }

    private func httpTask(
        _ preparation: PreparedRun,
        request: RequestNodeID,
        in project: ProjectID,
        startedAt: Date
    ) -> Task<RequestExchange, Never> {
        let executor = executor(for: project)
        return Task<RequestExchange, Never> {
            let outcome: RequestExchange.Outcome
            do {
                outcome = .response(try await executor.execute(preparation.prepared, tls: preparation.tls))
            } catch {
                outcome = .failure(Self.failure(for: error).redacting(preparation.prepared.redaction))
            }
            return RequestExchange(
                projectID: project,
                requestID: request,
                startedAt: startedAt,
                environmentName: preparation.environmentName,
                request: preparation.prepared.summary,
                outcome: outcome,
                unresolvedVariables: preparation.prepared.unresolvedVariables
            )
        }
    }

    public func isInFlight(_ request: RequestNodeID, in project: ProjectID) -> Bool {
        inFlight.contains(RunKey(request, in: project))
    }

    /// Cancels the run in flight; one whose task has not started yet is unaffected (cancel the task awaiting `run`).
    public func cancel(_ request: RequestNodeID, in project: ProjectID) {
        tasks[RunKey(request, in: project)]?.cancel()
    }

    /// Drops a project's cookies, connections, and history, as when it is deleted. Its runs in flight are cancelled and
    /// detached first, so none can finish afterwards and record into the history again.
    public func forget(_ project: ProjectID) {
        for key in tasks.keys where key.projectID == project {
            detach(key)
        }
        liveCalls = liveCalls.filter { $0.key.projectID != project }
        openStreams = openStreams.filter { $0.projectID != project }
        grpcSchemas?.refreshReflection(in: project)
        graphQLSchemas?.forget(project)
        executors.removeValue(forKey: project)?.invalidate()
        history.clear(in: project)
        latest = latest.filter { $0.key.projectID != project }
    }

    /// Drops one request's history, as when it is deleted or switches protocol and its runs no longer describe it. A
    /// run in flight is cancelled and detached first, so it cannot finish afterwards and record again.
    public func forget(_ request: RequestNodeID, in project: ProjectID) {
        let key = RunKey(request, in: project)
        detach(key)
        history.clear(for: request, in: project)
        latest[key] = nil
    }

    /// Cancels a run and forgets it is running, so it can never publish or record.
    func detach(_ key: RunKey) {
        tasks.removeValue(forKey: key)?.cancel()
        inFlight.remove(key)
        liveCalls[key] = nil
        openStreams.remove(key)
    }

    private struct PreparedRun {
        var prepared: PreparedHTTPRequest
        var tls: TLSContext
        var environmentName: String?
    }

    /// What every run of a request resolves against, whatever its kind.
    struct RunContext {
        let item: RequestItem
        let document: ProjectDocument
        let resolver: TemplateResolver
        /// Errors thrown before a prepared request exists are scrubbed with the same secrets it would carry.
        let redaction: SecretRedaction
        let paths: ProjectPathResolver
        let environmentName: String

        /// The project's auth followed by each enclosing folder's, outermost first.
        var authChain: [HTTPAuth] {
            [document.auth] + document.ancestors(of: item.id).map(\.auth)
        }
    }

    func runContext(_ request: RequestNodeID, in projectID: ProjectID, options: RunOptions) throws(RunFailure) -> RunContext {
        library.reloadSecretsIfUnread(for: projectID)
        guard let project = library.project(projectID), let document = project.document else {
            throw RunFailure(kind: .invalidRequest, message: "The project is not available.")
        }
        guard let item = item(request, in: projectID, options: options) else {
            throw RunFailure(kind: .invalidRequest, message: "The request no longer exists.")
        }
        if let saved = document.request(request), options.unsaved == nil, saved.kind.name != item.kind.name {
            throw RunFailure(kind: .invalidRequest, message: "A one-run spec must be \(saved.kind.name.rawValue), as the request is.")
        }
        guard let environment = runEnvironment(in: document, project: projectID, options: options) else {
            throw RunFailure(kind: .invalidRequest, message: "The environment no longer exists.")
        }
        let scope = VariableScope(
            global: library.globalEnvironment,
            document: document,
            activeEnvironmentID: environment.id,
            overrides: options.variableOverrides
        )
        let resolver = TemplateResolver(scope: scope, dynamic: dynamic)
        return RunContext(
            item: item,
            document: document,
            resolver: resolver,
            redaction: SecretRedaction(resolver: resolver),
            paths: ProjectPathResolver(projectRoot: project.url, localPaths: workspace.localPaths(in: projectID)),
            environmentName: environment.name
        )
    }

    /// The environment a run resolves against. One an agent or a re-run names must exist (`nil` otherwise); a stored
    /// selection whose environment was deleted (perhaps on another Mac) falls back to Default, as the window shows it.
    func runEnvironment(in document: ProjectDocument, project: ProjectID, options: RunOptions) -> RequestEnvironment? {
        if let explicit = options.environmentID {
            return document.environment(explicit)
        }
        return workspace.projectState(project).activeEnvironmentID.flatMap { document.environment($0) } ?? document.defaultEnvironment
    }

    private func prepareRun(_ request: RequestNodeID, in projectID: ProjectID, options: RunOptions) throws(RunFailure) -> PreparedRun {
        let context = try runContext(request, in: projectID, options: options)
        guard let spec = context.item.kind.httpSpec else {
            throw RunFailure(kind: .invalidRequest, message: "“\(context.item.name)” is a gRPC request; this works only with HTTP requests.")
        }
        let prepared = try preparedHTTP(spec, context: context, options: options)
        let tls = try tls(for: prepared, project: projectID, context: context)
        return PreparedRun(prepared: prepared, tls: tls, environmentName: context.environmentName)
    }

    /// An HTTP spec's request built as a run builds it: normalized, with templates and auth resolved, refusing
    /// unresolved variables unless `options` allows them.
    func preparedHTTP(_ spec: HTTPRequestSpec, context: RunContext, options: RunOptions) throws(RunFailure) -> PreparedHTTPRequest {
        let spec = spec.normalized()
        let buildContext = HTTPBuildContext(
            resolver: context.resolver,
            authChain: context.authChain,
            paths: context.paths,
            defaults: settings.settings.requestDefaults,
            userAgent: userAgent
        )
        let prepared: PreparedHTTPRequest
        do {
            prepared = try HTTPRequestBuilder.prepare(spec, context: buildContext)
        } catch {
            throw RunFailure(kind: .invalidRequest, message: error.localizedDescription).redacting(context.redaction)
        }
        if !options.allowUnresolved, !prepared.unresolvedVariables.isEmpty {
            throw RunFailure.undefinedVariables(prepared.unresolvedVariables)
        }
        return prepared
    }

    /// The certificates a prepared request uses: the project's CAs and the client certificate for its host.
    func tls(for prepared: PreparedHTTPRequest, project: ProjectID, context: RunContext) throws(RunFailure) -> TLSContext {
        let url = prepared.urlRequest.url
        do {
            return try tlsContext(
                host: url?.host ?? "",
                port: url?.port ?? (url?.scheme?.lowercased() == "https" ? 443 : 80),
                verifiesServer: prepared.verifyTLS,
                project: project,
                context: context
            )
        } catch {
            throw error.redacting(context.redaction)
        }
    }

    /// Snapshots what TLS needs off the main actor (passphrases and Keychain references), then loads the identity and
    /// CAs for `host` and `port`. HTTP and gRPC both build their context here, so one host gets the same certificates.
    func tlsContext(host: String, port: Int?, verifiesServer: Bool, project: ProjectID, context: RunContext) throws(RunFailure) -> TLSContext {
        let configuration = context.document.tls
        let entries = configuration.clientCertificates
        let passphrases = Dictionary(uniqueKeysWithValues: entries.compactMap { entry in
            library.certificatePassphrase(for: entry.id, in: project).map { (entry.id, $0) }
        })
        let references = Dictionary(uniqueKeysWithValues: entries.compactMap { entry in
            workspace.keychainIdentity(for: entry.id).map { (entry.id, $0) }
        })
        let resolver = ProjectTLSResolver(
            configuration: configuration,
            paths: context.paths,
            passphrase: { passphrases[$0] },
            keychainIdentityReference: { references[$0] },
            keychain: keychain,
            pkcs12Probe: pkcs12Probe
        )
        do {
            return try resolver.context(host: host, port: port, verifiesServer: verifiesServer)
        } catch {
            throw RunFailure(kind: .tls, message: error.localizedDescription)
        }
    }

    func executor(for project: ProjectID) -> HTTPExecutor {
        if let executor = executors[project] {
            return executor
        }
        let executor = makeExecutor()
        executors[project] = executor
        return executor
    }

    /// Publishes an exchange and adds it to the history, unless its project is gone: a deleted project must leave
    /// nothing on disk.
    func record(_ exchange: RequestExchange) -> RequestExchange {
        guard library.project(exchange.projectID) != nil else {
            return exchange
        }
        latest[RunKey(exchange.requestID, in: exchange.projectID)] = exchange
        history.record(exchange)
        return exchange
    }

    nonisolated static func failure(for error: any Error) -> RunFailure {
        switch error as? HTTPExecutionError {
        case .cancelled:
            RunFailure(kind: .cancelled, message: HTTPExecutionError.cancelled.localizedDescription)
        case .timedOut:
            RunFailure(kind: .timedOut, message: HTTPExecutionError.timedOut.localizedDescription)
        case .untrustedServer(let reason):
            RunFailure(kind: .tls, message: reason)
        case .transport(let message):
            RunFailure(kind: .transport, message: message)
        case nil:
            RunFailure(kind: .transport, message: error.localizedDescription)
        }
    }
}

/// What every exchange of one run carries, whichever path produced it: a failure before sending, a response, or a
/// gRPC call's partial and final records.
private struct RunStamp {
    let id: RunID
    let startedAt: Date
    let spec: RequestKind?
    /// `nil` when the project is gone or the environment named for the run no longer exists.
    let environment: RequestEnvironment?

    func applied(to exchange: RequestExchange) -> RequestExchange {
        var stamped = exchange
        stamped.id = id
        stamped.spec = spec
        if let environment {
            stamped.environmentID = environment.id
            stamped.environmentName = environment.name
        }
        return stamped
    }
}
