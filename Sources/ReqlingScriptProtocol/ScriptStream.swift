import Foundation

/// What a stream phase's helper needs beyond what every phase gets: what the stream opened with, and whether a script
/// can reply on it yet.
public struct ScriptStreamSetup: Hashable, Sendable, Codable {
    public var opening: ScriptStreamOpening
    /// Whether the connection or call takes what `rq.send` sends: never for an event stream, and for a gRPC call only
    /// while its request stream is open. `ScriptRunnerMessage.sendingClosed` turns it off later.
    public var canSend: Bool

    public init(opening: ScriptStreamOpening, canSend: Bool) {
        self.opening = opening
        self.canSend = canSend
    }
}

/// `rq.response` in a stream script: what was known when the stream opened. The rest of a response is known only once
/// it ends, so only post-response scripts read it.
public enum ScriptStreamOpening: Hashable, Sendable, Codable {
    case eventStream(code: Int, status: String, headers: [ScriptRow])
    /// The handshake's status, `nil` when its response wasn't kept, as `ScriptWebSocketResponse.code` is.
    case webSocket(code: Int?, headers: [ScriptRow], subprotocol: String?)
    case grpc(metadata: [ScriptRow])

    /// The name `rq.response` members are documented under (`ScriptAPICatalog`).
    public var kind: ScriptResponseKind {
        switch self {
        case .eventStream: .eventStream
        case .webSocket: .webSocket
        case .grpc: .grpc
        }
    }
}

/// One event or message a stream received, as its handlers get it.
public struct ScriptStreamItem: Hashable, Sendable, Codable {
    public enum Content: Hashable, Sendable, Codable {
        /// An event stream's event, for `rq.onEvent`.
        case event(ScriptStreamEvent)
        /// A message the WebSocket connection received, for `rq.onMessage`.
        case socketMessage(ScriptSocketMessage)
        /// A message the gRPC call received, as JSON text, for `rq.onMessage`.
        case grpcMessage(String)
    }

    /// Its place among everything the stream received, from 1, counting what was dropped too, so a result names the
    /// same item however many before it reached no handler.
    public var number: Int
    public var content: Content

    public init(number: Int, content: Content) {
        self.number = number
        self.content = content
    }

    /// About how many bytes it holds, which bounds what waits for the handlers (`ScriptStreamWindow`).
    public var byteCount: Int {
        switch content {
        case .event(let event):
            event.data.utf8.count + (event.id?.utf8.count ?? 0) + (event.event?.utf8.count ?? 0)
        case .socketMessage(let message):
            (message.text?.utf8.count ?? 0) + (message.base64?.utf8.count ?? 0)
        case .grpcMessage(let json):
            json.utf8.count
        }
    }
}

/// A message a stream script sent with `rq.send`, as the script gave it: never `{{variables}}`-resolved, since scripts
/// treat `{{name}}` as plain text.
public enum ScriptOutgoingMessage: Hashable, Sendable, Codable {
    /// Text; for gRPC, the message as JSON.
    case text(String)
    /// A WebSocket binary message's bytes.
    case binary(Data)

    /// Its size as sent, in bytes.
    public var byteCount: Int {
        switch self {
        case .text(let text): text.utf8.count
        case .binary(let bytes): bytes.count
        }
    }
}
