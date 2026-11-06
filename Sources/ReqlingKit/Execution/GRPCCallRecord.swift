import Foundation

/// What a gRPC call did, for display and the run history: everything shown is masked.
public struct GRPCCallRecord: Hashable, Sendable, Codable {
    /// The most events a record keeps. A long stream keeps its newest ones and counts the rest in
    /// `trimmedEventCount`, so neither memory nor each live update grows with the stream's length.
    public static let eventLimit = 2_000

    /// The resolved target, masked.
    public var target: String
    /// `service/method`.
    public var method: String
    public var kind: GRPCMethodKind
    /// Request metadata as sent, masked.
    public var sentMetadata: [KeyValuePair]
    public var initialMetadata: [KeyValuePair]
    public var trailers: [KeyValuePair]
    /// Messages both ways, in the order they crossed the wire: all of them, or the newest when some were omitted.
    /// Each one's `sequence` is its place in the whole call, so gaps show where messages were left out.
    public var events: [GRPCMessageEvent]
    /// Every message the call sent or received, `events` and omitted ones alike.
    public var sentCount: Int
    public var receivedCount: Int
    /// The oldest messages, cut to keep `eventLimit` (or to fit the run history); all come before `events`.
    public var trimmedEventCount: Int
    /// Messages the app never recorded: dropped while it fell behind a fast stream, or still queued when the call
    /// was cancelled. They can fall between kept events.
    public var droppedEventCount: Int
    /// `nil` while the call is still open.
    public var status: GRPCStatusRecord?
    public var duration: TimeInterval

    /// Every message left out of `events`, for whatever reason.
    public var omittedEventCount: Int {
        trimmedEventCount + droppedEventCount
    }

    public init(
        target: String,
        method: String,
        kind: GRPCMethodKind,
        sentMetadata: [KeyValuePair] = [],
        initialMetadata: [KeyValuePair] = [],
        trailers: [KeyValuePair] = [],
        events: [GRPCMessageEvent] = [],
        status: GRPCStatusRecord? = nil,
        duration: TimeInterval = 0,
        sentCount: Int? = nil,
        receivedCount: Int? = nil,
        trimmedEventCount: Int = 0,
        droppedEventCount: Int = 0
    ) {
        self.target = target
        self.method = method
        self.kind = kind
        self.sentMetadata = sentMetadata
        self.initialMetadata = initialMetadata
        self.trailers = trailers
        self.events = events
        self.status = status
        self.duration = duration
        self.sentCount = sentCount ?? events.count { $0.direction == .sent }
        self.receivedCount = receivedCount ?? events.count { $0.direction == .received }
        self.trimmedEventCount = trimmedEventCount
        self.droppedEventCount = droppedEventCount
    }

    private enum CodingKeys: String, CodingKey {
        case target, method, kind, sentMetadata, initialMetadata, trailers, events, status, duration
        case sentCount, receivedCount, trimmedEventCount, droppedEventCount
        /// Read only: a record cached before the split had one count of oldest-first omissions.
        case omittedEventCount
    }

    /// The counts and sequences are newer than the cache format. A record cached without them gets its omissions
    /// counted as trimmed (the only kind it had), sequences from each event's place after those, and totals from
    /// its events, its omissions counted as received, the direction a long stream floods.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        target = try container.decode(String.self, forKey: .target)
        method = try container.decode(String.self, forKey: .method)
        kind = try container.decode(GRPCMethodKind.self, forKey: .kind)
        sentMetadata = try container.decode([KeyValuePair].self, forKey: .sentMetadata)
        initialMetadata = try container.decode([KeyValuePair].self, forKey: .initialMetadata)
        trailers = try container.decode([KeyValuePair].self, forKey: .trailers)
        status = try container.decodeIfPresent(GRPCStatusRecord.self, forKey: .status)
        duration = try container.decode(TimeInterval.self, forKey: .duration)
        let legacyOmitted = try container.decodeIfPresent(Int.self, forKey: .omittedEventCount) ?? 0
        droppedEventCount = try container.decodeIfPresent(Int.self, forKey: .droppedEventCount) ?? 0
        trimmedEventCount = try container.decodeIfPresent(Int.self, forKey: .trimmedEventCount) ?? legacyOmitted
        var events = try container.decode([GRPCMessageEvent].self, forKey: .events)
        let sequences = try container.decode([SequenceProbe].self, forKey: .events)
        for index in events.indices where sequences[index].sequence == nil {
            events[index].sequence = trimmedEventCount + index
        }
        self.events = events
        sentCount = try container.decodeIfPresent(Int.self, forKey: .sentCount) ?? events.count { $0.direction == .sent }
        receivedCount = try container.decodeIfPresent(Int.self, forKey: .receivedCount)
            ?? events.count { $0.direction == .received } + trimmedEventCount + droppedEventCount
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(target, forKey: .target)
        try container.encode(method, forKey: .method)
        try container.encode(kind, forKey: .kind)
        try container.encode(sentMetadata, forKey: .sentMetadata)
        try container.encode(initialMetadata, forKey: .initialMetadata)
        try container.encode(trailers, forKey: .trailers)
        try container.encode(events, forKey: .events)
        try container.encodeIfPresent(status, forKey: .status)
        try container.encode(duration, forKey: .duration)
        try container.encode(sentCount, forKey: .sentCount)
        try container.encode(receivedCount, forKey: .receivedCount)
        try container.encode(trimmedEventCount, forKey: .trimmedEventCount)
        try container.encode(droppedEventCount, forKey: .droppedEventCount)
    }

    /// Whether an encoded event carries its sequence; one cached before sequences existed does not.
    private struct SequenceProbe: Decodable {
        let sequence: Int?
    }

    /// The record cut to fit the run history: each message's JSON to `messageLimit` UTF-8 bytes, then the oldest
    /// messages dropped until the rest total `totalLimit`. `wasCut` says whether anything changed.
    func fittingCache(messageLimit: Int, totalLimit: Int) -> (record: GRPCCallRecord, wasCut: Bool) {
        var record = self
        var wasCut = false
        for index in record.events.indices where record.events[index].json.utf8.count > messageLimit {
            record.events[index].json = record.events[index].json.prefix(utf8Count: messageLimit)
            wasCut = true
        }
        var total = 0
        var keptFrom = record.events.endIndex
        while keptFrom > record.events.startIndex {
            let size = record.events[keptFrom - 1].json.utf8.count
            guard total + size <= totalLimit else {
                break
            }
            total += size
            keptFrom -= 1
        }
        if keptFrom > record.events.startIndex {
            record.trimmedEventCount += keptFrom
            record.events.removeFirst(keptFrom)
            wasCut = true
        }
        return (record, wasCut)
    }
}

/// A gRPC status: a code (0 is OK), its canonical name, and the server's message.
public struct GRPCStatusRecord: Hashable, Sendable, Codable {
    public var code: Int
    public var name: String
    public var message: String

    public init(code: Int, name: String, message: String) {
        self.code = code
        self.name = name
        self.message = message
    }

    public var isOK: Bool {
        code == 0
    }
}

/// One message on a call's timeline.
public struct GRPCMessageEvent: Hashable, Sendable, Codable {
    public typealias Direction = MessageDirection

    public var direction: Direction
    /// Seconds since the call started.
    public var offset: TimeInterval
    /// Proto3 JSON; masked for sent messages.
    public var json: String
    public var byteCount: Int
    /// The message's 0-based place among every message the call sent or received, both directions together. Kept
    /// through trimming, so it numbers a message the same in every update.
    public var sequence: Int
    /// Fields of a received message that `json` leaves out because the schema does not define them; see
    /// `ProtobufJSONCodec.decodeCountingUnknownFields(_:as:)`.
    public var unknownFieldCount: Int

    public init(direction: Direction, offset: TimeInterval, json: String, byteCount: Int, sequence: Int = 0, unknownFieldCount: Int = 0) {
        self.direction = direction
        self.offset = offset
        self.json = json
        self.byteCount = byteCount
        self.sequence = sequence
        self.unknownFieldCount = unknownFieldCount
    }

    private enum CodingKeys: String, CodingKey {
        case direction, offset, json, byteCount, sequence, unknownFieldCount
    }

    /// A message cached before sequences existed decodes as 0; `GRPCCallRecord` renumbers it from its place.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        direction = try container.decode(Direction.self, forKey: .direction)
        offset = try container.decode(TimeInterval.self, forKey: .offset)
        json = try container.decode(String.self, forKey: .json)
        byteCount = try container.decode(Int.self, forKey: .byteCount)
        sequence = try container.decodeIfPresent(Int.self, forKey: .sequence) ?? 0
        unknownFieldCount = try container.decodeIfPresent(Int.self, forKey: .unknownFieldCount) ?? 0
    }
}
