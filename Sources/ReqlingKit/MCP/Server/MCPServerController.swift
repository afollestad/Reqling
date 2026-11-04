import Foundation
import MCP
import Observation

/// Runs the built-in MCP server while Settings has it on, at `http://127.0.0.1:<port>/mcp`, and reports whether it is
/// running or why it is not.
///
/// One SDK `Server` on one stateless transport serves every client. The SDK's own `initialize` handler refuses a
/// second client ("already initialized"), so this registers its own after `start`, which installs the defaults; the
/// server runs non-strict for the same reason, since its initialized flag never gets set.
@MainActor
@Observable
public final class MCPServerController {
    public enum Status: Equatable, Sendable {
        case stopped
        case starting
        case running(port: Int)
        case failed(String)
    }

    public private(set) var status: Status = .stopped
    /// The bearer token clients send; loaded from the Keychain on first use, so a launch with MCP off never reads it.
    public private(set) var token: String?

    public let dispatcher: MCPToolDispatcher

    /// What only the window can do; the app's root model sets itself here once it exists.
    public var host: (any MCPAppHost)? {
        get { context.host }
        set { context.host = newValue }
    }

    @ObservationIgnored private let context: MCPToolContext
    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let tokenStore: any MCPTokenStore
    @ObservationIgnored private let resources: MCPResources
    @ObservationIgnored private let version: String
    /// Maps the Settings port to the one to bind; tests bind port 0 so suites never collide.
    @ObservationIgnored private let bindPort: (Int) -> Int
    @ObservationIgnored private var running: RunningServer?
    @ObservationIgnored private var syncTask: Task<Void, Never>?
    @ObservationIgnored private var needsResync = false

    public init(
        context: MCPToolContext,
        settings: SettingsStore,
        tokenStore: any MCPTokenStore,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        bindPort: @escaping (Int) -> Int = { $0 }
    ) {
        dispatcher = MCPToolDispatcher(context: context, sleep: sleep)
        resources = MCPResources(context: context)
        self.context = context
        self.settings = settings
        self.tokenStore = tokenStore
        version = context.appInfo.version
        self.bindPort = bindPort
    }

    /// The endpoint clients connect to, for the setup commands Settings shows.
    public var endpoint: URL? {
        guard case .running(let port) = status else {
            return URL(string: "http://127.0.0.1:\(settings.settings.mcpPort)\(MCPHTTPListener.path)")
        }
        return URL(string: "http://127.0.0.1:\(port)\(MCPHTTPListener.path)")
    }

    // MARK: - Lifecycle

    /// Starts, stops, or restarts the server to match Settings. Transitions run one at a time; a change that lands
    /// during one runs again once it ends.
    public func sync() {
        guard syncTask == nil else {
            needsResync = true
            return
        }
        syncTask = Task { [weak self] in
            await self?.drainSyncs()
        }
    }

    /// Waits for the transitions `sync()` started, for callers that need the outcome.
    public func settled() async {
        while let task = syncTask {
            await task.value
        }
    }

    /// Stops the server, for quitting.
    public func shutDown() async {
        await settled()
        await stopServer()
        status = .stopped
    }

    /// Closes the port at once, for `applicationWillTerminate`, which cannot await; the process exit ends the rest.
    public func stopListening() {
        running?.listener.stop()
    }

    private func drainSyncs() async {
        repeat {
            needsResync = false
            await reconcile()
        } while needsResync
        syncTask = nil
    }

    private func reconcile() async {
        let wanted = settings.settings.mcpEnabled ? settings.settings.mcpPort : nil
        if let running, running.settingsPort == wanted {
            return
        }
        await stopServer()
        guard let wanted else {
            status = .stopped
            return
        }
        status = .starting
        do {
            let token = try loadToken()
            status = .running(port: try await startServer(settingsPort: wanted, token: token))
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    private func startServer(settingsPort: Int, token: String) async throws -> Int {
        let box = MCPTokenBox(token)
        let transport = StatelessHTTPServerTransport(validationPipeline: StandardValidationPipeline(validators: [
            OriginValidator.localhost(),
            MCPBearerTokenValidator(token: box),
            AcceptHeaderValidator(mode: .jsonOnly),
            ContentTypeValidator(),
            ProtocolVersionValidator()
        ]))
        let server = Server(
            name: MCPToolCatalog.serverName,
            version: version,
            title: "Reqling",
            instructions: MCPToolCatalog.instructions,
            capabilities: Self.capabilities,
            configuration: .default
        )
        try await server.start(transport: transport)
        await registerHandlers(on: server)
        let listener = MCPHTTPListener()
        let port: Int
        do {
            port = try await listener.start(port: bindPort(settingsPort), transport: transport, token: box) { [weak self, weak listener] reason in
                Task { @MainActor in
                    await self?.listenerStopped(listener, reason: reason)
                }
            }
        } catch {
            await server.stop()
            throw error
        }
        running = RunningServer(listener: listener, server: server, settingsPort: settingsPort, token: box)
        return port
    }

    private func stopServer() async {
        guard let running else {
            return
        }
        self.running = nil
        running.listener.stop()
        await running.server.stop()
    }

    /// Only for the listener still running: a late failure from one already replaced must not stop its successor.
    private func listenerStopped(_ listener: MCPHTTPListener?, reason: String) async {
        guard let listener, running?.listener === listener else {
            return
        }
        await stopServer()
        status = .failed(reason)
    }

    private static let capabilities = Server.Capabilities(
        resources: .init(subscribe: false, listChanged: false),
        tools: .init(listChanged: false)
    )

    private func registerHandlers(on server: Server) async {
        let dispatcher = dispatcher
        let resources = resources
        let info = Server.Info(name: MCPToolCatalog.serverName, version: version, title: "Reqling")
        let capabilities = Self.capabilities
        let instructions = MCPToolCatalog.instructions
        await server.withMethodHandler(Initialize.self) { parameters in
            let requested = parameters.protocolVersion
            return Initialize.Result(
                protocolVersion: Version.supported.contains(requested) ? requested : Version.latest,
                capabilities: capabilities,
                serverInfo: info,
                instructions: instructions
            )
        }
        await server.withMethodHandler(ListTools.self) { _ in
            ListTools.Result(tools: await dispatcher.definitions)
        }
        await server.withMethodHandler(CallTool.self) { parameters in
            let result = await dispatcher.call(parameters.name, arguments: parameters.arguments)
            return CallTool.Result(
                content: [.text(text: result.text, annotations: nil, _meta: nil)],
                structuredContent: result.structuredContent,
                isError: result.isError
            )
        }
        await server.withMethodHandler(ListResources.self) { _ in
            ListResources.Result(resources: await resources.list())
        }
        await server.withMethodHandler(ListResourceTemplates.self) { _ in
            ListResourceTemplates.Result(templates: MCPResources.templates)
        }
        await server.withMethodHandler(ReadResource.self) { parameters in
            try await resources.read(parameters.uri)
        }
    }

    // MARK: - Token

    /// The stored token, creating one the first time.
    @discardableResult
    public func loadToken() throws -> String {
        if let token {
            return token
        }
        let loaded = try tokenStore.loadOrCreate()
        token = loaded
        return loaded
    }

    /// Replaces the token; clients using the old one get 401 from their next request.
    public func regenerateToken() throws {
        let fresh = try MCPBearerToken.make()
        try tokenStore.save(fresh)
        token = fresh
        running?.token.value = fresh
    }
}

/// The server while it listens, with the Settings port it was started for, so a change of port restarts it.
private struct RunningServer {
    let listener: MCPHTTPListener
    let server: Server
    let settingsPort: Int
    let token: MCPTokenBox
}
