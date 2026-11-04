import Foundation

/// How a call secures its connection.
public enum GRPCTransportSecurity: Sendable {
    case plaintext
    /// TLS under `context`: its `verifiesServer`, its extra CAs (trusted in addition to the system roots), and the
    /// client identity it names for the target's `host` and `port`.
    case tls(TLSContext)
}

/// One gRPC call, with every template already resolved and every message already encoded.
public struct GRPCCallRequest: Sendable {
    public var target: GRPCTarget
    public var security: GRPCTransportSecurity
    /// Fully qualified, such as `helloworld.Greeter`.
    public var service: String
    /// The method's simple name, such as `SayHello`.
    public var method: String
    public var kind: GRPCMethodKind
    /// Enabled rows are sent. A key ending in `-bin` carries base64 (padded or not) and is sent as binary; any other
    /// value must be printable ASCII, as gRPC requires.
    public var metadata: [KeyValuePair]
    /// The call's deadline, measured from when it starts; `nil` waits indefinitely.
    public var timeout: Duration?
    public var body: GRPCRequestBody

    public init(
        target: GRPCTarget,
        security: GRPCTransportSecurity = .plaintext,
        service: String,
        method: String,
        kind: GRPCMethodKind,
        metadata: [KeyValuePair] = [],
        timeout: Duration? = nil,
        body: GRPCRequestBody
    ) {
        self.target = target
        self.security = security
        self.service = service
        self.method = method
        self.kind = kind
        self.metadata = metadata
        self.timeout = timeout
        self.body = body
    }

    /// `service/method`.
    public var methodPath: String {
        "\(service)/\(method)"
    }
}

/// What a call sends. Unary and server-streaming calls take one `message`; client-streaming and bidirectional calls
/// take either (a lone message is sent and the request stream closed).
public enum GRPCRequestBody: Sendable {
    case message([UInt8])
    case stream(GRPCOutbox)
}

/// The request messages of a client-streaming or bidirectional call, which the caller can add to while the call is
/// open. Nothing is sent until the call's stream opens; `finish()` closes the request side, which a client-streaming
/// server usually waits for before it answers.
///
/// Feed one call per outbox: the call consumes its messages, so a second call would find them gone.
public final class GRPCOutbox: Sendable {
    let messages: AsyncStream<[UInt8]>
    private let continuation: AsyncStream<[UInt8]>.Continuation

    /// Queues `messages` ahead of anything sent later.
    public init(_ messages: [[UInt8]] = []) {
        (self.messages, continuation) = AsyncStream.makeStream(of: [UInt8].self)
        for message in messages {
            continuation.yield(message)
        }
    }

    /// Queues `message`; `false` once the outbox is finished or its call has ended, when the message is dropped.
    @discardableResult
    public func send(_ message: [UInt8]) -> Bool {
        if case .enqueued = continuation.yield(message) {
            return true
        }
        return false
    }

    /// Closes the request stream once everything already queued is sent.
    public func finish() {
        continuation.finish()
    }
}

/// Something a call did before it ended, in the order it happened.
public enum GRPCCallEvent: Hashable, Sendable {
    /// The call's stream opened on a connected server, before anything else; a call cancelled after this was under way.
    case opened(timestamp: Date)
    /// The request message at `index` (from 0, in send order) was handed to the open stream. `sequence` numbers every
    /// message of the call from 0, both directions together.
    case sent(index: Int, sequence: Int, timestamp: Date)
    /// The server's response headers; pseudo-headers are left out, and binary values are base64.
    case initialMetadata([KeyValuePair], timestamp: Date)
    case received([UInt8], sequence: Int, timestamp: Date)
    /// Running totals of messages never reported, by direction: dropped while the receiver fell behind a fast stream,
    /// or still queued when the call was cancelled. Sent whenever the totals have grown, just before the next event,
    /// so an open stream shows its gaps as they happen; each supersedes the last, and the last is exact. Other events
    /// are never dropped.
    case omitted(sent: Int, received: Int)
}

/// How a call ended.
public enum GRPCCallOutcome: Hashable, Sendable {
    /// The call ended with a gRPC status: usually the server's, but also one the client assigns once a call is under
    /// way, such as `DEADLINE_EXCEEDED`, or `UNAVAILABLE` when the stream drops.
    case finished(status: GRPCStatusRecord, trailers: [KeyValuePair], timestamp: Date)
    /// The call never reached a status: it was invalid, could not connect, failed TLS, or was cancelled.
    case failed(GRPCCallError)
}

/// Why a call ended without a gRPC status. Kept apart from statuses so a refused connection or an untrusted
/// certificate never reads as something the server said.
public enum GRPCCallError: Error, Hashable, Sendable, LocalizedError {
    case invalidRequest(String)
    case connectionFailed(String)
    /// The server's certificate failed trust evaluation (system roots plus the project's CAs).
    case untrustedServer(String)
    /// The TLS handshake failed for another reason, such as a server that requires a client certificate.
    case tlsFailed(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .invalidRequest(let message), .connectionFailed(let message), .untrustedServer(let message),
             .tlsFailed(let message):
            message
        case .cancelled:
            "The call was cancelled."
        }
    }
}
