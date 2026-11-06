import Foundation

/// Whether a WebSocket message is UTF-8 text or binary.
public enum WebSocketMessageFormat: String, Hashable, Sendable, Codable, CaseIterable {
    case text
    case binary
}

/// One WebSocket connection to open, with every template already resolved.
struct WebSocketConnectRequest: Sendable {
    /// A `ws` or `wss` URL, the headers to send, and the timeout that bounds connecting, TLS, and the server's answer
    /// to the handshake. An open connection has no idle timeout: a socket may stay quiet for as long as it likes.
    var handshake: URLRequest
    /// The URL with the run's secrets masked, which the records carry; the handshake's own URL is never recorded.
    var shownURL: String
    /// Offered in preference order; the server must pick one of these or none.
    var subprotocols: [String]
    /// Consulted only for `wss`; `nil` uses the defaults (verify the server, present no certificate).
    var tls: TLSContext?
    /// The project's jar (`HTTPExecutor.cookies`): its cookies for the URL go out with the handshake, and the server's
    /// `Set-Cookie`s come back into it, unless the handshake's `httpShouldHandleCookies` is off (the user typed a
    /// `Cookie` header), as URLSession treats it.
    var cookies: HTTPCookieStorage?
    /// Ping after this long without a frame either way; `nil` never pings unasked. `WebSocketCommand.keepalive`
    /// changes it once open.
    var keepalive: Duration?

    init(
        handshake: URLRequest,
        shownURL: String,
        subprotocols: [String] = [],
        tls: TLSContext? = nil,
        cookies: HTTPCookieStorage? = nil,
        keepalive: Duration? = nil
    ) {
        self.handshake = handshake
        self.shownURL = shownURL
        self.subprotocols = subprotocols
        self.tls = tls
        self.cookies = cookies
        self.keepalive = keepalive
    }
}

/// What the window or an agent asks an open connection to do, in order.
enum WebSocketCommand: Sendable {
    case message(WebSocketMessageFormat, [UInt8])
    case ping
    /// From now on, pings after this long without a frame either way, or never unasked for `nil`.
    case keepalive(Duration?)
    /// Starts the close handshake. Messages queued after it are not sent.
    case close(code: UInt16, reason: String)
}

/// The commands for one connection, which the caller adds to while it is open. Nothing is sent until the connection
/// opens, so messages queued first (a request's on-connect messages) go out in order as soon as it does.
///
/// Feed one connection per outbox: the connection consumes its commands, so a second would find them gone.
final class WebSocketOutbox: Sendable {
    let commands: AsyncStream<WebSocketCommand>
    private let continuation: AsyncStream<WebSocketCommand>.Continuation

    init(_ commands: [WebSocketCommand] = []) {
        (self.commands, continuation) = AsyncStream.makeStream(of: WebSocketCommand.self)
        for command in commands {
            continuation.yield(command)
        }
    }

    /// Queues `command`; `false` once the outbox is finished, when it is dropped.
    @discardableResult
    func send(_ command: WebSocketCommand) -> Bool {
        if case .enqueued = continuation.yield(command) {
            return true
        }
        return false
    }

    /// Takes no more commands. A WebSocket has no half-close, so this leaves the connection open.
    func finish() {
        continuation.finish()
    }
}

/// Something an open connection did, in the order it happened.
enum WebSocketEvent: Sendable {
    /// The server switched protocols; everything after happens on the open connection. `head` is the 101 with the
    /// handshake's timing and TLS.
    case opened(head: HTTPResponseRecord, subprotocol: String?, timestamp: Date)
    /// The message the outbox queued at `index` (from 0, counting messages only) was written to the connection.
    case sent(index: Int, timestamp: Date)
    case received(WebSocketMessageFormat, [UInt8], timestamp: Date)
    case control(WebSocketControlEvent, timestamp: Date)
    /// Running totals of messages never reported, by direction, as `GRPCCallEvent.omitted` counts them: dropped while
    /// the receiver fell behind, or still queued when the connection was cancelled. Each supersedes the last.
    case omitted(sent: Int, received: Int)
}

/// The frames around the messages: pings, pongs, close frames, and what happened to the connection.
enum WebSocketControlEvent: Hashable, Sendable {
    /// A ping we sent, by its counter, which its payload carries so a pong can be matched to it.
    case pingSent(id: UInt64)
    /// A pong to our ping `id` after `roundTrip` seconds, or with both `nil`, one we never asked for (a one-way
    /// heartbeat the protocol allows).
    case pong(id: UInt64?, roundTrip: TimeInterval?)
    /// The server pinged, and we answered with a pong.
    case serverPinged
    /// `code` is `nil` for a close frame that carried none (1005, No Status): ours echoing such a frame, or the server's.
    case closeSent(code: UInt16?, reason: String)
    case closeReceived(code: UInt16?, reason: String)
    case note(String)
}

/// How a connection ended.
enum WebSocketOutcome: Sendable {
    /// It opened, and has ended.
    case ended(WebSocketEnd, timestamp: Date)
    /// The server answered the handshake without opening a connection, or broke the handshake's rules; `head` is its
    /// answer, with up to `WebSocketExecutor.refusalBodyLimit` of its body, and `reason` says what went wrong.
    case refused(head: HTTPResponseRecord, reason: String)
    /// It never got an answer.
    case failed(WebSocketError)
}

/// How an open connection ended.
enum WebSocketEnd: Hashable, Sendable {
    /// Closed with a close frame: the side that sent the first one gave `code` and `reason`. `code` is `nil` when the
    /// server's frame carried none. Includes our close that the server never answered in time.
    case closed(code: UInt16?, reason: String, byServer: Bool)
    /// Ended without a close frame (1006): the connection dropped, or a keepalive ping went unanswered.
    case dropped(String)
    /// The server broke the protocol, and we closed with `code` as a browser would.
    case violation(code: UInt16, message: String)
}

/// Why a connection never opened. TLS failures of either kind map to `RunFailure.Kind.tls`, as for HTTP and gRPC.
enum WebSocketError: Error, Hashable, Sendable, LocalizedError {
    case invalidRequest(String)
    case connectionFailed(String)
    /// The server's certificate failed trust evaluation (system roots plus the project's CAs).
    case untrustedServer(String)
    case tlsFailed(String)
    case timedOut
    case cancelled

    var errorDescription: String? {
        switch self {
        case .invalidRequest(let message), .connectionFailed(let message), .untrustedServer(let message), .tlsFailed(let message):
            message
        case .timedOut:
            "The server didn't answer the WebSocket handshake in time."
        case .cancelled:
            "The connection was cancelled."
        }
    }
}
