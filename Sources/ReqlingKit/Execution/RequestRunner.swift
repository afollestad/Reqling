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

    public init(
        environmentID: EnvironmentID? = nil,
        variableOverrides: [String: String] = [:],
        specOverride: (@Sendable (inout HTTPRequestSpec) -> Void)? = nil,
        allowUnresolved: Bool = false
    ) {
        self.environmentID = environmentID
        self.variableOverrides = variableOverrides
        self.specOverride = specOverride
        self.allowUnresolved = allowUnresolved
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
    public private(set) var inFlight: Set<RunKey> = []
    public private(set) var latest: [RunKey: RequestExchange] = [:]
    /// Bumped whenever any request's outcome changes; `outcome(for:in:)` reads it so views re-filter.
    public private(set) var outcomeRevision = 0

    @ObservationIgnored private let library: ProjectLibrary
    @ObservationIgnored private let workspace: WorkspaceStateStore
    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let keychain: any KeychainIdentityStore
    @ObservationIgnored private let cache: ResponseCache
    @ObservationIgnored private let userAgent: String
    @ObservationIgnored private let dynamic: DynamicVariables
    @ObservationIgnored private let makeExecutor: @MainActor () -> HTTPExecutor
    @ObservationIgnored private var executors: [ProjectID: HTTPExecutor] = [:]
    @ObservationIgnored private var tasks: [RunKey: Task<RequestExchange, Never>] = [:]
    /// Per-project outcomes, loaded from the cache's index on first use.
    @ObservationIgnored private var outcomes: [ProjectID: [RequestNodeID: RunOutcomeKind]] = [:]

    public init(
        library: ProjectLibrary,
        workspace: WorkspaceStateStore,
        settings: SettingsStore,
        keychain: any KeychainIdentityStore,
        cache: ResponseCache,
        userAgent: String,
        dynamic: DynamicVariables = .live,
        makeExecutor: @escaping @MainActor () -> HTTPExecutor = { HTTPExecutor() }
    ) {
        self.library = library
        self.workspace = workspace
        self.settings = settings
        self.keychain = keychain
        self.cache = cache
        self.userAgent = userAgent
        self.dynamic = dynamic
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

    /// Builds the request exactly as a run would, without sending it.
    public func prepare(
        _ request: RequestNodeID,
        in project: ProjectID,
        options: RunOptions = RunOptions()
    ) throws(RunFailure) -> PreparedHTTPRequest {
        try prepareRun(request, in: project, options: options).prepared
    }

    /// Runs a saved request and waits for the result. Starting a run of a request that is already in flight in the
    /// same project cancels the earlier one.
    @discardableResult
    public func run(_ request: RequestNodeID, in project: ProjectID, options: RunOptions = RunOptions()) async -> RequestExchange {
        let key = RunKey(request, in: project)
        // Detach the earlier run before anything can fail, so its late completion can never overwrite this one.
        tasks.removeValue(forKey: key)?.cancel()
        inFlight.remove(key)
        let startedAt = Date()
        let preparation: PreparedRun
        do {
            preparation = try prepareRun(request, in: project, options: options)
        } catch {
            return record(RequestExchange(
                projectID: project,
                requestID: request,
                startedAt: startedAt,
                environmentName: nil,
                request: nil,
                outcome: .failure(error)
            ))
        }
        let executor = executor(for: project)
        let task = Task<RequestExchange, Never> {
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
        tasks[key] = task
        inFlight.insert(key)
        let exchange = await task.value
        // A newer run may have replaced this one, or `forget` dropped it; only the current run publishes.
        guard tasks[key] == task else {
            return exchange
        }
        tasks[key] = nil
        inFlight.remove(key)
        return record(exchange)
    }

    public func isInFlight(_ request: RequestNodeID, in project: ProjectID) -> Bool {
        inFlight.contains(RunKey(request, in: project))
    }

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

    private func prepareRun(_ request: RequestNodeID, in projectID: ProjectID, options: RunOptions) throws(RunFailure) -> PreparedRun {
        guard let project = library.project(projectID), let document = project.document else {
            throw RunFailure(kind: .invalidRequest, message: "The project is not available.")
        }
        guard let item = document.request(request), var spec = item.kind.httpSpec else {
            throw RunFailure(kind: .invalidRequest, message: "The request no longer exists.")
        }
        spec = spec.normalized()
        options.specOverride?(&spec)

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
        // Errors thrown before a prepared request exists are scrubbed with the same secrets it would carry.
        let redaction = SecretRedaction(resolver: resolver)
        let localPaths = Dictionary(uniqueKeysWithValues: workspace.state.localPaths.compactMap { key, value in
            LocalPathID(string: key).map { ($0, value) }
        })
        let paths = ProjectPathResolver(projectRoot: project.url, localPaths: localPaths)
        let context = HTTPBuildContext(
            resolver: resolver,
            authChain: [document.auth] + document.ancestors(of: request).map(\.auth),
            paths: paths,
            defaults: settings.settings.requestDefaults,
            userAgent: userAgent
        )
        let prepared: PreparedHTTPRequest
        do {
            prepared = try HTTPRequestBuilder.prepare(spec, context: context)
        } catch {
            throw RunFailure(kind: .invalidRequest, message: error.localizedDescription).redacting(redaction)
        }
        if !options.allowUnresolved, !prepared.unresolvedVariables.isEmpty {
            let names = prepared.unresolvedVariables.map { "{{\($0)}}" }.joined(separator: ", ")
            throw RunFailure(kind: .invalidRequest, message: "Undefined variables: \(names). Define them in an environment, or remove them.")
        }

        let tls: TLSContext
        do {
            tls = try tlsContext(for: prepared, project: projectID, configuration: document.tls, paths: paths)
        } catch {
            throw error.redacting(redaction)
        }
        let environmentName = environmentID.flatMap { document.environment($0)?.name } ?? RequestEnvironment.defaultName
        return PreparedRun(prepared: prepared, tls: tls, environmentName: environmentName)
    }

    /// Snapshots what the TLS delegate may need off the main actor (passphrases and Keychain references), then loads
    /// the identity and CAs for the request's host.
    private func tlsContext(
        for prepared: PreparedHTTPRequest,
        project: ProjectID,
        configuration: ProjectTLSConfiguration,
        paths: ProjectPathResolver
    ) throws(RunFailure) -> TLSContext {
        let entries = configuration.clientCertificates
        let passphrases = Dictionary(uniqueKeysWithValues: entries.compactMap { entry in
            library.certificatePassphrase(for: entry.id, in: project).map { (entry.id, $0) }
        })
        let references = Dictionary(uniqueKeysWithValues: entries.compactMap { entry in
            workspace.keychainIdentity(for: entry.id).map { (entry.id, $0) }
        })
        let resolver = ProjectTLSResolver(
            configuration: configuration,
            paths: paths,
            passphrase: { passphrases[$0] },
            keychainIdentityReference: { references[$0] },
            keychain: keychain
        )
        let url = prepared.urlRequest.url
        let port = url?.port ?? (url?.scheme?.lowercased() == "https" ? 443 : 80)
        do {
            return try resolver.context(host: url?.host ?? "", port: port, verifiesServer: prepared.verifyTLS)
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
    private func record(_ exchange: RequestExchange) -> RequestExchange {
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
