import Foundation
import Observation
import ReqlingScriptProtocol
import ReqlingTemplating

/// Runs saved requests: resolves them against the project and environment, sends them, and records each run in
/// `history`, keeping the latest exchange per request at hand. The UI and the MCP server share it, so a run started by
/// an agent shows up in the window.
@MainActor
@Observable
public final class RequestRunner {
    public internal(set) var inFlight: Set<RunKey> = []
    /// The latest exchange per run; an open gRPC call (status still `nil`) or event stream (`end` still `nil`)
    /// publishes partial ones as it goes.
    public internal(set) var latest: [RunKey: RequestExchange] = [:]
    /// gRPC calls whose request stream is open for `sendMessage`; `endStream` closes one.
    public internal(set) var openStreams: Set<RunKey> = []
    /// Requests whose response is an event stream still open, which Stop (`cancel`) ends.
    public internal(set) var eventStreams: Set<RunKey> = []
    /// WebSocket connections open for `sendWebSocketMessage` and `pingWebSocket`, which Disconnect (`cancel`) closes.
    public internal(set) var openSockets: Set<RunKey> = []
    /// The script phase each run is in, while its scripts run.
    public internal(set) var scriptPhases: [RunKey: ScriptPhase] = [:]
    /// Asks whether a project's scripts may run; the app sets it. Without one, a project not yet trusted runs without
    /// its scripts.
    @ObservationIgnored public weak var trustDecider: (any ScriptTrustDeciding)?

    @ObservationIgnored let library: ProjectLibrary
    @ObservationIgnored let workspace: WorkspaceStateStore
    @ObservationIgnored let settings: SettingsStore
    @ObservationIgnored let keychain: any KeychainIdentityStore
    /// Checks PKCS#12 files before they open; its first check of a file blocks `tlsContext` for one helper launch.
    @ObservationIgnored let pkcs12Probe: any PKCS12ImportProbe
    /// Every recorded run. Only `record` adds to it; clearing goes through this runner too, so `latest` never shows a
    /// run its history no longer has.
    @ObservationIgnored public let history: RunHistory
    @ObservationIgnored let userAgent: String
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
    /// Each HTTP run's event stream, by run, from the moment it is sent: identity-checked like `liveCalls`, and open
    /// only once its response turns out to be one.
    @ObservationIgnored var liveStreams: [RunKey: EventStreamLive] = [:]
    /// Each WebSocket run's connection, by run, from the moment it is sent: identity-checked like `liveCalls`, and in
    /// `openSockets` only once the server switches protocols.
    @ObservationIgnored var liveSockets: [RunKey: WebSocketLive] = [:]
    /// What each saved run in flight stamps its exchanges with, so `recordLiveRuns` can record one that never finishes;
    /// unsaved runs never record, so they have none.
    @ObservationIgnored var liveStamps: [RunKey: RunStamp] = [:]
    /// Waits out an event stream's reconnect delay and time limit, and times a WebSocket's handshake, keepalive, and
    /// close; tests inject one that needs no wall clock.
    @ObservationIgnored let sleep: @Sendable (Duration) async throws -> Void
    /// Runs scripts out of process (`HelperScriptRunner`).
    @ObservationIgnored let scripts: any ScriptRunning
    /// Each run's scripts, from its start until it is recorded; `recordLiveRuns` reports them for a run Reqling quits on.
    @ObservationIgnored var scriptSessions: [RunKey: ScriptSession] = [:]
    /// Each run's post-response phase while it runs. Not the run's own task, so Stop on an event stream, which cancels
    /// that, lets the scripts run on what arrived; `cancel` and `detach` stop it too.
    @ObservationIgnored var scriptTasks: [RunKey: Task<ScriptSession.PhaseOutcome, Never>] = [:]
    /// Each run's exchange from the moment its transport ends until the run is recorded, so a quit while its stream or
    /// post-response scripts finish, or before `run` takes it up, still records it (`recordLiveRuns`). Each transport
    /// sets it as it drops its live record, in the same turn, so no quit falls between them; `run` and `detach` clear it.
    @ObservationIgnored var pendingPostExchanges: [RunKey: RequestExchange] = [:]
    /// What recorded runs' scripts made secret, kept in memory only (`RequestRunner+Scripts`).
    @ObservationIgnored var scriptSecrets = ScriptSecretMemory()
    /// One trust question per project at a time, which every run waiting on it shares.
    @ObservationIgnored var trustPrompts: [ProjectID: TrustPrompt] = [:]
    /// The folder or project run step each run belongs to, while it runs, so `cancel` can tell the step it was stopped.
    @ObservationIgnored var batchSteps: [RunKey: BatchStepContext] = [:]

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
        scripts: any ScriptRunning,
        makeExecutor: @escaping @MainActor () -> HTTPExecutor = { HTTPExecutor() },
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
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
        self.scripts = scripts
        self.makeExecutor = makeExecutor
        self.sleep = sleep
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

    /// Builds an HTTP request exactly as a run would, its pre-request scripts included, without sending it; nothing the
    /// scripts set is kept. A gRPC or WebSocket request fails.
    public func prepare(
        _ request: RequestNodeID,
        in project: ProjectID,
        options: RunOptions = RunOptions()
    ) async throws(RunFailure) -> PreparedHTTPRequest {
        try await previewHTTP(request, in: project, options: options).prepared
    }

    /// `prepare`, with the report of the pre-request scripts it ran.
    func previewHTTP(
        _ request: RequestNodeID,
        in project: ProjectID,
        options: RunOptions
    ) async throws(RunFailure) -> (prepared: PreparedHTTPRequest, scriptReport: ScriptReport?) {
        // A request that isn't HTTP fails before any script runs.
        guard item(request, in: project, options: options)?.kind.httpSpec != nil else {
            return (try prepareRun(request, in: project, options: options).prepared, nil)
        }
        let session = try await previewScripts(request, in: project, options: options)
        return (try prepareRun(request, in: project, options: options, session: session).prepared, session?.shownReport)
    }

    /// Runs a saved request and waits for the result. Starting a run of a request that is already in flight in the
    /// same project cancels the earlier one. Cancelling the task awaiting this cancels the run, even one cancelled
    /// before it started, which `cancel(_:in:)` cannot see yet.
    @discardableResult
    public func run(_ request: RequestNodeID, in project: ProjectID, options: RunOptions = RunOptions()) async -> RequestExchange {
        let key = RunKey(request, in: project)
        // Detach the earlier run before anything can fail, so its late completion can never overwrite this one.
        detach(key)
        let item = item(request, in: project, options: options)
        let environment = library.document(project).flatMap { runEnvironment(in: $0, project: project, options: options) }
        let step = options.batchStep
        var stamp = RunStamp(id: RunID(), startedAt: Date(), spec: item?.kind, environment: environment)
        stamp.heldRunLocalSecrets = !(step?.carriedSecrets.isEmpty ?? true)
        beginBatchStep(step, key: key, run: stamp.id, options: options)
        defer { endBatchStep(step, key: key) }
        // Taken now, so editing a script while the run waits on its response never changes what runs.
        let session = item.flatMap { scriptSession(for: $0, in: project, options: options, mode: .run) }
        // Every kind runs its pre-request scripts and prepares inside its task, so both count as in flight and can be
        // cancelled; finding a gRPC schema can also compile protos or ask the server.
        let task: Task<RequestExchange, Never> = switch item?.kind {
        case .grpc:
            Task { await self.executeGRPC(key, options: options, stamp: stamp, session: session) }
        case .webSocket:
            Task { await self.executeWebSocket(key, options: options, stamp: stamp, session: session) }
        case .http, nil:
            Task { await self.executeHTTP(key, options: options, stamp: stamp, session: session) }
        }
        tasks[key] = task
        inFlight.insert(key)
        if options.unsaved == nil {
            liveStamps[key] = stamp
        }
        scriptSessions[key] = session
        // The run is an unstructured task, so it outlives a replaced caller; the caller's cancellation is forwarded.
        var exchange = stamp.applied(to: await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        })
        // A newer run may have replaced this one, or `forget` dropped it; only the current run publishes.
        guard tasks[key] == task else {
            return exchange
        }
        if let session {
            exchange = await finishScripts(exchange, key: key, session: session)
            guard tasks[key] == task else {
                return exchange
            }
            if options.unsaved == nil {
                scriptSecrets.remember(session.secretValues, for: exchange.id)
            }
        }
        finishBatchStep(step, session: session)
        tasks[key] = nil
        inFlight.remove(key)
        liveStamps[key] = nil
        scriptSessions[key] = nil
        pendingPostExchanges[key] = nil
        return options.unsaved == nil ? record(exchange, step: step) : exchange
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

    public func isInFlight(_ request: RequestNodeID, in project: ProjectID) -> Bool {
        inFlight.contains(RunKey(request, in: project))
    }

    /// Cancels the run in flight; one whose task has not started yet is unaffected (cancel the task awaiting `run`). An
    /// open WebSocket takes no more messages from here on, while its close handshake finishes.
    public func cancel(_ request: RequestNodeID, in project: ProjectID) {
        let key = RunKey(request, in: project)
        batchSteps[key]?.wasCancelled = true
        tasks[key]?.cancel()
        scriptTasks[key]?.cancel()
        // The stream scripts outlive the stream, finishing the call in hand before post-response scripts run.
        scriptSessions[key]?.closeStreamSending()
        scriptSessions[key]?.stopStream()
        liveSockets[key]?.isStopping = true
        openSockets.remove(key)
    }

    /// Drops a project's cookies, connections, and history, as when it is deleted. Its runs in flight are cancelled and
    /// detached first, so none can finish afterwards and record into the history again.
    public func forget(_ project: ProjectID) {
        for key in tasks.keys where key.projectID == project {
            detach(key)
        }
        dropLive(in: project)
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

    /// Cancels a run and forgets it is running, so it can never publish or record. `cancels: false` leaves it running
    /// unwatched, as a WebSocket closing with its own code must.
    func detach(_ key: RunKey, cancels: Bool = true) {
        let task = tasks.removeValue(forKey: key)
        if cancels {
            task?.cancel()
        }
        scriptTasks.removeValue(forKey: key)?.cancel()
        scriptSessions.removeValue(forKey: key)?.cancelStream()
        pendingPostExchanges[key] = nil
        scriptPhases[key] = nil
        inFlight.remove(key)
        dropLive(key)
    }

    struct PreparedRun {
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

    /// `session`, when the run has scripts, supplies the variables and request changes they left.
    func runContext(
        _ request: RequestNodeID,
        in projectID: ProjectID,
        options: RunOptions,
        session: ScriptSession? = nil
    ) throws(RunFailure) -> RunContext {
        library.reloadSecretsIfUnread(for: projectID)
        guard let project = library.project(projectID), let document = project.document else {
            throw RunFailure(kind: .invalidRequest, message: "The project is not available.")
        }
        guard var item = item(request, in: projectID, options: options) else {
            throw RunFailure(kind: .invalidRequest, message: "The request no longer exists.")
        }
        if let saved = document.request(request), options.unsaved == nil, saved.kind.name != item.kind.name {
            throw RunFailure(kind: .invalidRequest, message: "A one-run spec must be \(saved.kind.name.rawValue), as the request is.")
        }
        guard let environment = runEnvironment(in: document, project: projectID, options: options) else {
            throw RunFailure(kind: .invalidRequest, message: "The environment no longer exists.")
        }
        let step = options.batchStep
        let scope = session?.scope ?? VariableScope(
            global: library.globalEnvironment,
            document: document,
            activeEnvironmentID: environment.id,
            currentValues: library.currentValues.snapshot(for: projectID),
            overrides: options.variableOverrides,
            iterationData: step?.iterationData ?? [:],
            locals: step?.locals ?? [:]
        )
        let resolver = TemplateResolver(scope: scope, dynamic: dynamic)
        var redaction = SecretRedaction(resolver: resolver)
        // A secret an earlier step made and unset is in no scope any more, yet may still be what a server echoes.
        let carried = session?.allSecretValues ?? step?.carriedSecrets ?? []
        if session != nil || !carried.isEmpty {
            if let session {
                item.kind = session.kind
            }
            redaction = Self.redaction(scope: scope, resolver: resolver, carried: carried)
        }
        return RunContext(
            item: item,
            document: document,
            resolver: resolver,
            redaction: redaction,
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

    func prepareRun(
        _ request: RequestNodeID,
        in projectID: ProjectID,
        options: RunOptions,
        session: ScriptSession? = nil
    ) throws(RunFailure) -> PreparedRun {
        let context = try runContext(request, in: projectID, options: options, session: session)
        guard let spec = context.item.kind.httpSpec else {
            let kind = context.item.kind.name.title
            throw RunFailure(kind: .invalidRequest, message: "“\(context.item.name)” is a \(kind) request; this works only with HTTP requests.")
        }
        var prepared = try preparedHTTP(spec, context: context, options: options)
        if let session {
            prepared.markScriptChanges(session.changes, redaction: context.redaction)
        }
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

    func executor(for project: ProjectID) -> HTTPExecutor {
        if let executor = executors[project] {
            return executor
        }
        let executor = makeExecutor()
        executors[project] = executor
        return executor
    }

    /// `nil` once the library has dropped the project, so changes landing after `forget` never bring its executor
    /// back. `creating: false` never makes one: a project that has sent nothing has no cookies to read.
    func cookieJar(for project: ProjectID, creating: Bool) -> ProjectCookieJar? {
        guard library.project(project) != nil, let executor = creating ? executor(for: project) : executors[project] else {
            return nil
        }
        return executor.cookies.map(ProjectCookieJar.init)
    }

    /// Publishes an exchange and adds it to the history, unless its project is gone: a deleted project must leave
    /// nothing on disk. A folder or project run's `step` learns its run reached the history.
    func record(_ exchange: RequestExchange, step: BatchStepContext? = nil) -> RequestExchange {
        guard library.project(exchange.projectID) != nil else {
            return exchange
        }
        step?.wasRecorded = true
        latest[RunKey(exchange.requestID, in: exchange.projectID)] = exchange
        history.record(exchange)
        return exchange
    }
}
