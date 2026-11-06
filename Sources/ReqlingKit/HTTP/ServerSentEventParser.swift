import Foundation

/// One event an event-stream response dispatched.
public struct ServerSentEvent: Hashable, Sendable, Codable {
    /// The `event` field, or `message` when the stream named none.
    public var type: String
    /// The stream's last event ID when this event fired, the one a reconnect would send; `nil` while it is empty.
    public var id: String?
    /// The `data` lines, joined with newlines.
    public var data: String

    public init(type: String = "message", id: String? = nil, data: String) {
        self.type = type
        self.id = id
        self.data = data
    }
}

/// What `ServerSentEventParser` reads from a stream, in order.
public enum ServerSentEventField: Hashable, Sendable {
    case event(ServerSentEvent)
    /// The stream's last event ID changed: what a reconnect sends as `Last-Event-ID`, which it leaves out while empty.
    case lastEventID(String)
    /// The server set its reconnection delay, in milliseconds.
    case retry(Int)
}

/// Reads a `text/event-stream` body as it arrives, following the WHATWG "event stream interpretation" rules.
///
/// Bytes come in whatever chunks the network delivers, so a line, a UTF-8 sequence, or a CRLF can straddle two of
/// them: everything up to the last line break is read at once, and the rest waits for the next chunk. Lines are
/// decoded only once whole, since CR and LF never occur inside a UTF-8 sequence. A trailing event that no blank line
/// ends is never dispatched, as the spec says of a stream that ends mid-event.
public struct ServerSentEventParser: Sendable {
    private var line: [UInt8] = []
    /// The last line ended with CR, so an LF that starts the next chunk belongs to it.
    private var endedWithCR = false
    /// A UTF-8 byte order mark may start the stream, and only the stream.
    private var isFirstLine = true
    private var type = ""
    private var data = ""
    private var hasData = false
    private var lastEventIDBuffer = ""
    /// The last event ID as last reported, so `.lastEventID` comes only when it changes.
    private var lastEventID = ""

    public init() {}

    /// Everything `bytes` completes, in stream order.
    public mutating func parse(_ bytes: some Sequence<UInt8>) -> [ServerSentEventField] {
        var fields: [ServerSentEventField] = []
        for byte in bytes {
            switch byte {
            case UInt8(ascii: "\n") where endedWithCR:
                endedWithCR = false
            case UInt8(ascii: "\n"), UInt8(ascii: "\r"):
                endedWithCR = byte == UInt8(ascii: "\r")
                finishLine(into: &fields)
            default:
                endedWithCR = false
                line.append(byte)
            }
        }
        return fields
    }

    private mutating func finishLine(into fields: inout [ServerSentEventField]) {
        defer {
            line.removeAll(keepingCapacity: true)
            isFirstLine = false
        }
        if isFirstLine, line.starts(with: [0xEF, 0xBB, 0xBF]) {
            line.removeFirst(3)
        }
        guard !line.isEmpty else {
            dispatch(into: &fields)
            return
        }
        let text = Self.decode(line)
        guard !text.hasPrefix(":") else {
            return
        }
        let name: Substring
        var value: Substring
        if let colon = text.firstIndex(of: ":") {
            name = text[..<colon]
            value = text[text.index(after: colon)...]
            if value.first == " " {
                value = value.dropFirst()
            }
        } else {
            name = text[...]
            value = ""
        }
        switch name {
        case "event":
            type = String(value)
        case "data":
            data += (hasData ? "\n" : "") + value
            hasData = true
        case "id" where !value.contains("\u{0}"):
            lastEventIDBuffer = String(value)
        case "retry" where !value.isEmpty && value.unicodeScalars.allSatisfy({ ("0"..."9").contains($0) }):
            if let milliseconds = Int(value) {
                fields.append(.retry(milliseconds))
            }
        default:
            break
        }
    }

    /// The spec decodes the stream as UTF-8 with replacement: one bad byte becomes U+FFFD, rather than losing the line.
    private static func decode(_ line: [UInt8]) -> String {
        // swiftlint:disable:next optional_data_string_conversion
        String(decoding: line, as: UTF8.self)
    }

    /// A blank line: the last event ID takes the buffer's value whether or not an event fires, then any data fires.
    private mutating func dispatch(into fields: inout [ServerSentEventField]) {
        if lastEventIDBuffer != lastEventID {
            lastEventID = lastEventIDBuffer
            fields.append(.lastEventID(lastEventID))
        }
        defer {
            type = ""
            data = ""
            hasData = false
        }
        guard hasData else {
            return
        }
        fields.append(.event(ServerSentEvent(
            type: type.isEmpty ? "message" : type,
            id: lastEventID.isEmpty ? nil : lastEventID,
            data: data
        )))
    }
}
