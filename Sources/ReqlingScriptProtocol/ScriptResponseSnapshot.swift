/// What a post-response script sees as `rq.response`, by how the request was answered.
public enum ScriptResponseSnapshot: Hashable, Sendable, Codable {
    case http(ScriptHTTPResponse)
    case eventStream(ScriptEventStreamResponse)
    case grpc(ScriptGRPCResponse)
    case webSocket(ScriptWebSocketResponse)

    /// The name `rq.response` members are documented under (`ScriptAPICatalog`).
    public var kind: ScriptResponseKind {
        switch self {
        case .http: .http
        case .eventStream: .eventStream
        case .grpc: .grpc
        case .webSocket: .webSocket
        }
    }
}

/// How a request was answered, which decides what `rq.response` holds.
public enum ScriptResponseKind: String, Hashable, Sendable, Codable, CaseIterable {
    case http
    case eventStream
    case grpc
    case webSocket
}

public struct ScriptHTTPResponse: Hashable, Sendable, Codable {
    public var code: Int
    public var status: String
    public var headers: [ScriptRow]
    public var body: ScriptBlob
    /// The body's size as received, which `truncated` says the blob fell short of.
    public var size: Int
    public var truncated: Bool
    /// Milliseconds.
    public var responseTime: Double

    public init(code: Int, status: String, headers: [ScriptRow], body: ScriptBlob, size: Int, truncated: Bool, responseTime: Double) {
        self.code = code
        self.status = status
        self.headers = headers
        self.body = body
        self.size = size
        self.truncated = truncated
        self.responseTime = responseTime
    }
}

public struct ScriptEventStreamResponse: Hashable, Sendable, Codable {
    public var code: Int
    public var status: String
    public var headers: [ScriptRow]
    public var events: [ScriptStreamEvent]
    /// How the stream ended: `closed`, `stopped`, `limit`, `timedOut`, or `failed`.
    public var end: String
    /// Events the run kept no record of, beyond those listed.
    public var omittedEventCount: Int
    public var responseTime: Double

    public init(
        code: Int,
        status: String,
        headers: [ScriptRow],
        events: [ScriptStreamEvent],
        end: String,
        omittedEventCount: Int,
        responseTime: Double
    ) {
        self.code = code
        self.status = status
        self.headers = headers
        self.events = events
        self.end = end
        self.omittedEventCount = omittedEventCount
        self.responseTime = responseTime
    }
}

public struct ScriptStreamEvent: Hashable, Sendable, Codable {
    public var id: String?
    public var event: String?
    public var data: String
    public var retry: Int?

    public init(id: String?, event: String?, data: String, retry: Int?) {
        self.id = id
        self.event = event
        self.data = data
        self.retry = retry
    }
}

public struct ScriptGRPCResponse: Hashable, Sendable, Codable {
    /// `nil` for a call that ended without a status.
    public var statusCode: Int?
    public var statusName: String?
    public var statusMessage: String?
    public var metadata: [ScriptRow]
    public var trailers: [ScriptRow]
    /// Received messages as JSON text, in order.
    public var messages: [String]
    public var sentCount: Int
    public var receivedCount: Int
    public var responseTime: Double

    public init(
        statusCode: Int?,
        statusName: String?,
        statusMessage: String?,
        metadata: [ScriptRow],
        trailers: [ScriptRow],
        messages: [String],
        sentCount: Int,
        receivedCount: Int,
        responseTime: Double
    ) {
        self.statusCode = statusCode
        self.statusName = statusName
        self.statusMessage = statusMessage
        self.metadata = metadata
        self.trailers = trailers
        self.messages = messages
        self.sentCount = sentCount
        self.receivedCount = receivedCount
        self.responseTime = responseTime
    }
}

public struct ScriptWebSocketResponse: Hashable, Sendable, Codable {
    /// The handshake's status; `nil` when no handshake response was kept.
    public var code: Int?
    public var headers: [ScriptRow]
    public var subprotocol: String?
    public var messages: [ScriptSocketMessage]
    public var closeCode: Int?
    public var closeReason: String?
    /// How the connection ended: `closed`, `refused`, `stopped`, `limit`, or `failed`.
    public var end: String
    public var responseTime: Double

    public init(
        code: Int?,
        headers: [ScriptRow],
        subprotocol: String?,
        messages: [ScriptSocketMessage],
        closeCode: Int?,
        closeReason: String?,
        end: String,
        responseTime: Double
    ) {
        self.code = code
        self.headers = headers
        self.subprotocol = subprotocol
        self.messages = messages
        self.closeCode = closeCode
        self.closeReason = closeReason
        self.end = end
        self.responseTime = responseTime
    }
}

public struct ScriptSocketMessage: Hashable, Sendable, Codable {
    /// `sent` or `received`.
    public var direction: String
    /// The text of a text message; `nil` for a binary one.
    public var text: String?
    /// The bytes of a binary message, base64.
    public var base64: String?

    public init(direction: String, text: String?, base64: String?) {
        self.direction = direction
        self.text = text
        self.base64 = base64
    }
}
