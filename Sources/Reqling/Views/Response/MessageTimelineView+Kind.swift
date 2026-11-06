import ReqlingKit

/// What a timeline lists, for the words its notes use and the limit they quote.
enum MessageTimelineKind {
    /// A gRPC call's messages both ways.
    case call
    /// An event stream's events, with notes about its connection between them.
    case stream
    /// A WebSocket's messages both ways, with its pings, close frames, and notes between them.
    case connection

    /// What a skipped one is: always a message or an event, never a ping or note.
    func count(_ count: Int) -> String {
        let noun = self == .stream ? "event" : "message"
        return count == 1 ? "1 \(noun)" : "\(count) \(noun)s"
    }

    /// An entry of the timeline, as an earlier one left out is named.
    var singular: String {
        switch self {
        case .call: "message"
        case .stream: "event"
        case .connection: "entry"
        }
    }

    var plural: String {
        switch self {
        case .call: "messages"
        case .stream: "events"
        case .connection: "entries"
        }
    }

    /// What an open one waits for.
    var awaited: String {
        self == .stream ? "events" : "messages"
    }

    /// Why older entries are gone from a record nobody shortened.
    var windowNote: String {
        switch self {
        case .call: "a call keeps its newest \(GRPCCallRecord.eventLimit), or as many as fit"
        case .stream: "a stream keeps its newest \(EventStreamRecord.entryLimit), or as many as fit"
        case .connection: "a connection keeps its newest \(WebSocketRecord.entryLimit), or as many as fit"
        }
    }

    /// What a row's time is measured from.
    var origin: String {
        switch self {
        case .call: "Since the call started"
        case .stream: "Since the request was sent"
        case .connection: "Since Reqling started connecting"
        }
    }
}

extension TimelineItem.Header {
    /// Which way a message or frame went; an event-stream event is always received, and a note goes neither way.
    var direction: MessageDirection? {
        switch self {
        case .grpc(let direction, _), .webSocket(let direction, _, _), .control(let direction): direction
        case .event: .received
        case .note: nil
        }
    }
}
