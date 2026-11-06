import CryptoKit
import Foundation
import NIOCore
import NIOHTTP1
import NIOSSL
import NIOTLS
import NIOWebSocket
import Synchronization

/// The HTTP/1.1 upgrade that opens a connection: where it connects, the request it sends, and the checks its answer must
/// pass, which are a browser's (RFC 6455 §4.1): the accept key, and no subprotocol or extension the client never
/// offered.
enum WebSocketHandshake {
    /// Headers only the connection writes: NIO adds the key, version, `Upgrade`, and `Connection`, and `Host` comes from
    /// the URL, so typed copies are dropped rather than sent twice, as URLSession ignores a typed `Host`. A typed
    /// `Sec-WebSocket-Extensions` goes too: no extension is supported, so a server that took one would break the
    /// connection.
    static let reservedHeaders = WebSocketRequestSpec.connectionHeaders.union(["sec-websocket-extensions"])

    /// Where a handshake connects, and what it sends there.
    struct Target {
        /// The host to resolve: an IPv6 literal without its brackets.
        let host: String
        let port: Int
        let isTLS: Bool
        /// The URL as `http`/`https`, which cookies match against (`Secure` ones only over `https`).
        let cookieURL: URL
        let head: HTTPRequestHead
        let handlesCookies: Bool
    }

    static func target(for request: URLRequest, cookies: HTTPCookieStorage?) throws(WebSocketError) -> Target {
        guard let url = request.url, let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw .invalidRequest("Enter a URL to connect to.")
        }
        let scheme = components.scheme?.lowercased()
        guard scheme == "ws" || scheme == "wss" else {
            throw .invalidRequest("A WebSocket URL starts with ws:// or wss://.")
        }
        guard let host = url.host(percentEncoded: false), !host.isEmpty else {
            throw .invalidRequest("“\(url.absoluteString)” has no host to connect to.")
        }
        let isTLS = scheme == "wss"
        let defaultPort = isTLS ? 443 : 80
        let port = components.port ?? defaultPort
        let shownHost = host.contains(":") ? "[\(host)]" : host
        var cookieComponents = components
        cookieComponents.scheme = isTLS ? "https" : "http"
        cookieComponents.fragment = nil
        let cookieURL = cookieComponents.url ?? url

        var target = components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath
        if let query = components.percentEncodedQuery {
            target += "?\(query)"
        }
        var headers = HTTPHeaders()
        headers.add(name: "Host", value: port == defaultPort ? shownHost : "\(shownHost):\(port)")
        // Sorted, so the wire order never depends on a dictionary's.
        let typed = (request.allHTTPHeaderFields ?? [:]).sorted { $0.key.lowercased() < $1.key.lowercased() }
        for (name, value) in typed where !reservedHeaders.contains(name.lowercased()) {
            headers.add(name: name, value: value)
        }
        if request.httpShouldHandleCookies, let cookies, let stored = cookies.cookies(for: cookieURL), !stored.isEmpty {
            for (name, value) in HTTPCookie.requestHeaderFields(with: stored) {
                headers.add(name: name, value: value)
            }
        }
        return Target(
            host: host,
            port: port,
            isTLS: isTLS,
            cookieURL: cookieURL,
            head: HTTPRequestHead(version: .http1_1, method: .GET, uri: target, headers: headers),
            handlesCookies: request.httpShouldHandleCookies
        )
    }

    /// Keeps the server's `Set-Cookie`s, from a 101 or a refusal alike, as URLSession would for an HTTP response.
    static func storeCookies(from head: HTTPResponseHead, target: Target, in cookies: HTTPCookieStorage?) {
        guard target.handlesCookies, let cookies else {
            return
        }
        // One value at a time: Foundation reads a combined `Set-Cookie` as one cookie.
        for value in head.headers["Set-Cookie"] {
            let parsed = HTTPCookie.cookies(withResponseHeaderFields: ["Set-Cookie": value], for: target.cookieURL)
            cookies.setCookies(parsed, for: target.cookieURL, mainDocumentURL: nil)
        }
    }

    /// The server's choice of subprotocol, or why its 101 breaks the handshake's rules.
    static func check(_ head: HTTPResponseHead, key: String, offered: [String]) -> Result<String?, HandshakeViolation> {
        var hash = Insecure.SHA1()
        hash.update(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))
        let expected = Data(hash.finalize()).base64EncodedString()
        let accepts = head.headers["Sec-WebSocket-Accept"]
        guard accepts.count == 1, accepts[0].trimmingCharacters(in: .whitespaces) == expected else {
            return .failure(HandshakeViolation(reason: "The server's Sec-WebSocket-Accept doesn't match the key Reqling sent."))
        }
        let extensions = head.headers["Sec-WebSocket-Extensions"].joined(separator: ", ").trimmingCharacters(in: .whitespaces)
        if !extensions.isEmpty {
            return .failure(HandshakeViolation(reason: "The server turned on “\(extensions)”, an extension Reqling never offered."))
        }
        let chosen = head.headers["Sec-WebSocket-Protocol"]
        guard let choice = chosen.first?.trimmingCharacters(in: .whitespaces) else {
            return .success(nil)
        }
        guard chosen.count == 1, offered.contains(choice) else {
            let offer = offered.isEmpty ? "none were offered" : "Reqling offered \(offered.joined(separator: ", "))"
            return .failure(HandshakeViolation(reason: "The server chose the subprotocol “\(chosen.joined(separator: ", "))”, but \(offer)."))
        }
        return .success(choice)
    }

    struct HandshakeViolation: Error {
        let reason: String
    }
}

/// What a connection's handshake became once the server answered.
enum WebSocketUpgrade: Sendable {
    case upgraded(NIOAsyncChannel<WebSocketFrame, WebSocketFrame>, channel: any Channel)
    /// The server answered with something other than 101; its head comes through `channel` again, then its body.
    case notUpgraded(NIOAsyncChannel<HTTPClientResponsePart, HTTPClientRequestPart>)
}

/// Upgrades to a WebSocket only past `WebSocketHandshake.check`, recording the server's answer (and why it was
/// refused) in `observer` first, so a 101 that breaks the rules still shows. NIO's own upgrader would refuse such an
/// answer without handing it over.
final class WebSocketUpgrader: NIOTypedHTTPClientProtocolUpgrader {
    let supportedProtocol = "websocket"
    let requiredUpgradeHeaders: [String] = []
    private let key = NIOWebSocketClientUpgrader.randomRequestKey()
    private let subprotocols: [String]
    private let observer: WebSocketHandshakeObserver
    private let messageLimit: Int

    init(subprotocols: [String], observer: WebSocketHandshakeObserver, messageLimit: Int) {
        self.subprotocols = subprotocols
        self.observer = observer
        self.messageLimit = messageLimit
    }

    func addCustom(upgradeRequestHeaders: inout HTTPHeaders) {
        upgradeRequestHeaders.add(name: "Sec-WebSocket-Key", value: key)
        upgradeRequestHeaders.add(name: "Sec-WebSocket-Version", value: "13")
    }

    func shouldAllowUpgrade(upgradeResponse: HTTPResponseHead) -> Bool {
        observer.answered(upgradeResponse)
        switch WebSocketHandshake.check(upgradeResponse, key: key, offered: subprotocols) {
        case .success(let subprotocol):
            observer.chose(subprotocol)
            return true
        case .failure(let violation):
            observer.denied(violation.reason)
            return false
        }
    }

    /// Fragments are joined (`NIOWebSocketFrameAggregator`) up to `messageLimit`, so the session sees whole messages
    /// with control frames passing between them. The decoder's and the aggregator's errors reach the session, which
    /// closes with their code; NIO's `WebSocketProtocolErrorHandler` is left out because its own close can end the
    /// inbound stream before the error arrives.
    func upgrade(channel: any Channel, upgradeResponse: HTTPResponseHead) -> EventLoopFuture<WebSocketUpgrade> {
        let messageLimit = messageLimit
        return channel.eventLoop.makeCompletedFuture {
            let pipeline = channel.pipeline.syncOperations
            try pipeline.addHandler(WebSocketFrameEncoder())
            try pipeline.addHandler(ByteToMessageHandler(WebSocketFrameDecoder(maxFrameSize: messageLimit)))
            try pipeline.addHandler(NIOWebSocketFrameAggregator(
                minNonFinalFragmentSize: 0,
                maxAccumulatedFrameCount: 65_536,
                maxAccumulatedFrameSize: messageLimit
            ))
            return .upgraded(try NIOAsyncChannel(wrappingChannelSynchronously: channel), channel: channel)
        }
    }
}

/// What one handshake observed, from the event loop: when it connected, finished TLS, and was answered, the TLS version,
/// whether a client certificate went out, and the answer itself.
final class WebSocketHandshakeObserver: Sendable {
    struct State {
        var connectedAt: Date?
        var tlsCompletedAt: Date?
        var tlsVersion: String?
        var presentedClientCertificate = false
        var answeredAt: Date?
        var answer: HTTPResponseHead?
        var subprotocol: String?
        var denial: String?
    }

    private let now: @Sendable () -> Date
    private let state = Mutex(State())

    init(now: @escaping @Sendable () -> Date) {
        self.now = now
    }

    var snapshot: State {
        state.withLock { $0 }
    }

    func connected() {
        let date = now()
        state.withLock { $0.connectedAt = date }
    }

    func completedTLS(version: TLSVersion?) {
        let date = now()
        state.withLock { state in
            state.tlsCompletedAt = date
            state.tlsVersion = version.map(Self.describe)
        }
    }

    func presentedClientCertificate() {
        state.withLock { $0.presentedClientCertificate = true }
    }

    func answered(_ head: HTTPResponseHead) {
        let date = now()
        state.withLock { state in
            state.answeredAt = date
            state.answer = head
        }
    }

    func chose(_ subprotocol: String?) {
        state.withLock { $0.subprotocol = subprotocol }
    }

    func denied(_ reason: String) {
        state.withLock { $0.denial = reason }
    }

    /// The answer as a response record, its phases measured from `startedAt`.
    func record(url: String, startedAt: Date, body: Data = Data()) -> HTTPResponseRecord? {
        let state = snapshot
        guard let answer = state.answer, let answeredAt = state.answeredAt else {
            return nil
        }
        let connect = state.connectedAt.map { $0.timeIntervalSince(startedAt) }
        let tls = state.connectedAt.flatMap { connected in state.tlsCompletedAt.map { $0.timeIntervalSince(connected) } }
        let waitingFrom = state.tlsCompletedAt ?? state.connectedAt ?? startedAt
        return HTTPResponseRecord(
            statusCode: Int(answer.status.code),
            headers: answer.headers.map { KeyValuePair(key: $0.name, value: $0.value) },
            body: body,
            url: url,
            startedAt: startedAt,
            duration: answeredAt.timeIntervalSince(startedAt),
            timing: HTTPTiming(connect: connect, tlsHandshake: tls, waiting: answeredAt.timeIntervalSince(waitingFrom)),
            protocolName: "http/1.1",
            tlsVersion: state.tlsVersion,
            presentedClientCertificate: state.presentedClientCertificate
        )
    }

    private static func describe(_ version: TLSVersion) -> String {
        switch version {
        case .tlsv13: "TLS 1.3"
        case .tlsv12: "TLS 1.2"
        case .tlsv11: "TLS 1.1"
        case .tlsv1: "TLS 1.0"
        }
    }
}

/// Times the connection and its TLS for `WebSocketHandshakeObserver`, passing everything through untouched.
final class WebSocketHandshakeTimer: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer

    private let observer: WebSocketHandshakeObserver

    init(observer: WebSocketHandshakeObserver) {
        self.observer = observer
    }

    func channelActive(context: ChannelHandlerContext) {
        observer.connected()
        context.fireChannelActive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        context.fireChannelRead(data)
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if case TLSUserEvent.handshakeCompleted = event {
            let version = try? context.pipeline.syncOperations.handler(type: NIOSSLClientHandler.self).tlsVersion
            observer.completedTLS(version: version ?? nil)
        }
        context.fireUserInboundEventTriggered(event)
    }
}

/// Signs with the identity's key like `SecKeyPrivateKey`, noting that the server asked for the certificate: TLS only
/// signs with a client key when it presents the certificate.
struct WebSocketClientKey: NIOSSLCustomPrivateKey, Hashable {
    let key: SecKeyPrivateKey
    let observer: WebSocketHandshakeObserver

    var signatureAlgorithms: [SignatureAlgorithm] {
        key.signatureAlgorithms
    }

    func sign(channel: any Channel, algorithm: SignatureAlgorithm, data: ByteBuffer) -> EventLoopFuture<ByteBuffer> {
        observer.presentedClientCertificate()
        return key.sign(channel: channel, algorithm: algorithm, data: data)
    }

    func decrypt(channel: any Channel, data: ByteBuffer) -> EventLoopFuture<ByteBuffer> {
        key.decrypt(channel: channel, data: data)
    }

    static func == (lhs: WebSocketClientKey, rhs: WebSocketClientKey) -> Bool {
        lhs.key == rhs.key && lhs.observer === rhs.observer
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(key)
        hasher.combine(ObjectIdentifier(observer))
    }
}
