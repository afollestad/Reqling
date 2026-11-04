import Foundation
import Observation

/// Options for one run, mostly used by agents through MCP.
public struct RunOptions: Sendable {
    /// `nil` uses the project's active environment.
    public var environmentID: EnvironmentID?
    /// One-run values that beat every environment.
    public var variableOverrides: [String: String]
    /// One-run edits to the spec, such as an extra header; the saved template is untouched.
    public var specOverride: (@Sendable (inout HTTPRequestSpec) -> Void)?
    /// Send even when some `{{variables}}` cannot be resolved; they go out verbatim.
    public var allowUnresolved: Bool
    /// For client-streaming and bidirectional gRPC calls: leave the request stream open after the request's own
    /// messages, for `RequestRunner.sendMessage` and `endStream`. The editor sets it; agents and tests leave it off, so
    /// a call runs to completion unattended.
    public var keepsStreamOpen: Bool

    public init(
        environmentID: EnvironmentID? = nil,
        variableOverrides: [String: String] = [:],
        specOverride: (@Sendable (inout HTTPRequestSpec) -> Void)? = nil,
        allowUnresolved: Bool = false,
        keepsStreamOpen: Bool = false
    ) {
        self.environmentID = environmentID
        self.variableOverrides = variableOverrides
        self.specOverride = specOverride
        self.allowUnresolved = allowUnresolved
        self.keepsStreamOpen = keepsStreamOpen
    }
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

/// Runs saved requests: resolves them against the project and environment, sends them, and records the latest
/// exchange per request. The UI and the MCP server share it, so a run started by an agent shows up in the window.
@MainActor
@Observable
public final class RequestRunner {
    public internal(set) var inFlight: Set<RunKey> = []
    /// The latest exchange per run; an open gRPC call publishes partial ones (status still `nil`) as it goes.
    public internal(set) var latest: [RunKey: RequestExchange] = [:]
    /// Bumped whenever any request's outcome changes; `outcome(for:in:)` reads it so views re-filter.
    public private(set) var outcomeRevision = 0
    /// gRPC calls whose request stream is open for `sendMessage`; `endStream` closes one.
    public internal(set) var openStreams: Set<RunKey> = []

    @ObservationIgnored let library: ProjectLibrary
    @ObservationIgnored let workspace: WorkspaceStateStore
    @ObservationIgnored let settings: SettingsStore
    @ObservationIgnored private let keychain: any KeychainIdentityStore
    @ObservationIgnored private let cache: ResponseCache
    @ObservationIgnored private let userAgent: String
    @ObservationIgnored private let dynamic: DynamicVariables
    @ObservationIgnored private let makeExecutor: @MainActor () -> HTTPExecutor
    /// `nil` only where gRPC is never run; its requests then fail with an explanation. Public so the editor's Refresh
    /// drops the same reflection cache runs use.
    @ObservationIgnored public let grpcSchemas: GRPCSchemaService?
    @ObservationIgnored private var executors: [ProjectID: HTTPExecutor] = [:]
    @ObservationIgnored private var tasks: [RunKey: Task<RequestExchange, Never>] = [:]
    /// Per-project outcomes, loaded from the cache's index on first use.
    @ObservationIgnored private var outcomes: [ProjectID: [RequestNodeID: RunOutcomeKind]] = [:]
    /// Each running gRPC call's timeline and outbox, by run. A run only touches its own entry (checked by identity),
    /// so a replaced or forgotten run's late events never reach the newer one.
    @ObservationIgnored var liveCalls: [RunKey: GRPCLiveCall] = [:]

    public init(
        library: ProjectLibrary,
        workspace: WorkspaceStateStore,
        settings: SettingsStore,
        keychain: any KeychainIdentityStore,
        cache: ResponseCache,
        userAgent: String,
        dynamic: DynamicVariables = .live,
        grpcSchemas: GRPCSchemaService? = nil,
        makeExecutor: @escaping @MainActor () -> HTTPExecutor = { HTTPExecutor() }
    ) {
        self.library = library
        self.workspace = workspace
        self.settings = settings
        self.keychain = keychain
        self.cache = cache
        self.userAgent = userAgent
        self.dynamic = dynamic
        self.grpcSchemas = grpcSchemas
        self.makeExecutor = makeExecutor
    }

    /// The latest exchange: from this session, or else the one cached on disk.
    public func exchange(for request: RequestNodeID, in project: ProjectID) -> RequestExchange? {
        let key = RunKey(request, in: project)
        if let exchange = latest[key] {
            return exchange
        }
        guard let cached = cache.load(request, in: project) else {
            return nil
        }
        latest[key] = cached
        return cached
    }

    /// How the request's latest run went; `.notSent` when it has never run on this Mac.
    public func outcome(for request: RequestNodeID, in project: ProjectID) -> RunOutcomeKind {
        _ = outcomeRevision
        if outcomes[project] == nil {
            outcomes[project] = cache.outcomes(in: project)
        }
        return outcomes[project]?[request] ?? .notSent
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
        let startedAt = Date()
        let task: Task<RequestExchange, Never>
        if library.document(project)?.request(request)?.kind.grpcSpec != nil {
            // Inside the task, unlike HTTP's preparation: finding the schema can compile protos or ask the server, so
            // it must count as in flight and be cancellable.
            task = Task { await self.runGRPC(request, in: project, options: options, startedAt: startedAt) }
        } else {
            let preparation: PreparedRun
            do {
                preparation = try prepareRun(request, in: project, options: options)
            } catch {
                return record(failedExchange(request, in: project, startedAt: startedAt, error))
            }
            task = httpTask(preparation, request: request, in: project, startedAt: startedAt)
        }
        tasks[key] = task
        inFlight.insert(key)
        // The run is an unstructured task, so it outlives a replaced caller; the caller's cancellation is forwarded.
        let exchange = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        // A newer run may have replaced this one, or `forget` dropped it; only the current run publishes.
        guard tasks[key] == task else {
            return exchange
        }
        tasks[key] = nil
        inFlight.remove(key)
        return record(exchange)
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

    /// Drops a project's cookies, connections, and cached exchanges, as when it is deleted. Its runs in flight are
    /// cancelled and detached first, so none can finish afterwards and write the cache back.
    public func forget(_ project: ProjectID) {
        for (key, task) in tasks where key.projectID == project {
            task.cancel()
            tasks[key] = nil
            inFlight.remove(key)
        }
        liveCalls = liveCalls.filter { $0.key.projectID != project }
        openStreams = openStreams.filter { $0.projectID != project }
        grpcSchemas?.refreshReflection(in: project)
        executors.removeValue(forKey: project)?.invalidate()
        cache.removeAll(in: project)
        latest = latest.filter { $0.key.projectID != project }
        outcomes[project] = nil
        outcomeRevision += 1
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
        guard let project = library.project(projectID), let document = project.document else {
            throw RunFailure(kind: .invalidRequest, message: "The project is not available.")
        }
        guard let item = document.request(request) else {
            throw RunFailure(kind: .invalidRequest, message: "The request no longer exists.")
        }
        // An environment an agent names must exist; a stored selection whose environment was deleted (perhaps on
        // another Mac) falls back to Default, as the window shows it.
        let environmentID: EnvironmentID?
        if let explicit = options.environmentID {
            guard document.environment(explicit) != nil else {
                throw RunFailure(kind: .invalidRequest, message: "The environment no longer exists.")
            }
            environmentID = explicit
        } else {
            environmentID = workspace.projectState(projectID).activeEnvironmentID.flatMap { document.environment($0)?.id }
        }
        let scope = VariableScope(document: document, activeEnvironmentID: environmentID, overrides: options.variableOverrides)
        let resolver = TemplateResolver(scope: scope, dynamic: dynamic)
        let localPaths = Dictionary(uniqueKeysWithValues: workspace.state.localPaths.compactMap { key, value in
            LocalPathID(string: key).map { ($0, value) }
        })
        return RunContext(
            item: item,
            document: document,
            resolver: resolver,
            redaction: SecretRedaction(resolver: resolver),
            paths: ProjectPathResolver(projectRoot: project.url, localPaths: localPaths),
            environmentName: environmentID.flatMap { document.environment($0)?.name } ?? RequestEnvironment.defaultName
        )
    }

    private func prepareRun(_ request: RequestNodeID, in projectID: ProjectID, options: RunOptions) throws(RunFailure) -> PreparedRun {
        let context = try runContext(request, in: projectID, options: options)
        guard var spec = context.item.kind.httpSpec else {
            throw RunFailure(kind: .invalidRequest, message: "“\(context.item.name)” is a gRPC request; this works only with HTTP requests.")
        }
        spec = spec.normalized()
        options.specOverride?(&spec)
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
        let url = prepared.urlRequest.url
        let tls: TLSContext
        do {
            tls = try tlsContext(
                host: url?.host ?? "",
                port: url?.port ?? (url?.scheme?.lowercased() == "https" ? 443 : 80),
                verifiesServer: prepared.verifyTLS,
                project: projectID,
                context: context
            )
        } catch {
            throw error.redacting(context.redaction)
        }
        return PreparedRun(prepared: prepared, tls: tls, environmentName: context.environmentName)
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
            keychain: keychain
        )
        do {
            return try resolver.context(host: host, port: port, verifiesServer: verifiesServer)
        } catch {
            throw RunFailure(kind: .tls, message: error.localizedDescription)
        }
    }

    private func executor(for project: ProjectID) -> HTTPExecutor {
        if let executor = executors[project] {
            return executor
        }
        let executor = makeExecutor()
        executors[project] = executor
        return executor
    }

    /// Publishes and caches an exchange, unless its project is gone: a deleted project must leave nothing on disk.
    func record(_ exchange: RequestExchange) -> RequestExchange {
        guard library.project(exchange.projectID) != nil else {
            return exchange
        }
        latest[RunKey(exchange.requestID, in: exchange.projectID)] = exchange
        cache.save(exchange)
        if outcomes[exchange.projectID] == nil {
            outcomes[exchange.projectID] = cache.outcomes(in: exchange.projectID)
        }
        outcomes[exchange.projectID]?[exchange.requestID] = exchange.outcomeKind
        outcomeRevision += 1
        return exchange
    }

    nonisolated private static func failure(for error: any Error) -> RunFailure {
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
