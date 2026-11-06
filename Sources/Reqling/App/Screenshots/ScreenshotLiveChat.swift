#if DEBUG
import Foundation
import Network
import ReqlingKit
import Synchronization

/// The `websocket` scene's live connection, so the capture shows what only an open one has: the composer, each saved
/// message's Send button, and a timeline growing both ways. A WebSocket server on IPv4 loopback stands in for Acme's
/// support chat, answers each message with the next of `replies`, and pings after the last, and Support chat's
/// `{{baseUrl}}` is pointed at it. Then the editor connects, sends its saved question, and leaves a draft in the
/// composer, all through the same view model calls its buttons make. The server pings rather than the editor, since a
/// loopback round trip shows as "0 ms".
///
/// The timeline's offsets are real, so they differ between captures; the website's alt text leaves them out.
@MainActor
final class ScreenshotLiveChat {
    static let replies = ["Hi Grace, Ada here. How can I help?", "It ships today, tracking to follow."]
    static let draft = "Thanks! Can you send me the tracking link?"

    /// Runs the scene to its last step; awaited by tests, and by `ScreenshotMode`, which stops on a failure.
    private(set) var script: Task<Void, any Error>?
    private let server: ScreenshotChatServer

    /// `editor` is Support chat's, already shown; `project` is Acme API, whose `baseUrl` it repoints.
    init(editor: WebSocketEditorViewModel, project: ProjectID, library: ProjectLibrary) throws {
        let server = try ScreenshotChatServer(replies: Self.replies)
        self.server = server
        script = Task {
            let port = try await server.start()
            try library.mutate(project) { document in
                let variables = document.defaultEnvironment.variables
                if let index = variables.firstIndex(where: { $0.key == "baseUrl" }) {
                    document.defaultEnvironment.variables[index].value = "http://127.0.0.1:\(port)"
                }
            }
            try await Self.converse(through: editor)
        }
    }

    /// Ends the connection and the server; the app never calls it, since a capture ends by stopping the process.
    func stop() {
        script?.cancel()
        server.stop()
    }

    /// Each step waits for the last one's answer to land on the timeline, so the entries always come in this order.
    private static func converse(through editor: WebSocketEditorViewModel) async throws {
        editor.send()
        try await until(editor) { (editor.response.record?.receivedCount ?? 0) >= 1 }
        guard let question = editor.spec.messages.first(where: { !$0.sendsOnConnect }) else {
            throw ScreenshotChatError("Support chat has no saved message to send by hand.")
        }
        editor.sendSaved(question)
        try await until(editor) { editor.response.record?.entries.contains(where: \.isServerPing) == true }
        editor.liveMessage.text = draft
    }

    /// Returns once `condition` holds, re-checking whenever what it reads changes, so no step waits on a clock. Throws
    /// once the connection has ended without it, so a failed chat stops the app rather than settling into a capture.
    private static func until(_ editor: WebSocketEditorViewModel, _ condition: @escaping @MainActor () -> Bool) async throws {
        while !condition() {
            try Task.checkCancellation()
            if let exchange = editor.response.exchange, exchange.failure != nil || exchange.webSocket?.end != nil {
                throw ScreenshotChatError(exchange.failure?.message ?? "The connection ended before the chat finished.")
            }
            await withCheckedContinuation { continuation in
                withObservationTracking {
                    _ = condition()
                } onChange: {
                    continuation.resume()
                }
            }
        }
    }
}

private struct ScreenshotChatError: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}

extension WebSocketEntry {
    /// Only a server sends a ping the connection receives.
    var isServerPing: Bool {
        if case .control(.received, let text) = kind {
            return text.hasPrefix("Ping")
        }
        return false
    }
}

/// A WebSocket server on IPv4 loopback that accepts the first subprotocol offered, answers pings, replies to the n-th
/// text message with `replies[n]`, and pings once it has sent the last. Network framework does the handshake and
/// framing, so it needs nothing the app doesn't already link.
private final class ScreenshotChatServer: Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "ScreenshotChatServer")
    private let replies: [String]
    private let state = Mutex<(answered: Int, connections: [NWConnection])>((0, []))

    init(replies: [String]) throws {
        self.replies = replies
        let options = NWProtocolWebSocket.Options()
        options.autoReplyPing = true
        options.setClientRequestHandler(queue) { subprotocols, _ in
            NWProtocolWebSocket.Response(status: .accept, subprotocol: subprotocols.first)
        }
        let parameters = NWParameters.tcp
        parameters.defaultProtocolStack.applicationProtocols.insert(options, at: 0)
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
    }

    /// Starts listening and returns the port the system picked.
    func start() async throws -> UInt16 {
        // Weak, since the listener holds its handler for as long as it lives.
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else {
                connection.cancel()
                return
            }
            state.withLock { $0.connections.append(connection) }
            connection.start(queue: queue)
            receive(on: connection)
        }
        return try await withCheckedThrowingContinuation { continuation in
            let resumed = Mutex(false)
            listener.stateUpdateHandler = { [listener] state in
                let result: Result<UInt16, any Error>? = switch state {
                case .ready: listener.port.map { .success($0.rawValue) } ?? .failure(CocoaError(.featureUnsupported))
                case .failed(let error): .failure(error)
                case .cancelled: .failure(CancellationError())
                default: nil
                }
                guard let result else {
                    return
                }
                // A listener can fail or be cancelled after it was ready; only its first outcome answers `start`.
                let isFirst = resumed.withLock { resumed in
                    defer { resumed = true }
                    return !resumed
                }
                if isFirst {
                    continuation.resume(with: result)
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener.cancel()
        state.withLock { $0.connections }.forEach { $0.cancel() }
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [self] data, context, _, error in
            let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
            if metadata?.opcode == .text, data != nil {
                let index = state.withLock { state in
                    defer { state.answered += 1 }
                    return state.answered
                }
                if replies.indices.contains(index) {
                    send(replies[index], on: connection)
                }
                if index == replies.count - 1 {
                    ping(on: connection)
                }
            }
            if error == nil {
                receive(on: connection)
            }
        }
    }

    private func ping(on connection: NWConnection) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .ping)
        metadata.setPongHandler(queue) { _ in }
        let context = NWConnection.ContentContext(identifier: "ping", metadata: [metadata])
        connection.send(content: Data(), contentContext: context, isComplete: true, completion: .idempotent)
    }

    private func send(_ text: String, on connection: NWConnection) {
        let context = NWConnection.ContentContext(identifier: "reply", metadata: [NWProtocolWebSocket.Metadata(opcode: .text)])
        connection.send(content: Data(text.utf8), contentContext: context, isComplete: true, completion: .idempotent)
    }
}
#endif
