import Foundation
import Security

/// What came back from one HTTP exchange.
public struct HTTPResponseRecord: Hashable, Sendable, Codable {
    public var statusCode: Int
    public var headers: [KeyValuePair]
    public var body: Data
    /// The final URL, after any redirects that were followed, with the request's secrets masked.
    public var url: String
    public var startedAt: Date
    public var duration: TimeInterval
    public var timing: HTTPTiming?
    /// `h2`, `http/1.1`, and so on.
    public var protocolName: String?
    public var tlsVersion: String?
    public var presentedClientCertificate: Bool
    public var redirectCount: Int
    /// The events of an event-stream response, whose `body` stays empty; `nil` for every other response.
    public var eventStream: EventStreamRecord?

    public init(
        statusCode: Int,
        headers: [KeyValuePair],
        body: Data,
        url: String,
        startedAt: Date,
        duration: TimeInterval,
        timing: HTTPTiming? = nil,
        protocolName: String? = nil,
        tlsVersion: String? = nil,
        presentedClientCertificate: Bool = false,
        redirectCount: Int = 0,
        eventStream: EventStreamRecord? = nil
    ) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
        self.url = url
        self.startedAt = startedAt
        self.duration = duration
        self.timing = timing
        self.protocolName = protocolName
        self.tlsVersion = tlsVersion
        self.presentedClientCertificate = presentedClientCertificate
        self.redirectCount = redirectCount
        self.eventStream = eventStream
    }

    /// The standard reason phrase (RFC 9110 and friends). `HTTPURLResponse`'s localized strings are prose
    /// ("no error" for 200), not reason phrases.
    public var reasonPhrase: String {
        Self.reasonPhrases[statusCode] ?? HTTPURLResponse.localizedString(forStatusCode: statusCode).capitalized
    }

    private static let reasonPhrases: [Int: String] = [
        100: "Continue", 101: "Switching Protocols", 103: "Early Hints",
        200: "OK", 201: "Created", 202: "Accepted", 203: "Non-Authoritative Information", 204: "No Content",
        205: "Reset Content", 206: "Partial Content", 207: "Multi-Status",
        300: "Multiple Choices", 301: "Moved Permanently", 302: "Found", 303: "See Other", 304: "Not Modified",
        307: "Temporary Redirect", 308: "Permanent Redirect",
        400: "Bad Request", 401: "Unauthorized", 402: "Payment Required", 403: "Forbidden", 404: "Not Found",
        405: "Method Not Allowed", 406: "Not Acceptable", 407: "Proxy Authentication Required", 408: "Request Timeout",
        409: "Conflict", 410: "Gone", 411: "Length Required", 412: "Precondition Failed", 413: "Content Too Large",
        414: "URI Too Long", 415: "Unsupported Media Type", 416: "Range Not Satisfiable", 417: "Expectation Failed",
        418: "I'm a Teapot", 421: "Misdirected Request", 422: "Unprocessable Content", 423: "Locked",
        425: "Too Early", 426: "Upgrade Required", 428: "Precondition Required", 429: "Too Many Requests",
        431: "Request Header Fields Too Large", 451: "Unavailable For Legal Reasons",
        500: "Internal Server Error", 501: "Not Implemented", 502: "Bad Gateway", 503: "Service Unavailable",
        504: "Gateway Timeout", 505: "HTTP Version Not Supported", 507: "Insufficient Storage", 511: "Network Authentication Required"
    ]

    public func header(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

/// Phase durations of the final transaction, in seconds; `nil` where the phase did not happen (a reused connection
/// skips DNS, connect, and TLS).
public struct HTTPTiming: Hashable, Sendable, Codable {
    public var dnsLookup: TimeInterval?
    public var connect: TimeInterval?
    public var tlsHandshake: TimeInterval?
    public var requestSent: TimeInterval?
    /// Time to first byte, from the end of the request to the start of the response.
    public var waiting: TimeInterval?
    public var download: TimeInterval?
    public var isReusedConnection: Bool

    public init(
        dnsLookup: TimeInterval? = nil,
        connect: TimeInterval? = nil,
        tlsHandshake: TimeInterval? = nil,
        requestSent: TimeInterval? = nil,
        waiting: TimeInterval? = nil,
        download: TimeInterval? = nil,
        isReusedConnection: Bool = false
    ) {
        self.dnsLookup = dnsLookup
        self.connect = connect
        self.tlsHandshake = tlsHandshake
        self.requestSent = requestSent
        self.waiting = waiting
        self.download = download
        self.isReusedConnection = isReusedConnection
    }
}

public enum HTTPExecutionError: Error, Equatable, LocalizedError {
    case cancelled
    case timedOut
    case untrustedServer(String)
    case transport(String)

    public var errorDescription: String? {
        switch self {
        case .cancelled:
            "The request was cancelled."
        case .timedOut:
            "The request timed out."
        case .untrustedServer(let reason):
            reason
        case .transport(let message):
            message
        }
    }
}

/// What `HTTPExecutor.executeStreaming` reports while an event-stream response is open, in order.
public enum HTTPStreamEvent: Sendable {
    /// The response is an event stream: its head, before any event, without timing, protocol, or TLS yet. URLSession
    /// reports a head only with the first bytes of its body, so a server that sends nothing yet hasn't opened one.
    case opened(HTTPResponseRecord, timestamp: Date)
    /// `sequence` counts this connection's events from 0, dropped ones included; `receivedByteCount` is every byte of
    /// the body so far.
    case event(ServerSentEvent, sequence: Int, receivedByteCount: Int, timestamp: Date)
    case lastEventID(String)
    case retry(milliseconds: Int)
    /// Events never delivered, dropped while the receiver fell behind or skipped once stopped: a running total for the
    /// connection, each superseding the last.
    case omitted(Int)
}

/// How `HTTPExecutor.executeStreaming` ended.
public enum HTTPExecution: Sendable {
    case response(HTTPResponseRecord)
    /// An event stream that opened, its events delivered as they came, and has now ended: its head, with the
    /// connection's timing, why it ended, and every byte of its body.
    case stream(head: HTTPResponseRecord, end: EventStreamRecord.End, receivedByteCount: Int)
}

/// Sends prepared requests. One executor per project, so each project keeps its own in-memory cookie jar and
/// connection pool and never sees another project's cookies.
///
/// Server trust and client certificates are settled once per connection, and a session pools connections across
/// requests, so a connection opened with verification off would carry a later verified request with no check at all.
/// Each TLS policy (verification on or off, plus `TLSContext.fingerprint`) therefore gets its own session, through
/// `HTTPSessionPool`; all of them share one cookie jar, so changing TLS settings never logs the project out.
public final class HTTPExecutor: Sendable {
    private let pool: HTTPSessionPool

    public init(configuration: @escaping @Sendable () -> URLSessionConfiguration = HTTPExecutor.defaultConfiguration) {
        pool = HTTPSessionPool(configuration: configuration)
    }

    /// Ephemeral (cookies in memory, private to the session) and uncached: an API client must always hit the server.
    public static func defaultConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return configuration
    }

    /// Cancels every request in flight and closes every connection. Later requests fail as cancelled.
    public func invalidate() {
        pool.invalidate()
    }

    public func execute(
        _ request: PreparedHTTPRequest,
        tls: TLSContext,
        now: @escaping @Sendable () -> Date = { Date() }
    ) async throws(HTTPExecutionError) -> HTTPResponseRecord {
        switch try await perform(request, tls: tls, now: now, buffer: nil) {
        case .response(let response):
            response
        case .stream(let head, _, _):
            // Unreachable: without a buffer, an event stream's body is collected like any other.
            head
        }
    }

    /// Sends `request` like `execute`, except that a response that turns out to be an event stream (a 200 of type
    /// `text/event-stream`) is read as it arrives: `onEvent` gets its head, then each event, in order, and has had
    /// them all by the time this returns, except those `HTTPStreamEvent.omitted` counts. Any other response is
    /// collected whole, as `execute` does.
    ///
    /// The request's timeout keeps applying once a stream opens: URLSession's is an idle timeout, reset by every byte,
    /// so it becomes the longest a stream may stay silent (keep-alive comments count) before it ends `.timedOut`.
    /// Ending a stream never throws: cancelling ends it `.stopped`, and a transport error `.failed`. A server that closes
    /// the connection mid-response reads as `.closed`: URLSession takes that as the end of the body.
    public func executeStreaming(
        _ request: PreparedHTTPRequest,
        tls: TLSContext,
        now: @escaping @Sendable () -> Date = { Date() },
        onEvent: @escaping @Sendable (HTTPStreamEvent) async -> Void
    ) async throws(HTTPExecutionError) -> HTTPExecution {
        let buffer = LiveEventBuffer<HTTPStreamEvent>(messageLimit: Self.eventBufferLimit, byteLimit: Self.eventBufferByteLimit) { _, received in
            .omitted(received)
        }
        // Unstructured, so stopping the stream does not cancel delivery: what was delivered stays, and the backlog is
        // counted rather than lost silently.
        let delivery = Task {
            while let event = await buffer.next() {
                await onEvent(event)
            }
        }
        let result: Result<HTTPExecution, HTTPExecutionError>
        do throws(HTTPExecutionError) {
            result = .success(try await perform(request, tls: tls, now: now, buffer: buffer))
        } catch {
            result = .failure(error)
        }
        buffer.finish()
        // A stop that lands while the backlog drains, after the response itself has ended, skips the rest too.
        await withTaskCancellationHandler {
            await delivery.value
        } onCancel: {
            buffer.skipBacklog()
        }
        return try result.get()
    }

    /// The live buffer's budget between the network and the runner, as `GRPCExecutor`'s is for a call.
    static let eventBufferLimit = 2_000
    static let eventBufferByteLimit = 32 * 1024 * 1024

    /// One exchange, start to end. With a `buffer`, an event-stream response delivers into it instead of collecting.
    private func perform(
        _ request: PreparedHTTPRequest,
        tls: TLSContext,
        now: @escaping @Sendable () -> Date,
        buffer: LiveEventBuffer<HTTPStreamEvent>?
    ) async throws(HTTPExecutionError) -> HTTPExecution {
        guard let session = pool.lease(verifiesServer: request.verifyTLS, fingerprint: tls.fingerprint) else {
            throw .cancelled
        }
        defer { pool.release(session) }
        let recording = Recording(request: request, startedAt: now(), now: now)
        let delegate = ExchangeDelegate(
            followRedirects: request.followRedirects,
            verifiesServer: request.verifyTLS,
            tls: tls,
            credentialHeaderNames: ExchangeDelegate.redirectStrippedHeaders.union(request.credentialHeaderNames),
            stream: buffer.map { buffer in
                ExchangeDelegate.Stream(
                    buffer: buffer,
                    head: { http, state in recording.record(of: http, body: Data(), state: state) },
                    now: now
                )
            }
        )
        let task = session.dataTask(with: request.urlRequest)
        task.delegate = delegate
        // A request that leased its session just before `invalidate()` must not be sent. The pool raises the flag
        // before it cancels the session's tasks, so a task created before this check reads false is cancelled there.
        guard !pool.isInvalidated else {
            task.cancel()
            throw .cancelled
        }
        // Created before the handler, so a run cancelled before it started still reaches the task.
        await withTaskCancellationHandler {
            await delegate.run(task)
        } onCancel: {
            task.cancel()
            buffer?.skipBacklog()
        }
        let state = delegate.snapshot()
        if state.isStream, let http = state.response {
            let end: EventStreamRecord.End = switch state.failure {
            case nil: .closed
            case .cancelled: .stopped
            case .timedOut: .timedOut
            case let failure?: .failed(message: request.redaction.apply(failure.localizedDescription))
            }
            let head = recording.record(of: http, body: Data(), state: state)
            return .stream(head: head, end: end, receivedByteCount: state.receivedByteCount)
        }
        if let failure = state.failure {
            throw failure
        }
        guard let http = state.response else {
            throw .transport("The server's response was not HTTP.")
        }
        return .response(recording.record(of: http, body: state.body, state: state))
    }

    /// How one exchange's response is recorded.
    private struct Recording: Sendable {
        let request: PreparedHTTPRequest
        let startedAt: Date
        let now: @Sendable () -> Date

        /// The response as recorded. Timing, protocol, and TLS come from the metrics, which arrive only as the task
        /// ends: an event stream's head, built as it opens, has none yet.
        func record(of http: HTTPURLResponse, body: Data, state: ExchangeDelegate.State) -> HTTPResponseRecord {
            let transaction = state.metrics?.transactionMetrics.last
            // Masked: the record is shown, cached on disk, and handed to agents. The URL sent is the summary's; one a
            // redirect led to may carry the request's secrets (`?key=…` passed along), so those are masked in it.
            let url = state.redirected ? http.url.map { request.redaction.apply(to: $0) } : nil
            return HTTPResponseRecord(
                statusCode: http.statusCode,
                headers: http.allHeaderFields
                    .compactMap { key, value in (key as? String).map { KeyValuePair(key: $0, value: "\(value)") } }
                    .sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending },
                body: body,
                url: url ?? request.summary.url,
                startedAt: startedAt,
                duration: state.metrics?.taskInterval.duration ?? now().timeIntervalSince(startedAt),
                timing: transaction.map(HTTPExecutor.timing),
                protocolName: transaction?.networkProtocolName,
                tlsVersion: transaction?.negotiatedTLSProtocolVersion.map(HTTPExecutor.describe),
                presentedClientCertificate: state.presentedClientCertificate,
                redirectCount: state.metrics.map { max($0.redirectCount, 0) } ?? 0
            )
        }
    }

    private static func timing(_ transaction: URLSessionTaskTransactionMetrics) -> HTTPTiming {
        func span(_ start: Date?, _ end: Date?) -> TimeInterval? {
            guard let start, let end else {
                return nil
            }
            return end.timeIntervalSince(start)
        }
        let connectEnd = transaction.secureConnectionStartDate ?? transaction.connectEndDate
        return HTTPTiming(
            dnsLookup: span(transaction.domainLookupStartDate, transaction.domainLookupEndDate),
            connect: span(transaction.connectStartDate, connectEnd),
            tlsHandshake: span(transaction.secureConnectionStartDate, transaction.secureConnectionEndDate),
            requestSent: span(transaction.requestStartDate, transaction.requestEndDate),
            waiting: span(transaction.requestEndDate, transaction.responseStartDate),
            download: span(transaction.responseStartDate, transaction.responseEndDate),
            isReusedConnection: transaction.isReusedConnection
        )
    }

    private static func describe(_ version: tls_protocol_version_t) -> String {
        switch version {
        case .TLSv13: "TLS 1.3"
        case .TLSv12: "TLS 1.2"
        case .TLSv11: "TLS 1.1"
        case .TLSv10: "TLS 1.0"
        default: "TLS"
        }
    }
}
