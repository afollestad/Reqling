import Foundation

/// One row of a message timeline, whatever the protocol: a gRPC message, an event-stream event, a WebSocket message or
/// control frame, or a note about the connection between them.
public struct TimelineItem: Hashable, Sendable {
    public enum Header: Hashable, Sendable {
        case grpc(direction: MessageDirection, unknownFieldCount: Int)
        case event(type: String, id: String?)
        /// `isBase64` for binary, and for text the server sent that wasn't valid UTF-8.
        case webSocket(direction: MessageDirection, format: WebSocketMessageFormat, isBase64: Bool)
        /// A WebSocket ping, pong, or close frame; `text` describes it.
        case control(direction: MessageDirection)
        case note
    }

    /// Its place in the whole call or stream: the same in every update however the kept window moves.
    public let sequence: Int
    /// Seconds since the run started.
    public let offset: TimeInterval
    /// The message or data as received; 0 for a note.
    public let byteCount: Int
    /// A message's JSON, an event's data, or a note's text: what the row shows and Copy Value copies.
    public let text: String
    public let header: Header

    public init(sequence: Int, offset: TimeInterval, byteCount: Int, text: String, header: Header) {
        self.sequence = sequence
        self.offset = offset
        self.byteCount = byteCount
        self.text = text
        self.header = header
    }

    public init(_ event: GRPCMessageEvent) {
        self.init(
            sequence: event.sequence,
            offset: event.offset,
            byteCount: event.byteCount,
            text: event.json,
            header: .grpc(direction: event.direction, unknownFieldCount: event.unknownFieldCount)
        )
    }

    public init(_ entry: EventStreamEntry) {
        switch entry.kind {
        case .event(let event):
            self.init(
                sequence: entry.sequence,
                offset: entry.offset,
                byteCount: entry.byteCount,
                text: event.data,
                header: .event(type: event.type, id: event.id)
            )
        case .note(let note):
            self.init(sequence: entry.sequence, offset: entry.offset, byteCount: 0, text: note, header: .note)
        }
    }

    public init(_ entry: WebSocketEntry) {
        switch entry.kind {
        case .message(let message):
            self.init(
                sequence: entry.sequence,
                offset: entry.offset,
                byteCount: entry.byteCount,
                text: message.text,
                header: .webSocket(direction: message.direction, format: message.format, isBase64: message.isBase64)
            )
        case .control(let direction, let text):
            self.init(sequence: entry.sequence, offset: entry.offset, byteCount: 0, text: text, header: .control(direction: direction))
        case .note(let note):
            self.init(sequence: entry.sequence, offset: entry.offset, byteCount: 0, text: note, header: .note)
        }
    }

    /// Whether `text` is JSON to index and highlight: a gRPC message always is, an event's data or a WebSocket's text
    /// when it starts like an object or array (servers send plain text too), and base64, control frames, and notes
    /// never.
    public var isJSON: Bool {
        switch header {
        case .grpc:
            return true
        case .event, .webSocket(_, _, isBase64: false):
            let first = text.unicodeScalars.first { !CharacterSet.whitespacesAndNewlines.contains($0) }
            return first == "{" || first == "["
        case .webSocket, .control, .note:
            return false
        }
    }
}

/// A gRPC call's messages or an event stream's events as one tree for Tree mode: each a top-level node over its JSON.
///
/// A live call or stream publishes a new timeline per update with the same `id`, so the tree updates in place: it adds
/// the new rows and drops the ones the record trimmed, keeping whatever someone expanded.
public struct MessageTimeline: Sendable {
    public struct Message: Sendable {
        public let item: TimelineItem
        /// `nil` when its text isn't JSON or doesn't parse, as when the run history cut a long message short.
        public let index: JSONStructureIndex?
        /// The top-level fields of a JSON object or array, which its row expands to.
        public let fields: [JSONEntry]

        public init(item: TimelineItem, index: JSONStructureIndex?) {
            self.item = item
            self.index = index
            fields = index.flatMap { index in index.rootEntries().first?.container.map { index.children(of: $0) } } ?? []
        }

        public init(event: GRPCMessageEvent, index: JSONStructureIndex?) {
            self.init(item: TimelineItem(event), index: index)
        }
    }

    public let id: UUID
    public let messages: [Message]

    public init(id: UUID, messages: [Message]) {
        self.id = id
        self.messages = messages
    }

    /// Matches inside each message, with paths that start at the message's position on the timeline. A row matches
    /// itself on its event's type and ID, or on text that isn't indexed, such as an event's plain data or a note.
    func find(_ query: String, limit: Int) throws(CancellationError) -> BodyTreeSearchResult {
        let rowQuery = TreeQuery(query)
        var matches: [BodyTreeMatch] = []
        for (position, message) in messages.enumerated() where matches.count < limit {
            if Self.rowMatches(message, rowQuery) {
                matches.append(BodyTreeMatch(path: [position]))
            }
            guard let index = message.index, matches.count < limit else {
                continue
            }
            let found = try index.find(query, limit: limit - matches.count)
            // A message's own path starts at its one top-level value, which the timeline shows as the message row.
            matches += found.matches.map { BodyTreeMatch(path: [position] + $0.path.dropFirst()) }
        }
        return BodyTreeSearchResult(matches: matches, isTruncated: matches.count >= limit)
    }

    private static func rowMatches(_ message: Message, _ query: TreeQuery) -> Bool {
        if message.index == nil, query.matches(message.item.text) {
            return true
        }
        guard case .event(let type, let id) = message.item.header else {
            return false
        }
        return query.matches(type) || id.map(query.matches) == true
    }
}
