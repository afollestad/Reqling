import Foundation
import Security
import Synchronization

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
        redirectCount: Int = 0
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
        now: @Sendable () -> Date = { Date() }
    ) async throws(HTTPExecutionError) -> HTTPResponseRecord {
        guard let session = pool.lease(verifiesServer: request.verifyTLS, fingerprint: tls.fingerprint) else {
            throw .cancelled
        }
        defer { pool.release(session) }
        let delegate = ExchangeDelegate(
            followRedirects: request.followRedirects,
            verifiesServer: request.verifyTLS,
            tls: tls,
            credentialHeaderNames: ExchangeDelegate.redirectStrippedHeaders.union(request.credentialHeaderNames),
            pool: pool
        )
        let startedAt = now()
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request.urlRequest, delegate: delegate)
        } catch {
            throw delegate.translate(error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw .transport("The server's response was not HTTP.")
        }
        let state = delegate.snapshot()
        let transaction = state.metrics?.transactionMetrics.last
        // Masked: the record is shown, cached on disk, and handed to agents. The URL sent is the summary's; one a redirect
        // led to may carry the request's secrets (`?key=…` passed along), so those are masked in it.
        let url = state.redirected ? http.url.map { request.redaction.apply(to: $0) } : nil
        return HTTPResponseRecord(
            statusCode: http.statusCode,
            headers: http.allHeaderFields
                .compactMap { key, value in (key as? String).map { KeyValuePair(key: $0, value: "\(value)") } }
                .sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending },
            body: data,
            url: url ?? request.summary.url,
            startedAt: startedAt,
            duration: state.metrics?.taskInterval.duration ?? now().timeIntervalSince(startedAt),
            timing: transaction.map(Self.timing),
            protocolName: transaction?.networkProtocolName,
            tlsVersion: transaction?.negotiatedTLSProtocolVersion.map(Self.describe),
            presentedClientCertificate: state.presentedClientCertificate,
            redirectCount: state.metrics.map { max($0.redirectCount, 0) } ?? 0
        )
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

/// The per-exchange delegate: applies the redirect policy, evaluates server trust against the project's CAs, answers
/// client-certificate challenges, and keeps the metrics.
private final class ExchangeDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    struct State {
        var metrics: URLSessionTaskMetrics?
        var presentedClientCertificate = false
        var trustFailure: String?
        /// A redirect has left the original origin; credentials stay off every later hop, even one back.
        var leftOrigin = false
        /// A redirect was followed, so the response's URL is not the one the summary shows.
        var redirected = false
    }

    /// Credentials URLSession would otherwise carry to whatever origin a redirect names: it forwards `Cookie` and
    /// custom headers (an API key) to any host.
    static let redirectStrippedHeaders: Set<String> = ["authorization", "proxy-authorization", "cookie"]
    /// What URLSession drops on every redirect, same origin included, and a same-origin hop must put back, or Bearer
    /// and Basic auth fail on a plain `/items` → `/items/`.
    private static let redirectRestoredHeaders = ["Authorization", "Proxy-Authorization"]

    let followRedirects: Bool
    let verifiesServer: Bool
    let tls: TLSContext
    /// Lower-cased header names removed when a redirect leaves the original origin.
    let credentialHeaderNames: Set<String>
    private let pool: HTTPSessionPool
    private let state = Mutex(State())

    init(followRedirects: Bool, verifiesServer: Bool, tls: TLSContext, credentialHeaderNames: Set<String>, pool: HTTPSessionPool) {
        self.followRedirects = followRedirects
        self.verifiesServer = verifiesServer
        self.tls = tls
        self.credentialHeaderNames = credentialHeaderNames
        self.pool = pool
    }

    /// Runs synchronously before the task starts, so a task created just after `HTTPExecutor.invalidate()` (by a
    /// request that leased its session first) is cancelled rather than sent.
    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        if pool.isInvalidated {
            task.cancel()
        }
    }

    func snapshot() -> State {
        state.withLock { $0 }
    }

    func translate(_ error: any Error) -> HTTPExecutionError {
        if let trustFailure = state.withLock({ $0.trustFailure }) {
            return .untrustedServer(trustFailure)
        }
        guard let urlError = error as? URLError else {
            return error is CancellationError ? .cancelled : .transport(error.localizedDescription)
        }
        switch urlError.code {
        case .cancelled:
            return .cancelled
        case .timedOut:
            return .timedOut
        default:
            return .transport(urlError.localizedDescription)
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        // Returning nil hands back the redirect response itself, body and all.
        guard followRedirects else {
            return nil
        }
        state.withLock { $0.redirected = true }
        guard let originalRequest = task.originalRequest, let original = originalRequest.url, let target = request.url else {
            return request
        }
        // Compared with the original request, as cURL does, and remembered, so a hop back cannot reclaim them.
        let leftOrigin = state.withLock { state in
            state.leftOrigin = state.leftOrigin || !Self.sameOrigin(original, target)
            return state.leftOrigin
        }
        var next = request
        if leftOrigin {
            for name in (request.allHTTPHeaderFields ?? [:]).keys where credentialHeaderNames.contains(name.lowercased()) {
                next.setValue(nil, forHTTPHeaderField: name)
            }
        } else {
            for name in Self.redirectRestoredHeaders where next.value(forHTTPHeaderField: name) == nil {
                if let value = originalRequest.value(forHTTPHeaderField: name) {
                    next.setValue(value, forHTTPHeaderField: name)
                }
            }
        }
        return next
    }

    private static func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        Origin(lhs) == Origin(rhs)
    }

    /// Scheme, host, and port, with the scheme's default port filled in so `https://a` and `https://a:443` match.
    private struct Origin: Equatable {
        let scheme: String
        let host: String
        let port: Int?

        init(_ url: URL) {
            scheme = url.scheme?.lowercased() ?? ""
            host = url.host?.lowercased() ?? ""
            port = url.port ?? (scheme == "https" ? 443 : scheme == "http" ? 80 : nil)
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let space = challenge.protectionSpace
        switch space.authenticationMethod {
        case NSURLAuthenticationMethodServerTrust:
            guard let trust = space.serverTrust else {
                return (.performDefaultHandling, nil)
            }
            if !verifiesServer {
                return (.useCredential, URLCredential(trust: trust))
            }
            guard !tls.anchors.isEmpty else {
                return (.performDefaultHandling, nil)
            }
            switch TLSTrustEvaluator.evaluate(trust, host: space.host, anchors: tls.anchors) {
            case .success:
                return (.useCredential, URLCredential(trust: trust))
            case .failure(let error):
                state.withLock { $0.trustFailure = error.localizedDescription }
                return (.cancelAuthenticationChallenge, nil)
            }
        case NSURLAuthenticationMethodClientCertificate:
            guard let identity = tls.clientIdentity(space.host, space.port > 0 ? space.port : nil) else {
                // Proceed without a certificate; a server that requires one rejects the handshake itself.
                return (.performDefaultHandling, nil)
            }
            state.withLock { $0.presentedClientCertificate = true }
            // `.none`: each new connection asks again, so the credential store never answers for the delegate. No
            // intermediates must be `nil`, not empty: CFNetwork reads the first element of any array it gets and traps.
            let intermediates = identity.intermediates.isEmpty ? nil : identity.intermediates
            return (.useCredential, URLCredential(identity: identity.identity, certificates: intermediates, persistence: .none))
        default:
            return (.performDefaultHandling, nil)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        state.withLock { $0.metrics = metrics }
    }
}
