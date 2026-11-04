import Foundation

/// A gRPC call's messages as one tree for Tree mode: each message a top-level node over its JSON.
///
/// A streaming call publishes a new timeline per message with the same `id`, so the tree updates in place: it adds
/// the new messages and drops the ones the record trimmed, keeping whatever someone expanded.
public struct MessageTimeline: Sendable {
    public struct Message: Sendable {
        public let event: GRPCMessageEvent
        /// `nil` when its JSON doesn't parse, as when the response cache cut a long message short.
        public let index: JSONStructureIndex?
        /// The message's top-level fields, which its row expands to.
        public let fields: [JSONEntry]

        public init(event: GRPCMessageEvent, index: JSONStructureIndex?) {
            self.event = event
            self.index = index
            fields = index.flatMap { index in index.rootEntries().first?.container.map { index.children(of: $0) } } ?? []
        }
    }

    public let id: UUID
    public let messages: [Message]

    public init(id: UUID, messages: [Message]) {
        self.id = id
        self.messages = messages
    }

    /// Matches inside each message, with paths that start at the message's position on the timeline.
    func find(_ query: String, limit: Int) throws(CancellationError) -> BodyTreeSearchResult {
        var matches: [BodyTreeMatch] = []
        for (position, message) in messages.enumerated() {
            guard let index = message.index, matches.count < limit else {
                continue
            }
            let found = try index.find(query, limit: limit - matches.count)
            // A message's own path starts at its one top-level value, which the timeline shows as the message row.
            matches += found.matches.map { BodyTreeMatch(path: [position] + $0.path.dropFirst()) }
        }
        return BodyTreeSearchResult(matches: matches, isTruncated: matches.count >= limit)
    }
}
