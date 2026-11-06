import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOSSL
import NIOWebSocket
import Synchronization

/// Opens WebSocket connections over SwiftNIO: an HTTP/1.1 upgrade (`WebSocketHandshake`), TLS through `NIOClientTLS`
/// for `wss`, then the open connection (`WebSocketSession`) until it closes.
///
/// SwiftNIO rather than URLSession, whose WebSocket task answers the server's pings out of sight and drops a refused
/// handshake's body; neither proxies nor redirects apply, as for gRPC. Each connection runs in the caller's task, and
/// cancelling that task closes it: during the handshake at once, and once open with a close handshake (1000).
struct WebSocketExecutor: Sendable {
    /// The largest message either way; a bigger one closes the connection with 1009 (Message Too Big).
    static let messageLimit = 16 * 1024 * 1024
    /// The most messages, and payload bytes, waiting for `onEvent`; past that the oldest are dropped and counted
    /// (`WebSocketEvent.omitted`), as `GRPCExecutor.eventBufferLimit` bounds a call's.
    static let eventBufferLimit = 2_000
    static let eventBufferByteLimit = 32 * 1024 * 1024
    /// The most of a refused handshake's body kept, which is usually an error page or a JSON error.
    static let refusalBodyLimit = 1024 * 1024
    /// How long a close handshake may take before the connection is closed anyway.
    static let closeTimeout: Duration = .seconds(5)

    private let sleep: @Sendable (Duration) async throws -> Void
    private let now: @Sendable () -> Date
    private let group: any EventLoopGroup
    private let messageLimit: Int

    /// `sleep` times the handshake's deadline, keepalive pings, and the close handshake, so tests need no wall clock.
    /// `messageLimit` is `WebSocketExecutor.messageLimit` outside tests.
    init(
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        now: @escaping @Sendable () -> Date = { Date() },
        group: any EventLoopGroup = MultiThreadedEventLoopGroup.singleton,
        messageLimit: Int = WebSocketExecutor.messageLimit
    ) {
        self.sleep = sleep
        self.now = now
        self.group = group
        self.messageLimit = messageLimit
    }

    /// Opens `request` and runs it to the end. `onEvent` gets the events in order, one at a time, and has had them all
    /// by the time this returns, except those `WebSocketEvent.omitted` counts. `outbox` is read once the connection
    /// opens, so commands queued before then go out first.
    func execute(
        _ request: WebSocketConnectRequest,
        outbox: WebSocketOutbox,
        onEvent: @escaping @Sendable (WebSocketEvent) async -> Void
    ) async -> WebSocketOutcome {
        let startedAt = now()
        let observer = WebSocketHandshakeObserver(now: now)
        let trustFailure = TrustFailureRecorder()
        let target: WebSocketHandshake.Target
        let tls: TLSSetup?
        do {
            target = try WebSocketHandshake.target(for: request.handshake, cookies: request.cookies)
            tls = target.isTLS
                ? try TLSSetup(request.tls ?? .default, target: target, observer: observer, trustFailure: trustFailure)
                : nil
        } catch {
            return .failed(error)
        }
        let buffer = LiveEventBuffer<WebSocketEvent>(messageLimit: Self.eventBufferLimit, byteLimit: Self.eventBufferByteLimit) {
            .omitted(sent: $0, received: $1)
        }
        // Unstructured, so cancelling the connection does not cancel delivery: its close still reaches `onEvent`.
        let delivery = Task {
            while let event = await buffer.next() {
                await onEvent(event)
            }
        }
        let attempt = Attempt(request: request, target: target, tls: tls, observer: observer, trustFailure: trustFailure, startedAt: startedAt)
        let outcome = await run(attempt, outbox: outbox, buffer: buffer)
        buffer.finish()
        await withTaskCancellationHandler {
            await delivery.value
        } onCancel: {
            buffer.skipBacklog()
        }
        return outcome
    }

    /// Everything one connection's handshake works from.
    private struct Attempt: Sendable {
        let request: WebSocketConnectRequest
        let target: WebSocketHandshake.Target
        let tls: TLSSetup?
        let observer: WebSocketHandshakeObserver
        let trustFailure: TrustFailureRecorder
        let startedAt: Date

        /// Bounds connecting, TLS, and the server's answer, a refusal's body included. Held to the most Settings allows,
        /// as a gRPC deadline is (`GRPCRequestResolution.duration`), so a huge stored timeout can't overflow it.
        var timeout: Duration {
            .milliseconds(Int64(min(max(request.handshake.timeoutInterval, 0.001), AppSettings.timeoutRange.upperBound) * 1_000))
        }

        func record(body: Data = Data()) -> HTTPResponseRecord? {
            observer.record(url: request.shownURL, startedAt: startedAt, body: body)
        }
    }

    private func run(_ attempt: Attempt, outbox: WebSocketOutbox, buffer: LiveEventBuffer<WebSocketEvent>) async -> WebSocketOutcome {
        let answer: Answer
        switch await handshake(attempt) {
        case .answered(let answered):
            answer = answered
        case .ended(let outcome):
            return outcome
        }
        let observed = attempt.observer.snapshot
        let body: Data = if case .refused(let body) = answer { body } else { Data() }
        guard let head = attempt.record(body: body), let response = observed.answer else {
            if case .open(_, let underlying) = answer {
                underlying.close(promise: nil)
            }
            return .failed(.connectionFailed("The server closed the connection without answering the handshake."))
        }
        WebSocketHandshake.storeCookies(from: response, target: attempt.target, in: attempt.request.cookies)
        switch answer {
        case .refused:
            return .refused(head: head, reason: Self.refusal(head))
        case .open(let channel, let underlying):
            buffer.appendControl(.opened(head: head, subprotocol: observed.subprotocol, timestamp: now()))
            let end = await open(channel, underlying: underlying, keepalive: attempt.request.keepalive, outbox: outbox, buffer: buffer)
            return .ended(end, timestamp: now())
        }
    }

    private enum HandshakeResult {
        case answered(Answer)
        case ended(WebSocketOutcome)
    }

    private func handshake(_ attempt: Attempt) async -> HandshakeResult {
        let channels = ChannelSet()
        do {
            let answer = try await HandshakeDeadline.run(timeout: attempt.timeout, sleep: sleep) {
                try await connect(attempt, channels: channels)
            } discard: { late in
                if case .open(_, let channel) = late {
                    channel.close(promise: nil)
                }
            } abandon: {
                channels.closeAll()
            }
            return .answered(answer)
        } catch HandshakeDeadline.Failure.timedOut {
            return .ended(.failed(.timedOut))
        } catch HandshakeDeadline.Failure.cancelled {
            return .ended(.failed(.cancelled))
        } catch {
            channels.closeAll()
            if let denial = attempt.observer.snapshot.denial, let head = attempt.record() {
                return .ended(.refused(head: head, reason: denial))
            }
            return .ended(.failed(Self.classify(error, target: attempt.target, trustFailure: attempt.trustFailure.reason)))
        }
    }

    /// Runs the open connection until it closes. The session runs unstructured, so a cancelled caller still gets a
    /// close handshake: the sleeps that time it would throw at once in a cancelled task.
    private func open(
        _ channel: NIOAsyncChannel<WebSocketFrame, WebSocketFrame>,
        underlying: any Channel,
        keepalive: Duration?,
        outbox: WebSocketOutbox,
        buffer: LiveEventBuffer<WebSocketEvent>
    ) async -> WebSocketEnd {
        let session = WebSocketSession(
            channel: channel,
            underlying: underlying,
            sink: WebSocketEventSink(buffer: buffer, now: now),
            keepalive: keepalive,
            closeTimeout: Self.closeTimeout,
            messageLimit: messageLimit,
            sleep: sleep,
            now: now
        )
        let (inputs, feed) = AsyncStream.makeStream(of: WebSocketSession.Input.self)
        let running = Task {
            await session.run(outbox: outbox, inputs: inputs, feed: feed)
        }
        return await withTaskCancellationHandler {
            await running.value
        } onCancel: {
            feed.yield(.command(.close(code: 1000, reason: "")))
        }
    }

    /// What the server's answer became, read inside the handshake's deadline.
    private enum Answer: Sendable {
        case open(NIOAsyncChannel<WebSocketFrame, WebSocketFrame>, channel: any Channel)
        /// Up to `refusalBodyLimit` of a refusal's body; the head is in the observer.
        case refused(Data)
    }

    private func connect(_ attempt: Attempt, channels: ChannelSet) async throws -> Answer {
        let (target, tls, observer, subprotocols) = (attempt.target, attempt.tls, attempt.observer, attempt.request.subprotocols)
        let connectTimeout = TimeAmount.nanoseconds(Int64(attempt.timeout / .nanoseconds(1)))
        let upgrade = try await ClientBootstrap(group: group)
            .connectTimeout(connectTimeout)
            .connect(host: target.host, port: target.port) { channel in
                channels.add(channel)
                return channel.eventLoop.makeCompletedFuture {
                    let pipeline = channel.pipeline.syncOperations
                    if let tls {
                        try pipeline.addHandler(try tls.handler())
                    }
                    try pipeline.addHandler(WebSocketHandshakeTimer(observer: observer))
                    let upgrader = WebSocketUpgrader(subprotocols: subprotocols, observer: observer, messageLimit: messageLimit)
                    var configuration = NIOUpgradableHTTPClientPipelineConfiguration(
                        upgradeConfiguration: NIOTypedHTTPClientUpgradeConfiguration(
                            upgradeRequestHead: target.head,
                            upgraders: [upgrader],
                            notUpgradingCompletionHandler: { channel in
                                channel.eventLoop.makeCompletedFuture {
                                    WebSocketUpgrade.notUpgraded(try NIOAsyncChannel(wrappingChannelSynchronously: channel))
                                }
                            }
                        )
                    )
                    // Frames can arrive in the same read as the 101; dropping the decoder's leftovers would lose them.
                    configuration.leftOverBytesStrategy = .forwardBytes
                    return try pipeline.configureUpgradableHTTPClientPipeline(configuration: configuration)
                }
            }
            .get()
        switch upgrade {
        case .upgraded(let channel, let underlying):
            return .open(channel, channel: underlying)
        case .notUpgraded(let channel):
            return .refused(try await Self.readRefusal(channel, observer: observer))
        }
    }

    /// The refusal's head comes through again first, then as much of its body as `refusalBodyLimit` keeps.
    private static func readRefusal(
        _ channel: NIOAsyncChannel<HTTPClientResponsePart, HTTPClientRequestPart>,
        observer: WebSocketHandshakeObserver
    ) async throws -> Data {
        try await channel.executeThenClose { inbound, _ in
            var body = Data()
            reading: for try await part in inbound {
                switch part {
                case .head(let head):
                    observer.answered(head)
                case .body(let chunk):
                    body.append(contentsOf: chunk.readableBytesView.prefix(refusalBodyLimit - body.count))
                    if body.count >= refusalBodyLimit {
                        break reading
                    }
                case .end:
                    break reading
                }
            }
            return body
        }
    }

    /// Why a handshake that got an answer opened no connection: anything but 101, and redirects never followed.
    private static func refusal(_ head: HTTPResponseRecord) -> String {
        let status = "\(head.statusCode) \(head.reasonPhrase)"
        guard (300..<400).contains(head.statusCode) else {
            return "The server answered \(status) instead of switching protocols."
        }
        let location = head.header("Location").map { " to \($0)" } ?? ""
        return "The server answered \(status)\(location). WebSocket handshakes never follow redirects."
    }

    /// Only failures that kept the handshake from getting an answer reach here.
    static func classify(_ error: any Error, target: WebSocketHandshake.Target, trustFailure: String?) -> WebSocketError {
        if let trustFailure {
            return .untrustedServer(trustFailure)
        }
        let address = "\(target.host.contains(":") ? "[\(target.host)]" : target.host):\(target.port)"
        let causes = [error] + ((error as? NIOConnectionError)?.connectionErrors.map(\.error) ?? [])
        if let tlsError = causes.first(where: NIOClientTLS.isHandshakeError) {
            return .tlsFailed("The TLS handshake with \(address) failed: \(NIOClientTLS.handshakeReason(tlsError)).")
        }
        if let connection = error as? NIOConnectionError {
            if connection.connectionErrors.isEmpty, connection.dnsAError != nil || connection.dnsAAAAError != nil {
                return .connectionFailed("Could not find the server \(target.host).")
            }
            if let last = connection.connectionErrors.last?.error {
                return .connectionFailed("Could not connect to \(address): \(describe(last))")
            }
        }
        if case ChannelError.connectTimeout = error {
            return .timedOut
        }
        if let upgrade = error as? NIOHTTPClientUpgradeError, upgrade == .responseProtocolNotFound {
            return .connectionFailed("The server answered 101 Switching Protocols without switching to WebSocket.")
        }
        return .connectionFailed("Could not connect to \(address): \(describe(error))")
    }

    /// A socket error reads as its `strerror` text ("Connection refused") rather than NIO's call-site detail.
    static func describe(_ error: any Error) -> String {
        if let ioError = error as? IOError {
            return String(cString: strerror(ioError.errnoCode))
        }
        if case ChannelError.ioOnClosedChannel = error {
            return "The connection is closed."
        }
        return String(describing: error)
    }
}

/// The TLS a `wss` handshake runs: one `NIOSSLContext` per connection, built from the project's `TLSContext`.
private struct TLSSetup: Sendable {
    let context: NIOSSLContext
    let serverHostname: String?
    let client: NIOClientTLS

    init(
        _ tls: TLSContext,
        target: WebSocketHandshake.Target,
        observer: WebSocketHandshakeObserver,
        trustFailure: TrustFailureRecorder
    ) throws(WebSocketError) {
        do {
            client = try NIOClientTLS(tls, host: target.host, port: target.port, trustFailure: trustFailure)
        } catch {
            throw .tlsFailed(error.localizedDescription)
        }
        var configuration = TLSConfiguration.makeClientConfiguration()
        configuration.minimumTLSVersion = .tlsv12
        configuration.applicationProtocols = ["http/1.1"]
        configuration.certificateVerification = client.verifiesServer ? .noHostnameVerification : .none
        do {
            if let privateKey = client.privateKey {
                configuration.privateKey = .privateKey(NIOSSLPrivateKey(customPrivateKey: WebSocketClientKey(key: privateKey, observer: observer)))
                configuration.certificateChain = try client.certificateChain.map { .certificate(try NIOSSLCertificate(bytes: $0, format: .der)) }
            }
            context = try NIOSSLContext(configuration: configuration)
        } catch {
            throw .tlsFailed("TLS could not be set up for \(target.host): \(error)")
        }
        // NIOSSL refuses an IP address as a server name (SNI is for host names); trust still checks its IP SANs.
        serverHostname = (try? SocketAddress(ipAddress: target.host, port: target.port)) == nil ? target.host : nil
    }

    func handler() throws -> NIOSSLClientHandler {
        guard client.verifiesServer else {
            return try NIOSSLClientHandler(context: context, serverHostname: serverHostname)
        }
        let client = client
        return try NIOSSLClientHandler(
            context: context,
            serverHostname: serverHostname,
            customVerificationCallbackWithMetadata: { certificates, promise in
                client.verify(certificates, promise: promise)
            }
        )
    }
}

/// Every channel a handshake created, so a timed-out or cancelled one can close them all: NIO's connect has no
/// cancellation of its own, and Happy Eyeballs may race several.
private final class ChannelSet: Sendable {
    private let channels = Mutex<[any Channel]>([])

    func add(_ channel: any Channel) {
        channels.withLock { $0.append(channel) }
    }

    func closeAll() {
        for channel in channels.withLock({ $0 }) {
            channel.close(promise: nil)
        }
    }
}

/// Races a handshake against its deadline and the caller's cancellation, since NIO's connect watches neither: the
/// first to finish wins, and a handshake that completes after losing goes to `discard`.
enum HandshakeDeadline {
    enum Failure: Error {
        case timedOut
        case cancelled
    }

    /// `abandon` runs when the deadline or a cancellation wins, to stop the losing handshake.
    static func run<T: Sendable>(
        timeout: Duration,
        sleep: @escaping @Sendable (Duration) async throws -> Void,
        operation: @escaping @Sendable () async throws -> T,
        discard: @escaping @Sendable (T) -> Void,
        abandon: @escaping @Sendable () -> Void
    ) async throws -> T {
        let gate = ResumeGate<T>()
        Task {
            do {
                let value = try await operation()
                if !gate.resume(.success(value)) {
                    discard(value)
                }
            } catch {
                gate.resume(.failure(error))
            }
        }
        let timer = Task {
            guard (try? await sleep(timeout)) != nil else {
                return
            }
            if gate.resume(.failure(Failure.timedOut)) {
                abandon()
            }
        }
        defer {
            timer.cancel()
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { gate.install($0) }
        } onCancel: {
            if gate.resume(.failure(Failure.cancelled)) {
                abandon()
            }
        }
    }
}

/// Resumes one continuation with the first result offered, whether that arrives before the continuation is installed
/// or after.
private final class ResumeGate<T: Sendable>: Sendable {
    private struct State {
        var continuation: CheckedContinuation<T, any Error>?
        var early: Result<T, any Error>?
        var isSettled = false
    }

    private let state = Mutex(State())

    func install(_ continuation: CheckedContinuation<T, any Error>) {
        let early = state.withLock { state -> Result<T, any Error>? in
            guard let early = state.early else {
                state.continuation = continuation
                return nil
            }
            return early
        }
        early.map { continuation.resume(with: $0) }
    }

    /// `false` when an earlier result already won.
    @discardableResult
    func resume(_ result: Result<T, any Error>) -> Bool {
        let (won, continuation) = state.withLock { state -> (Bool, CheckedContinuation<T, any Error>?) in
            guard !state.isSettled else {
                return (false, nil)
            }
            state.isSettled = true
            guard let continuation = state.continuation else {
                state.early = result
                return (true, nil)
            }
            state.continuation = nil
            return (true, continuation)
        }
        continuation?.resume(with: result)
        return won
    }
}
