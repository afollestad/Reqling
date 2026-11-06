import Foundation
import ReqlingKit

/// An event-stream response, which shows its events in place of a body: live while the stream is open, through the
/// same timeline caches a gRPC call's messages use, so each event is tokenized and indexed once.
extension ResponseViewModel {
    /// The shown exchange's events, while it is an event stream.
    var eventStream: EventStreamRecord? {
        exchange?.response?.eventStream
    }

    var eventTimeline: [MessageTimelineEntry] {
        // Read the observable exchange before consulting the cache, so observation keeps tracking it.
        guard let exchange, let stream = exchange.response?.eventStream else {
            return []
        }
        return eventCache.entries(for: stream, startedAt: exchange.startedAt)
    }

    /// The events as one tree for Tree mode.
    var eventTree: BodyStructure? {
        // Read the observable exchange before consulting the cache, so observation keeps tracking it.
        guard let exchange, let stream = exchange.response?.eventStream else {
            return nil
        }
        return .messages(eventTreeCache.timeline(for: stream, startedAt: exchange.startedAt, isCacheShortened: exchange.isBodyTruncated))
    }

    /// The events as a `text/event-stream` body again, for Copy and Save, with the notes between them as comments.
    static func eventStreamText(_ stream: EventStreamRecord) -> String {
        stream.entries.map { entry in
            switch entry.kind {
            case .event(let event):
                var lines: [String] = []
                if let id = event.id {
                    lines.append("id: \(id)")
                }
                if event.type != "message" {
                    lines.append("event: \(event.type)")
                }
                lines += event.data.split(separator: "\n", omittingEmptySubsequences: false).map { "data: \($0)" }
                return lines.joined(separator: "\n") + "\n\n"
            case .note(let note):
                return ": \(note)\n\n"
            }
        }
        .joined()
    }
}
