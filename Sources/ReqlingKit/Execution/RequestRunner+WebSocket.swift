import Foundation
import ReqlingScriptProtocol

/// WebSocket runs: the same entry points, history, and outcome tracking as the other kinds (`run`, `cancel`, `forget`),
/// plus sending and pinging while a connection is open. The handshake is built as an HTTP GET (`preparedHTTP`), so
/// auth, `{{variables}}`, and masking are HTTP's; it shares the project's cookie jar (`HTTPExecutor.cookies`) and
/// certificates (`tlsContext`). Disconnect is `cancel`, which closes with 1000.
///
/// An open connection keeps what it connected with, except its keepalive: a change to the request's saved keepalive
/// applies at once (`followSavedKeepalive`), so a server that drops quiet connections can be kept talking without
/// reconnecting.
extension RequestRunner {
    /// Sends `message` on the open connection of `request`, resolved against the run's environment. Fails when no
    /// connection is open, or the message can't be resolved or encoded.
    public func sendWebSocketMessage(_ message: WebSocketMessage, to request: RequestNodeID, in project: ProjectID) throws(RunFailure) {
        try openSocket(request, in: project).send(message)
    }

    /// Pings the open connection of `request`; its pong shows on the timeline with the round trip.
    public func pingWebSocket(_ request: RequestNodeID, in project: ProjectID) throws(RunFailure) {
        try openSocket(request, in: project).ping()
    }

    private func openSocket(_ request: RequestNodeID, in project: ProjectID) throws(RunFailure) -> WebSocketLive {
        let key = RunKey(request, in: project)
        guard let live = liveSockets[key], openSockets.contains(key) else {
            throw RunFailure(kind: .invalidRequest, message: "The connection isn't open.")
        }
        return live
    }

    /// A WebSocket run ready to connect, everything resolved.
    struct PreparedWebSocket {
        let connect: WebSocketConnectRequest
        /// The handshake as sent, masked.
        let summary: ResolvedHTTPRequest
        let seeds: [EncodedWebSocketMessage]
        let unresolvedVariables: [String]
        let environmentName: String
        let resolver: TemplateResolver
        let redaction: SecretRedaction
    }

    /// The whole of a WebSocket run, inside the run's task so `cancel` and `forget` reach every await: its pre-request
    /// scripts, preparing the handshake with what they left, and the connection until it closes.
    func executeWebSocket(_ key: RunKey, options: RunOptions, stamp: RunStamp, session: ScriptSession?) async -> RequestExchange {
        let request = key.requestID
        let project = key.projectID
        if let session, let failure = await runPreRequestScripts(session, key: key, options: options) {
            return failedExchange(request, in: project, startedAt: stamp.startedAt, failure)
        }
        // A newer run replaced this one while its scripts ran; it must not take the newer run's place.
        guard !Task.isCancelled else {
            return failedExchange(request, in: project, startedAt: stamp.startedAt, Self.failure(for: HTTPExecutionError.cancelled))
        }
        let preparation: PreparedWebSocket
        do {
            preparation = try prepareWebSocket(request, in: project, options: options, session: session)
        } catch {
            return failedExchange(request, in: project, startedAt: stamp.startedAt, error)
        }
        return await connectWebSocket(preparation, key: key, options: options, stamp: stamp, session: session)
    }

    /// Resolves the handshake and the on-connect messages, failing before any network use on unresolved names, a URL
    /// a WebSocket can't use, or a message that can't be encoded, as HTTP fails before sending.
    func prepareWebSocket(
        _ request: RequestNodeID,
        in project: ProjectID,
        options: RunOptions,
        session: ScriptSession?
    ) throws(RunFailure) -> PreparedWebSocket {
        let context = try runContext(request, in: project, options: options, session: session)
        do throws(RunFailure) {
            guard let spec = context.item.kind.webSocketSpec?.normalized() else {
                throw RunFailure(kind: .invalidRequest, message: "“\(context.item.name)” is not a WebSocket request.")
            }
            var prepared = try preparedHTTP(spec.handshake, context: context, options: options)
            if let session {
                prepared.markScriptChanges(session.changes, redaction: context.redaction)
            }
            var handshake = prepared.urlRequest
            handshake.url = try Self.webSocketURL(handshake.url)
            var summary = prepared.summary
            summary.url = Self.webSocketURL(shown: summary.url)
            let tls = handshake.url?.scheme == "wss" ? try tlsContext(
                host: handshake.url?.host(percentEncoded: false) ?? "",
                port: handshake.url?.port ?? 443,
                verifiesServer: prepared.verifyTLS,
                project: project,
                context: context
            ) : nil
            var templates = RunTemplates(resolver: context.resolver)
            var seeds: [EncodedWebSocketMessage] = []
            for (index, message) in spec.messages.enumerated() where message.sendsOnConnect {
                seeds.append(try WebSocketLive.encode(message, templates: &templates, label: "Message \(index + 1)"))
            }
            if !options.allowUnresolved, !templates.unresolved.isEmpty {
                throw RunFailure.undefinedVariables(templates.unresolved)
            }
            return PreparedWebSocket(
                connect: WebSocketConnectRequest(
                    handshake: handshake,
                    shownURL: summary.url,
                    subprotocols: Self.offeredSubprotocols(handshake),
                    tls: tls,
                    cookies: executor(for: project).cookies,
                    keepalive: Self.keepalive(seconds: spec.options.keepaliveSeconds)
                ),
                summary: summary,
                seeds: seeds,
                unresolvedVariables: prepared.unresolvedVariables + templates.unresolved.filter { !prepared.unresolvedVariables.contains($0) },
                environmentName: context.environmentName,
                resolver: context.resolver,
                redaction: context.redaction
            )
        } catch {
            throw error.redacting(context.redaction)
        }
    }

    /// What the handshake offers, typed or from the subprotocols list: the server's choice must be among them.
    private static func offeredSubprotocols(_ handshake: URLRequest) -> [String] {
        (handshake.value(forHTTPHeaderField: "Sec-WebSocket-Protocol") ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private func connectWebSocket(
        _ preparation: PreparedWebSocket,
        key: RunKey,
        options: RunOptions,
        stamp: RunStamp,
        session: ScriptSession?
    ) async -> RequestExchange {
        let live = WebSocketLive(
            context: WebSocketLive.Context(
                runID: stamp.id,
                projectID: key.projectID,
                requestID: key.requestID,
                startedAt: stamp.startedAt,
                environmentName: preparation.environmentName,
                request: preparation.summary,
                unresolvedVariables: preparation.unresolvedVariables,
                resolver: preparation.resolver,
                redaction: preparation.redaction,
                allowUnresolved: options.allowUnresolved,
                limit: options.streamLimit,
                scripts: session
            ),
            seeds: preparation.seeds
        )
        liveSockets[key] = live
        let publishes = options.unsaved == nil
        if publishes {
            latest[key] = live.exchange
            followSavedKeepalive(key, on: live)
        }
        let outcome = await WebSocketExecutor(sleep: sleep).execute(preparation.connect, outbox: live.outbox) { event in
            await self.receive(event, on: live, key: key, publishes: publishes, session: session)
        }
        session?.closeStreamSending()
        let exchange = live.finished(outcome, stopped: Task.isCancelled)
        if liveSockets[key] === live {
            liveSockets[key] = nil
            openSockets.remove(key)
            pendingPostExchanges[key] = exchange
        }
        return exchange
    }

    /// `publishes` is false for an unsaved run, which records its events without showing them.
    private func receive(_ event: WebSocketEvent, on live: WebSocketLive, key: RunKey, publishes: Bool, session: ScriptSession?) {
        // A replaced or forgotten run keeps going until its cancellation lands; it must not publish.
        guard liveSockets[key] === live else {
            return
        }
        let wasOpen = live.isOpen
        let wasAtLimit = live.reachedLimit
        let received = live.apply(event)
        if !wasOpen, live.isOpen {
            if publishes, !live.isStopping {
                openSockets.insert(key)
            }
            if case .opened(let head, let subprotocol, _) = event {
                let opening = ScriptInputBuilder.opening(webSocket: head, subprotocol: subprotocol)
                startStreamScripts(session, on: live, key: key, publishes: publishes, opening: opening)
            }
            if let maxDuration = live.context.limit?.maxDuration {
                let sleep = self.sleep
                live.limitTimer = Task { [weak live] in
                    guard (try? await sleep(maxDuration)) != nil else {
                        return
                    }
                    live?.stopAtLimit()
                }
            }
        }
        if let session {
            feedStreamScripts(session, received, from: live, wasAtLimit: wasAtLimit)
        }
        if let maxEvents = live.context.limit?.maxEvents, live.receivedCount >= maxEvents {
            live.stopAtLimit()
        }
        if live.reachedLimit {
            openSockets.remove(key)
        }
        if publishes {
            publishThrottled(live, key: key) { [weak self] in self?.liveSockets[key] === live }
        }
    }

    private func startStreamScripts(_ session: ScriptSession?, on live: WebSocketLive, key: RunKey, publishes: Bool, opening: ScriptStreamOpening) {
        startStreamScripts(session, key: key, live: live, publishes: publishes, transport: StreamScriptsTransport(
            opening: opening,
            canSend: live.canSendScripted,
            isCurrent: { [weak self, weak live] in live != nil && self?.liveSockets[key] === live },
            refresh: { [weak live] resolver, redaction in live?.refresh(resolver: resolver, redaction: redaction) },
            send: { [weak self, weak live] message in
                guard let self, let live, liveSockets[key] === live else {
                    return .closed("The connection is closed, so the message wasn't sent.")
                }
                return live.send(scripted: message)
            }
        ))
    }

    /// Hands the stream scripts a message received before any reached limit, which ends them as Stop does, and tells
    /// them once the connection takes no more of what they send.
    private func feedStreamScripts(_ session: ScriptSession, _ received: ScriptSocketMessage?, from live: WebSocketLive, wasAtLimit: Bool) {
        if let received, !wasAtLimit {
            session.deliver(.socketMessage(received), number: live.receivedCount)
        }
        if !live.canSendScripted {
            session.closeStreamSending()
        }
    }

    /// Sends `live` each change to its request's saved keepalive, until the run ends or is replaced. Only a change
    /// counts, so a re-run of an older version (`RunOptions.spec`) keeps its own interval until the saved one changes.
    /// Re-arms itself on each library change, as `withObservationTracking` reports only the first; edits in the window
    /// reach the library after its autosave pause, so a burst of them lands as one change.
    private func followSavedKeepalive(_ key: RunKey, on live: WebSocketLive) {
        guard liveSockets[key] === live else {
            return
        }
        let saved = withObservationTracking {
            library.document(key.projectID)?.request(key.requestID)?.kind.webSocketSpec.map(\.options.keepaliveSeconds)
        } onChange: { [weak self, weak live] in
            Task { @MainActor [weak self, weak live] in
                if let self, let live {
                    followSavedKeepalive(key, on: live)
                }
            }
        }
        // A project that failed to load, or a request mid-switch, says nothing about the keepalive.
        guard let saved else {
            return
        }
        if let followed = live.followedKeepalive, followed != saved {
            live.setKeepalive(Self.keepalive(seconds: saved))
        }
        live.followedKeepalive = saved
    }

    /// A request's keepalive as the connection takes it: held to `WebSocketRequestOptions.keepaliveRange`, and off for
    /// none, zero, or less.
    static func keepalive(seconds: Double?) -> Duration? {
        let range = WebSocketRequestOptions.keepaliveRange
        return seconds.flatMap { $0 > 0 ? .seconds(min(max($0, range.lowerBound), range.upperBound)) : nil }
    }

    /// The handshake's URL as a WebSocket's: `http` and `https` as `ws` and `wss`, as browsers allow (a URL typed with
    /// no scheme reaches here as `http`). A fragment or credentials in it are refused rather than dropped: browsers
    /// refuse the first and never send the second.
    private static func webSocketURL(_ url: URL?) throws(RunFailure) -> URL {
        guard let url, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw RunFailure(kind: .invalidRequest, message: "Enter a URL to connect to.")
        }
        switch components.scheme?.lowercased() {
        case "ws", "http": components.scheme = "ws"
        case "wss", "https": components.scheme = "wss"
        default:
            throw RunFailure(kind: .invalidRequest, message: "A WebSocket URL starts with ws:// or wss://.")
        }
        guard components.fragment == nil else {
            throw RunFailure(kind: .invalidRequest, message: "A WebSocket URL can't have a #fragment; remove it.")
        }
        guard components.user == nil, components.password == nil else {
            throw RunFailure(kind: .invalidRequest, message: "A WebSocket URL can't carry credentials; set them in the Auth tab.")
        }
        guard let mapped = components.url else {
            throw RunFailure(kind: .invalidRequest, message: "“\(url.absoluteString)” is not a valid WebSocket URL.")
        }
        return mapped
    }

    /// The masked summary's URL with its scheme mapped the same way.
    static func webSocketURL(shown: String) -> String {
        for (prefix, replacement) in [("https://", "wss://"), ("http://", "ws://")] where shown.lowercased().hasPrefix(prefix) {
            return replacement + shown.dropFirst(prefix.count)
        }
        return shown
    }
}

/// What a WebSocket request would send, resolved and masked, without connecting.
public struct WebSocketRequestPreview: Sendable {
    /// The handshake, masked.
    public let request: ResolvedHTTPRequest
    /// The on-connect messages in order, masked: text as resolved, binary as its base64.
    public let messages: [(format: WebSocketMessageFormat, text: String)]
    public let unresolvedVariables: [String]
    /// What the pre-request scripts the preview ran did; `nil` when none would run.
    public let scriptReport: ScriptReport?
}

extension RequestRunner {
    /// Resolves a WebSocket request's handshake and on-connect messages as a run would, its pre-request scripts
    /// included, with secrets masked; unresolved names are listed rather than refused, nothing is checked that only
    /// connecting would, and nothing the scripts set is kept.
    public func previewWebSocket(
        _ request: RequestNodeID,
        in project: ProjectID,
        options: RunOptions = RunOptions()
    ) async throws(RunFailure) -> WebSocketRequestPreview {
        var options = options
        options.allowUnresolved = true
        // A request that isn't a WebSocket fails before any script runs.
        let unscripted = try runContext(request, in: project, options: options)
        guard unscripted.item.kind.webSocketSpec != nil else {
            throw RunFailure(kind: .invalidRequest, message: "“\(unscripted.item.name)” is not a WebSocket request.")
        }
        let session = try await previewScripts(request, in: project, options: options)
        let context = try runContext(request, in: project, options: options, session: session)
        guard let spec = context.item.kind.webSocketSpec?.normalized() else {
            throw RunFailure(kind: .invalidRequest, message: "“\(context.item.name)” is not a WebSocket request.")
        }
        var prepared = try preparedHTTP(spec.handshake, context: context, options: options)
        if let session {
            prepared.markScriptChanges(session.changes, redaction: context.redaction)
        }
        var summary = prepared.summary
        summary.url = Self.webSocketURL(shown: summary.url)
        var templates = RunTemplates(resolver: context.resolver)
        var messages: [(format: WebSocketMessageFormat, text: String)] = []
        for message in spec.onConnectMessages {
            messages.append((message.format, try templates.resolve(message.text).shown))
        }
        return WebSocketRequestPreview(
            request: summary,
            messages: messages,
            unresolvedVariables: prepared.unresolvedVariables + templates.unresolved.filter { !prepared.unresolvedVariables.contains($0) },
            scriptReport: session?.shownReport
        )
    }
}

extension RunFailure {
    /// A connection that never got an answer; TLS failures of either kind share `.tls`, as HTTP's and gRPC's do.
    init(_ error: WebSocketError) {
        let kind: Kind = switch error {
        case .invalidRequest: .invalidRequest
        case .connectionFailed: .transport
        case .untrustedServer, .tlsFailed: .tls
        case .timedOut: .timedOut
        case .cancelled: .cancelled
        }
        self.init(kind: kind, message: error.localizedDescription)
    }
}
