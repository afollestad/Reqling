import Foundation
import MCP

/// Event-stream responses and WebSockets through the execution tools. A run waits for its stream or connection to end,
/// a GET stream reconnects for as long as it is open, and a WebSocket stays open until someone closes it, so every one
/// an agent starts carries a time bound: otherwise `execute_request` would wait out the tool's timeout and lose
/// everything that arrived.
extension MCPExecutionTools {
    /// How long an agent's stream is read when it names no `streamSeconds`.
    static let defaultStreamSeconds = 30.0

    static let streamProperties: [String: Value] = [
        "streamSeconds": MCPSchema.number(
            "Event streams and WebSockets: stop after this many seconds, and return what arrived. Default 30.",
            minimum: 1,
            maximum: 300
        ),
        "streamEvents": MCPSchema.integer(
            "Event streams: stop after this many events. WebSockets: close after this many received messages.",
            minimum: 1,
            maximum: 2_000
        )
    ]

    /// The bound for a run of `kind`: every HTTP run gets one, which only matters if its response turns out to be an
    /// event stream, and every WebSocket; gRPC calls end at their deadline instead, so asking for one there is refused.
    static func streamLimit(_ arguments: MCPArguments, for kind: RequestKind) throws -> StreamLimit? {
        let seconds = try arguments.optionalNumber("streamSeconds", in: 1...300)
        let events = try arguments.optionalInteger("streamEvents", in: 1...2_000)
        guard kind.httpSpec != nil || kind.webSocketSpec != nil else {
            guard seconds == nil, events == nil else {
                throw MCPToolError("`streamSeconds` and `streamEvents` are for event streams and WebSockets; a gRPC call ends at its deadline.")
            }
            return nil
        }
        return StreamLimit(maxDuration: .milliseconds(Int((seconds ?? defaultStreamSeconds) * 1_000)), maxEvents: events)
    }

    /// An event stream in place of a body: the newest events that fit `bodyLimit`, masked, and how the stream went.
    /// `end` is `null` while it is still open.
    static func eventStream(_ stream: EventStreamRecord, cachedCut: Bool, mask: (String) -> String) -> [String: Value] {
        var kept: [Value] = []
        var budget = bodyLimit
        for entry in stream.entries.reversed() {
            guard let event = entry.event else {
                continue
            }
            let data = mask(event.data)
            budget -= data.utf8.count
            guard budget >= 0 else {
                break
            }
            var described: [String: Value] = [
                "type": .string(mask(event.type)),
                "data": .string(data),
                "offsetMs": .int(Int((entry.offset * 1_000).rounded()))
            ]
            if let id = event.id {
                described["id"] = .string(mask(id))
            }
            kept.append(.object(described))
        }
        var description: [String: Value] = [
            "byteCount": .int(stream.receivedByteCount),
            "events": .array(kept.reversed()),
            "eventCount": .int(stream.eventCount),
            "reconnects": .int(stream.reconnectCount),
            "end": stream.end.map { .string(name(of: $0)) } ?? .null
        ]
        if let lastEventID = stream.lastEventID {
            description["lastEventId"] = .string(mask(lastEventID))
        }
        if case .failed(let message) = stream.end {
            description["endMessage"] = .string(mask(message))
        }
        let omitted = stream.eventCount - kept.count
        if omitted > 0 || cachedCut {
            description["omittedEventCount"] = .int(omitted)
            description["note"] = "Only the newest events are included."
        }
        return description
    }

    private static func name(of end: EventStreamRecord.End) -> String {
        switch end {
        case .closed: "closed"
        case .stopped: "stopped"
        case .limit: "limit"
        case .timedOut: "timedOut"
        case .failed: "failed"
        }
    }
}
