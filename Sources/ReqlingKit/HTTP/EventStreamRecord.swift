import Foundation

/// An event-stream response's timeline, which `HTTPResponseRecord.eventStream` holds in place of a body: its events
/// and what happened to its connection, across every reconnect, with everything shown masked.
public struct EventStreamRecord: Hashable, Sendable, Codable {
    /// The most entries a record keeps, as `GRPCCallRecord.eventLimit` does for a call: a long stream keeps its newest
    /// and counts the rest in `trimmedEntryCount`, so neither memory nor each live update grows with its length.
    public static let entryLimit = 2_000

    /// Why a stream stopped; `nil` while it is open.
    public enum End: Hashable, Sendable, Codable {
        /// The server ended the response, and the stream did not reconnect.
        case closed
        /// Stopped from the window, or by an agent's `cancel_request`.
        case stopped
        /// An agent's time or event bound (`RunOptions.streamLimit`) was reached.
        case limit
        /// Silent for longer than the request's timeout, the idle timeout URLSession applies between bytes.
        case timedOut
        case failed(message: String)

        /// Whether the stream ended on its own terms or someone's; a lost connection or a refused reconnect is a failure.
        public var isFailure: Bool {
            switch self {
            case .closed, .stopped, .limit: false
            case .timedOut, .failed: true
            }
        }
    }

    /// The newest entries, oldest first.
    public var entries: [EventStreamEntry]
    /// Every event the stream dispatched: those in `entries` and every one left out.
    public var eventCount: Int
    /// The oldest entries, cut to keep `entryLimit` (or to fit the run history); all come before `entries`.
    public var trimmedEntryCount: Int
    /// Events never recorded: dropped while the app fell behind a fast stream, or still queued when it stopped.
    public var droppedEventCount: Int
    /// Every byte of every connection's body, comments and field names included.
    public var receivedByteCount: Int
    public var reconnectCount: Int
    /// What a reconnect sends as `Last-Event-ID`; `nil` while the server has set none.
    public var lastEventID: String?
    /// The server's `retry:`, the delay before a reconnect; `nil` while it has sent none.
    public var retryMilliseconds: Int?
    public var end: End?

    public init(
        entries: [EventStreamEntry] = [],
        eventCount: Int? = nil,
        trimmedEntryCount: Int = 0,
        droppedEventCount: Int = 0,
        receivedByteCount: Int = 0,
        reconnectCount: Int = 0,
        lastEventID: String? = nil,
        retryMilliseconds: Int? = nil,
        end: End? = nil
    ) {
        self.entries = entries
        self.eventCount = eventCount ?? entries.count { $0.event != nil }
        self.trimmedEntryCount = trimmedEntryCount
        self.droppedEventCount = droppedEventCount
        self.receivedByteCount = receivedByteCount
        self.reconnectCount = reconnectCount
        self.lastEventID = lastEventID
        self.retryMilliseconds = retryMilliseconds
        self.end = end
    }

    /// The events among `entries`, without the notes.
    public var events: [ServerSentEvent] {
        entries.compactMap(\.event)
    }

    /// Whether a response is an event stream. Only a 200 is, as for a browser's `EventSource`; any other status, even
    /// with this type, is an error page to show whole. Media type parameters (`; charset=utf-8`) are ignored.
    public static func isEventStream(statusCode: Int, contentType: String?) -> Bool {
        guard statusCode == 200, let contentType else {
            return false
        }
        let mediaType = contentType.prefix { $0 != ";" }.trimmingCharacters(in: .whitespaces)
        return mediaType.caseInsensitiveCompare("text/event-stream") == .orderedSame
    }

    /// The record cut to fit the run history: each event's data to `dataLimit` UTF-8 bytes, then the oldest entries
    /// dropped until the rest's data totals `totalLimit`. `wasCut` says whether anything changed.
    func fittingCache(dataLimit: Int, totalLimit: Int) -> (record: EventStreamRecord, wasCut: Bool) {
        var record = self
        var wasCut = false
        for index in record.entries.indices {
            guard case .event(var event) = record.entries[index].kind, event.data.utf8.count > dataLimit else {
                continue
            }
            event.data = event.data.prefix(utf8Count: dataLimit)
            record.entries[index].kind = .event(event)
            wasCut = true
        }
        var total = 0
        var keptFrom = record.entries.endIndex
        while keptFrom > record.entries.startIndex {
            let size = record.entries[keptFrom - 1].event?.data.utf8.count ?? 0
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

/// One line on an event stream's timeline.
public struct EventStreamEntry: Hashable, Sendable, Codable, Identifiable {
    public enum Kind: Hashable, Sendable, Codable {
        case event(ServerSentEvent)
        /// What happened to the connection: the server closed it, it dropped, a reconnect is waiting or made.
        case note(String)
    }

    /// Its place in the whole stream, across reconnects: the same in every update however the kept window moves,
    /// so gaps show where entries were left out.
    public var sequence: Int
    /// Seconds since the run started.
    public var offset: TimeInterval
    public var kind: Kind
    /// The event's data as received, in UTF-8 bytes, kept apart from `data` because the run history may cut that;
    /// 0 for a note.
    public var byteCount: Int

    public init(sequence: Int, offset: TimeInterval, kind: Kind, byteCount: Int? = nil) {
        self.sequence = sequence
        self.offset = offset
        self.kind = kind
        if case .event(let event) = kind {
            self.byteCount = byteCount ?? event.data.utf8.count
        } else {
            self.byteCount = 0
        }
    }

    public var id: Int {
        sequence
    }

    public var event: ServerSentEvent? {
        if case .event(let event) = kind {
            return event
        }
        return nil
    }
}
