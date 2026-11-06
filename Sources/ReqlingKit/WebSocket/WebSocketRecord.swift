import Foundation

/// What a WebSocket connection did, for display and the run history: the server's answer to the handshake, every
/// message both ways with the pings and close frames between them, and how it ended. Everything sent is masked.
public struct WebSocketRecord: Hashable, Sendable, Codable {
    /// The most entries a record keeps, as `GRPCCallRecord.eventLimit` does for a call: a long connection keeps its
    /// newest and counts the rest in `trimmedEntryCount`, so neither memory nor each live update grows with its length.
    public static let entryLimit = 2_000

    /// Why a connection stopped; `nil` while it is open.
    public enum End: Hashable, Sendable, Codable {
        /// Closed with a close frame, by either side; `close` says who, with what code and reason.
        case closed
        /// Disconnected from the window, by an agent's `cancel_request`, or as Reqling quit.
        case stopped
        /// An agent's time or message bound (`RunOptions.streamLimit`) was reached.
        case limit
        /// The server answered the handshake without opening a connection; `handshake` holds its answer.
        case refused(message: String)
        /// The connection dropped without a close frame (1006), or the server broke the protocol.
        case failed(message: String)

        public var isFailure: Bool {
            switch self {
            case .closed, .stopped, .limit: false
            case .refused, .failed: true
            }
        }
    }

    /// A close frame: the first one sent, by whichever side sent it.
    public struct Close: Hashable, Sendable, Codable {
        /// `nil` when the frame carried no code (1005, No Status).
        public var code: Int?
        public var reason: String
        public var byServer: Bool

        public init(code: Int?, reason: String = "", byServer: Bool) {
            self.code = code
            self.reason = reason
            self.byServer = byServer
        }

        /// A close that means all went well: Normal Closure (1000), Going Away (1001), or no code at all.
        public var isNormal: Bool {
            code == nil || code == 1000 || code == 1001
        }

        /// The code and its registered name, such as "1000 Normal Closure", or "1005 No Status" for none.
        public var title: String {
            guard let code else {
                return "1005 No Status"
            }
            return WebSocketRecord.closeCodeNames[code].map { "\(code) \($0)" } ?? "\(code)"
        }
    }

    /// The URL connected to, masked.
    public var url: String
    /// The server's answer to the handshake: its 101 with timing and TLS, or a refusal with up to
    /// `WebSocketExecutor.refusalBodyLimit` of its body. `nil` until it answers.
    public var handshake: HTTPResponseRecord?
    public var subprotocol: String?
    /// The newest entries, oldest first; each one's `sequence` is its place in the whole connection, so gaps show where
    /// entries were left out.
    public var entries: [WebSocketEntry]
    /// Every message the connection sent or received, `entries` and omitted ones alike.
    public var sentCount: Int
    public var receivedCount: Int
    public var sentByteCount: Int
    public var receivedByteCount: Int
    /// The oldest entries, cut to keep `entryLimit` (or to fit the run history); all come before `entries`.
    public var trimmedEntryCount: Int
    /// Messages never recorded: dropped while the app fell behind a fast connection, or still queued when it ended.
    public var droppedEntryCount: Int
    public var close: Close?
    public var end: End?
    public var duration: TimeInterval

    public init(
        url: String,
        handshake: HTTPResponseRecord? = nil,
        subprotocol: String? = nil,
        entries: [WebSocketEntry] = [],
        sentCount: Int? = nil,
        receivedCount: Int? = nil,
        sentByteCount: Int? = nil,
        receivedByteCount: Int? = nil,
        trimmedEntryCount: Int = 0,
        droppedEntryCount: Int = 0,
        close: Close? = nil,
        end: End? = nil,
        duration: TimeInterval = 0
    ) {
        self.url = url
        self.handshake = handshake
        self.subprotocol = subprotocol
        self.entries = entries
        let messages = entries.compactMap(\.message)
        self.sentCount = sentCount ?? messages.count { $0.direction == .sent }
        self.receivedCount = receivedCount ?? messages.count { $0.direction == .received }
        self.sentByteCount = sentByteCount ?? entries.filter { $0.message?.direction == .sent }.reduce(0) { $0 + $1.byteCount }
        self.receivedByteCount = receivedByteCount ?? entries.filter { $0.message?.direction == .received }.reduce(0) { $0 + $1.byteCount }
        self.trimmedEntryCount = trimmedEntryCount
        self.droppedEntryCount = droppedEntryCount
        self.close = close
        self.end = end
        self.duration = duration
    }

    /// Every entry left out of `entries`, for whatever reason.
    public var omittedEntryCount: Int {
        trimmedEntryCount + droppedEntryCount
    }

    /// Whether the run went wrong: a refusal, a lost or broken connection, or a close with an abnormal code.
    public var isFailure: Bool {
        end?.isFailure == true || close.map { !$0.isNormal } == true
    }

    /// The registered close codes' names (RFC 6455 §7.4.1 and IANA's registry).
    public static let closeCodeNames: [Int: String] = [
        1000: "Normal Closure", 1001: "Going Away", 1002: "Protocol Error", 1003: "Unsupported Data",
        1005: "No Status", 1006: "Abnormal Closure", 1007: "Invalid Data", 1008: "Policy Violation",
        1009: "Message Too Big", 1010: "Mandatory Extension", 1011: "Internal Error", 1012: "Service Restart",
        1013: "Try Again Later", 1014: "Bad Gateway", 1015: "TLS Handshake"
    ]

    /// The record cut to fit the run history: each message's text to `messageLimit` UTF-8 bytes, then the oldest entries
    /// dropped until the rest total `totalLimit`, as `EventStreamRecord.fittingCache` cuts a stream. A refusal's body
    /// stays, since `HTTPResponseRecord`'s own limit already bounds it. `wasCut` says whether anything changed.
    func fittingCache(messageLimit: Int, totalLimit: Int) -> (record: WebSocketRecord, wasCut: Bool) {
        var record = self
        var wasCut = false
        for index in record.entries.indices {
            guard case .message(var message) = record.entries[index].kind, message.text.utf8.count > messageLimit else {
                continue
            }
            message.text = message.text.prefix(utf8Count: messageLimit)
            record.entries[index].kind = .message(message)
            wasCut = true
        }
        var total = 0
        var keptFrom = record.entries.endIndex
        while keptFrom > record.entries.startIndex {
            let size = record.entries[keptFrom - 1].message?.text.utf8.count ?? 0
            guard total + size <= totalLimit else {
                break
            }
            total += size
            keptFrom -= 1
        }
        if keptFrom > record.entries.startIndex {
            record.trimmedEntryCount += keptFrom
            record.entries.removeFirst(keptFrom)
            wasCut = true
        }
        return (record, wasCut)
    }
}

/// One line on a connection's timeline.
public struct WebSocketEntry: Hashable, Sendable, Codable, Identifiable {
    public enum Kind: Hashable, Sendable, Codable {
        case message(WebSocketMessageRecord)
        /// A ping, pong, or close frame, described ("Ping 3", "Pong 3 after 12 ms", "Close 1000 Normal Closure").
        case control(direction: MessageDirection, text: String)
        /// What happened to the connection: a close the server never answered, a message that couldn't be sent.
        case note(String)
    }

    public var sequence: Int
    /// Seconds since the run started.
    public var offset: TimeInterval
    public var kind: Kind
    /// A message's size as it crossed the wire, kept apart from its text, which the run history may cut; 0 otherwise.
    public var byteCount: Int

    public init(sequence: Int, offset: TimeInterval, kind: Kind, byteCount: Int = 0) {
        self.sequence = sequence
        self.offset = offset
        self.kind = kind
        self.byteCount = byteCount
    }

    public var id: Int {
        sequence
    }

    public var message: WebSocketMessageRecord? {
        if case .message(let message) = kind {
            return message
        }
        return nil
    }
}

/// A message as it crossed the wire.
public struct WebSocketMessageRecord: Hashable, Sendable, Codable {
    public var direction: MessageDirection
    public var format: WebSocketMessageFormat
    /// The text (masked when sent), or base64 for binary, and for text that wasn't valid UTF-8.
    public var text: String
    /// The text is base64: always for binary, and for text the server sent that wasn't valid UTF-8.
    public var isBase64: Bool

    public init(direction: MessageDirection, format: WebSocketMessageFormat, text: String, isBase64: Bool? = nil) {
        self.direction = direction
        self.format = format
        self.text = text
        self.isBase64 = isBase64 ?? (format == .binary)
    }
}
