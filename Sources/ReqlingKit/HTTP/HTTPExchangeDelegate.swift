import Foundation
import Security
import Synchronization

/// The per-exchange delegate: applies the redirect policy, evaluates server trust against the project's CAs, answers
/// client-certificate challenges, keeps the metrics, and collects the body, or reads it as events when it is an event
/// stream and the exchange asked for one.
///
/// Set as the task's own delegate after the task is created, so it never hears `urlSession(_:didCreateTask:)`;
/// `HTTPExecutor` checks the pool's invalidation itself before resuming the task.
final class ExchangeDelegate: NSObject, URLSessionDataDelegate, Sendable {
    struct State {
        var metrics: URLSessionTaskMetrics?
        var presentedClientCertificate = false
        var trustFailure: String?
        /// A redirect has left the original origin; credentials stay off every later hop, even one back.
        var leftOrigin = false
        /// A redirect was followed, so the response's URL is not the one the summary shows.
        var redirected = false
        var response: HTTPURLResponse?
        var body = Data()
        /// The response is an event stream, read as it arrives rather than collected into `body`.
        var isStream = false
        var parser = ServerSentEventParser()
        var receivedByteCount = 0
        /// How the task ended, translated; `nil` for success.
        var failure: HTTPExecutionError?
        var isComplete = false
        var waiter: CheckedContinuation<Void, Never>?
    }

    /// Where an event stream's events go, for `HTTPExecutor.executeStreaming`.
    struct Stream: Sendable {
        let buffer: LiveEventBuffer<HTTPStreamEvent>
        /// The response's head as the exchange would record it, built once the stream is detected.
        let head: @Sendable (HTTPURLResponse, State) -> HTTPResponseRecord
        let now: @Sendable () -> Date
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
    /// `nil` collects every body whole, an event stream's too.
    private let stream: Stream?
    private let state = Mutex(State())

    init(followRedirects: Bool, verifiesServer: Bool, tls: TLSContext, credentialHeaderNames: Set<String>, stream: Stream?) {
        self.followRedirects = followRedirects
        self.verifiesServer = verifiesServer
        self.tls = tls
        self.credentialHeaderNames = credentialHeaderNames
        self.stream = stream
    }

    func snapshot() -> State {
        state.withLock { $0 }
    }

    /// Resumes `task` and waits for it to end. A task cancelled before this, which URLSession may end without ever
    /// resuming, returns at once.
    func run(_ task: URLSessionDataTask) async {
        await withCheckedContinuation { continuation in
            let isComplete = state.withLock { state in
                if !state.isComplete {
                    state.waiter = continuation
                }
                return state.isComplete
            }
            if isComplete {
                continuation.resume()
            } else {
                task.resume()
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let waiter = state.withLock { state in
            state.failure = error.map { Self.translate($0, trustFailure: state.trustFailure) }
            state.isComplete = true
            defer { state.waiter = nil }
            return state.waiter
        }
        waiter?.resume()
    }

    private static func translate(_ error: any Error, trustFailure: String?) -> HTTPExecutionError {
        if let trustFailure {
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

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse) async -> URLSession.ResponseDisposition {
        let http = response as? HTTPURLResponse
        let opened = state.withLock { state -> HTTPResponseRecord? in
            state.response = http
            guard let stream, let http,
                  EventStreamRecord.isEventStream(statusCode: http.statusCode, contentType: http.value(forHTTPHeaderField: "Content-Type")) else {
                return nil
            }
            state.isStream = true
            return stream.head(http, state)
        }
        if let opened, let stream {
            stream.buffer.appendControl(.opened(opened, timestamp: stream.now()))
        }
        return .allow
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        // The session's delegate queue is serial, so chunks parse in order; the lock is for the other callbacks.
        let parsed = state.withLock { state -> (fields: [ServerSentEventField], receivedByteCount: Int)? in
            guard state.isStream else {
                state.body.append(data)
                return nil
            }
            state.receivedByteCount += data.count
            return (state.parser.parse(data), state.receivedByteCount)
        }
        guard let parsed, let stream else {
            return
        }
        let timestamp = stream.now()
        for field in parsed.fields {
            switch field {
            case .event(let event):
                stream.buffer.appendMessage(bytes: event.data.utf8.count, isSent: false) { sequence in
                    .event(event, sequence: sequence, receivedByteCount: parsed.receivedByteCount, timestamp: timestamp)
                }
            case .lastEventID(let id):
                stream.buffer.appendControl(.lastEventID(id))
            case .retry(let milliseconds):
                stream.buffer.appendControl(.retry(milliseconds: milliseconds))
            }
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
