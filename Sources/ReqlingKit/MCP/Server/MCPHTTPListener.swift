import Foundation
import MCP
import Network
import Synchronization

/// Reqling's MCP endpoint: `POST /mcp` on IPv4 loopback, one request per connection.
///
/// Every request is checked here before the SDK transport sees it: the `Host` must name the loopback address and this
/// port (a DNS-rebinding page cannot), an `Origin`, when sent, must too (a browser page cannot), and the bearer token
/// must match, compared in constant time. The transport validates again with its own pipeline.
final class MCPHTTPListener: @unchecked Sendable {
    static let path = "/mcp"

    struct Limits {
        var maxBodyBytes = 1_000_000
        /// Tool output is bounded by `MCPToolDispatcher.outputLimit`; JSON-RPC escaping can inflate it severalfold.
        var maxResponseBytes = 8_000_000
        var maxHeaderBytes = 64 * 1_024
        var startupTimeout: DispatchTimeInterval = .seconds(5)
        /// How long a client has to send a whole request. Handling it is bounded by each tool's own timeout instead,
        /// since a run can rightly take minutes.
        var receiveTimeout: DispatchTimeInterval = .seconds(15)
    }

    private let limits: Limits
    private let queue = DispatchQueue(label: "com.afollestad.reqling.mcp.listener")
    private let lock = NSLock()
    private var listener: NWListener?
    private var readyPort: Int?
    private var transport: StatelessHTTPServerTransport?
    private var token: MCPTokenBox?
    private var connections: [UUID: NWConnection] = [:]
    /// Called when a listener that was ready fails, such as when the network stack resets.
    private var onUnexpectedStop: (@Sendable (String) -> Void)?

    init(limits: Limits = Limits()) {
        self.limits = limits
    }

    var activePort: Int? {
        lock.withLock { readyPort }
    }

    /// Listens on `port` (0 picks a free one) and returns the port it got. Throws `MCPServerError.portInUse` when
    /// another process holds the port.
    func start(
        port: Int,
        transport: StatelessHTTPServerTransport,
        token: MCPTokenBox,
        onUnexpectedStop: @escaping @Sendable (String) -> Void
    ) async throws -> Int {
        guard let endpointPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else {
            throw MCPServerError.invalidPort(port)
        }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: port == 0 ? .any : endpointPort)
        let listener = try NWListener(using: parameters)
        lock.withLock {
            self.listener = listener
            self.transport = transport
            self.token = token
            self.onUnexpectedStop = onUnexpectedStop
            readyPort = nil
        }
        return try await waitUntilReady(listener, requestedPort: port)
    }

    func stop() {
        let (listener, connections) = lock.withLock {
            let current = (self.listener, Array(self.connections.values))
            self.listener = nil
            readyPort = nil
            transport = nil
            token = nil
            onUnexpectedStop = nil
            self.connections.removeAll()
            return current
        }
        connections.forEach { $0.cancel() }
        listener?.cancel()
    }

    // MARK: - Startup

    private func waitUntilReady(_ listener: NWListener, requestedPort: Int) async throws -> Int {
        try await withCheckedThrowingContinuation { continuation in
            let startup = StartupState(continuation)
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                guard let self, let listener else {
                    return
                }
                handle(state, of: listener, startup: startup, requestedPort: requestedPort)
            }
            listener.newConnectionHandler = { [weak self, weak listener] connection in
                guard let self, let listener else {
                    connection.cancel()
                    return
                }
                accept(connection, from: listener)
            }
            listener.start(queue: queue)
            queue.asyncAfter(deadline: .now() + limits.startupTimeout) { [weak self, weak listener] in
                guard let listener, let continuation = startup.take() else {
                    return
                }
                self?.discard(listener)
                continuation.resume(throwing: MCPServerError.startupTimedOut)
            }
        }
    }

    private func handle(_ state: NWListener.State, of listener: NWListener, startup: StartupState, requestedPort: Int) {
        switch state {
        case .ready:
            guard let continuation = startup.take() else {
                return
            }
            guard let port = listener.port.map({ Int($0.rawValue) }) else {
                discard(listener)
                continuation.resume(throwing: MCPServerError.startupTimedOut)
                return
            }
            lock.withLock {
                if self.listener === listener {
                    readyPort = port
                }
            }
            continuation.resume(returning: port)
        case .failed(let error):
            let wasReady = lock.withLock { self.listener === listener && readyPort != nil }
            let onUnexpectedStop = lock.withLock { self.onUnexpectedStop }
            discard(listener)
            if let continuation = startup.take() {
                continuation.resume(throwing: Self.startupError(error, port: requestedPort))
            } else if wasReady {
                onUnexpectedStop?(error.localizedDescription)
            }
        case .cancelled:
            startup.take()?.resume(throwing: MCPServerError.listenerFailed("The server was stopped."))
        default:
            break
        }
    }

    private static func startupError(_ error: NWError, port: Int) -> MCPServerError {
        if case .posix(let code) = error, code == .EADDRINUSE {
            return .portInUse(port)
        }
        return .listenerFailed(error.localizedDescription)
    }

    /// Clears `listener` if it is still the current one, and cancels it with its connections.
    private func discard(_ listener: NWListener) {
        let connections: [NWConnection] = lock.withLock {
            guard self.listener === listener else {
                return []
            }
            self.listener = nil
            readyPort = nil
            defer { self.connections.removeAll() }
            return Array(self.connections.values)
        }
        connections.forEach { $0.cancel() }
        listener.cancel()
    }

    // MARK: - Connections

    private func accept(_ connection: NWConnection, from listener: NWListener) {
        let id = UUID()
        let accepted = lock.withLock {
            guard self.listener === listener else {
                return false
            }
            connections[id] = connection
            return true
        }
        guard accepted else {
            connection.cancel()
            return
        }
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .cancelled, .failed:
                self?.forget(id)
            default:
                break
            }
        }
        connection.start(queue: queue)
        let deadline = ReceiveDeadline()
        queue.asyncAfter(deadline: .now() + limits.receiveTimeout) { [weak self] in
            if deadline.expire() {
                self?.finish(id, connection)
            }
        }
        receive(on: connection, id: id, buffer: Data(), deadline: deadline)
    }

    private func receive(on connection: NWConnection, id: UUID, buffer: Data, deadline: ReceiveDeadline) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self, error == nil else {
                self?.finish(id, connection)
                connection.cancel()
                return
            }
            var buffer = buffer
            if let data {
                buffer.append(data)
            }
            let parsed = MCPHTTPRequestParser.parse(buffer, maxHeaderBytes: limits.maxHeaderBytes, maxBodyBytes: limits.maxBodyBytes)
            if case .incomplete = parsed, !isComplete {
                receive(on: connection, id: id, buffer: buffer, deadline: deadline)
                return
            }
            guard deadline.complete() else {
                return
            }
            switch parsed {
            case .incomplete:
                send(400, on: connection, id: id)
            case .failure(let status):
                send(status, on: connection, id: id)
            case .request(let path, let request):
                handle(request, path: path, on: connection, id: id)
            }
        }
    }

    private func handle(_ request: HTTPRequest, path: String, on connection: NWConnection, id: UUID) {
        let (transport, token, port) = lock.withLock { (self.transport, self.token?.value, readyPort) }
        guard let transport, let token, let port else {
            send(503, on: connection, id: id)
            return
        }
        guard path == Self.path else {
            send(404, on: connection, id: id)
            return
        }
        if let status = Self.rejection(of: request, port: port, token: token) {
            send(status, headers: status == 401 ? [HTTPHeaderName.wwwAuthenticate: "Bearer"] : [:], on: connection, id: id)
            return
        }
        Task {
            let response = await transport.handleRequest(request)
            send(response.statusCode, headers: response.headers, body: response.bodyData, on: connection, id: id)
        }
    }

    /// The status to refuse `request` with, or `nil` to serve it.
    static func rejection(of request: HTTPRequest, port: Int, token: String) -> Int? {
        let hosts = ["127.0.0.1:\(port)", "localhost:\(port)"]
        guard let host = request.header(HTTPHeaderName.host), hosts.contains(host.lowercased()) else {
            return 421
        }
        if let origin = request.header(HTTPHeaderName.origin), !hosts.map({ "http://\($0)" }).contains(origin.lowercased()) {
            return 403
        }
        let prefix = "Bearer "
        guard let authorization = request.header(HTTPHeaderName.authorization), authorization.hasPrefix(prefix),
              constantTimeEqual(String(authorization.dropFirst(prefix.count)), token) else {
            return 401
        }
        return nil
    }

    static func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        var difference = left.count ^ right.count
        for index in 0..<max(left.count, right.count) {
            let leftByte = index < left.count ? left[index] : 0
            let rightByte = index < right.count ? right[index] : 0
            difference |= Int(leftByte ^ rightByte)
        }
        return difference == 0
    }

    private func send(_ status: Int, headers: [String: String] = [:], body: Data? = nil, on connection: NWConnection, id: UUID) {
        var body = body ?? Data()
        var status = status
        if body.count > limits.maxResponseBytes {
            body = Data()
            status = 500
        }
        var headers = headers
        headers["Content-Length"] = String(body.count)
        headers["Cache-Control"] = "no-store"
        headers["Connection"] = "close"
        let lines = headers.sorted { $0.key.lowercased() < $1.key.lowercased() }.map { "\($0.key): \($0.value)" }
        var data = Data("HTTP/1.1 \(status) \(Self.reason(status))\r\n\(lines.joined(separator: "\r\n"))\r\n\r\n".utf8)
        data.append(body)
        connection.send(content: data, completion: .contentProcessed { [weak self] _ in
            self?.finish(id, connection)
        })
    }

    private func finish(_ id: UUID, _ connection: NWConnection) {
        forget(id)
        connection.cancel()
    }

    private func forget(_ id: UUID) {
        _ = lock.withLock { connections.removeValue(forKey: id) }
    }

    private static func reason(_ status: Int) -> String {
        [
            200: "OK", 202: "Accepted", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden", 404: "Not Found",
            405: "Method Not Allowed", 406: "Not Acceptable", 413: "Content Too Large", 415: "Unsupported Media Type",
            421: "Misdirected Request", 500: "Internal Server Error", 503: "Service Unavailable"
        ][status] ?? "Error"
    }
}

/// The continuation `start` waits on, resumed exactly once by whichever of ready, failure, or timeout comes first.
private final class StartupState: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Int, any Error>?

    init(_ continuation: CheckedContinuation<Int, any Error>) {
        self.continuation = continuation
    }

    func take() -> CheckedContinuation<Int, any Error>? {
        lock.withLock {
            defer { continuation = nil }
            return continuation
        }
    }
}

/// Decides, once, whether a connection's request arrived before its receive timeout.
private final class ReceiveDeadline: @unchecked Sendable {
    private let lock = NSLock()
    private var isSettled = false

    /// True when the timeout won, so the caller closes the connection.
    func expire() -> Bool {
        settle()
    }

    /// True when the request won, so the caller answers it.
    func complete() -> Bool {
        settle()
    }

    private func settle() -> Bool {
        lock.withLock {
            defer { isSettled = true }
            return !isSettled
        }
    }
}

public enum MCPServerError: Error, Equatable, LocalizedError {
    case portInUse(Int)
    case invalidPort(Int)
    case startupTimedOut
    case listenerFailed(String)

    public var errorDescription: String? {
        switch self {
        case .portInUse(let port): "Port \(port) is in use by another app. Choose another port."
        case .invalidPort(let port): "\(port) is not a valid port."
        case .startupTimedOut: "The server didn't start listening in time."
        case .listenerFailed(let reason): "The server couldn't listen: \(reason)"
        }
    }
}

/// The current bearer token, read per request by the listener and the transport's validator, so regenerating it takes
/// effect at once without a restart.
final class MCPTokenBox: Sendable {
    private let token: Mutex<String>

    init(_ token: String) {
        self.token = Mutex(token)
    }

    var value: String {
        get { token.withLock { $0 } }
        set { token.withLock { $0 = newValue } }
    }
}

/// The transport's own token check, behind the listener's; see `MCPHTTPListener`.
struct MCPBearerTokenValidator: HTTPRequestValidator {
    let token: MCPTokenBox

    func validate(_ request: HTTPRequest, context: HTTPValidationContext) -> HTTPResponse? {
        let prefix = "Bearer "
        guard let authorization = request.header(HTTPHeaderName.authorization), authorization.hasPrefix(prefix),
              MCPHTTPListener.constantTimeEqual(String(authorization.dropFirst(prefix.count)), token.value) else {
            return .error(statusCode: 401, .invalidRequest("Unauthorized"), extraHeaders: [HTTPHeaderName.wwwAuthenticate: "Bearer"])
        }
        return nil
    }
}
