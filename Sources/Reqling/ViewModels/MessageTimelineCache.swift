import Foundation
import ReqlingKit

/// How a timeline shows its messages or events: one tree over all of them, or each one's text.
enum MessageTimelineMode: String, CaseIterable, Identifiable {
    case tree = "Tree"
    case text = "Text"

    var id: Self {
        self
    }
}

/// One message or event on a Text timeline, its JSON tokenized for highlighting.
struct MessageTimelineEntry: Identifiable, Equatable {
    let item: TimelineItem
    let tokens: [SyntaxToken]

    /// The item's `sequence`: its place in the whole call or stream, the same in every update however the kept window
    /// moves.
    var id: Int {
        item.sequence
    }
}

/// One call's or stream's timeline as a tree, keyed by `TimelineItem.sequence` as `MessageTimelineCache` is: each
/// item's JSON is indexed once, and the run keeps one timeline identity while it streams, so the tree updates in place.
struct MessageTreeCache {
    /// Items larger than this aren't indexed for the tree; Text mode still shows them.
    static let indexLimit = 1 << 20

    private var startedAt: Date?
    private var id = UUID()
    private var timeline: MessageTimeline?

    /// `allowsTruncation` reads JSON that ends early as cut short, which only a record the run history shortened
    /// holds: a gRPC codec writes only whole JSON, but a live event's data may simply not be JSON.
    mutating func timeline<Source>(
        of sources: [Source],
        startedAt: Date,
        allowsTruncation: Bool,
        sequence: (Source) -> Int,
        item: (Source) -> TimelineItem
    ) -> MessageTimeline {
        if startedAt != self.startedAt {
            self.startedAt = startedAt
            id = UUID()
            timeline = nil
        }
        if let timeline, timeline.messages.count == sources.count, timeline.messages.first?.item.sequence == sources.first.map(sequence),
           timeline.messages.last?.item.sequence == sources.last.map(sequence) {
            return timeline
        }
        let known = Dictionary((timeline?.messages ?? []).map { ($0.item.sequence, $0) }, uniquingKeysWith: { first, _ in first })
        let messages = sources.map { source in
            known[sequence(source)] ?? Self.message(item(source), allowsTruncation: allowsTruncation)
        }
        let value = MessageTimeline(id: id, messages: messages)
        timeline = value
        return value
    }

    private static func message(_ item: TimelineItem, allowsTruncation: Bool) -> MessageTimeline.Message {
        guard item.isJSON, item.text.utf8.count <= indexLimit else {
            return MessageTimeline.Message(item: item, index: nil)
        }
        return MessageTimeline.Message(item: item, index: try? JSONStructureIndex.build(Data(item.text.utf8), allowsTruncation: allowsTruncation))
    }
}

/// One call's or stream's Text timeline entries, keyed by `TimelineItem.sequence` so tokenizing happens once per item.
///
/// Keyed by position, a full record (`GRPCCallRecord.eventLimit` items) would look unchanged as its window slides
/// forward, freezing the timeline on its first items; and items dropped mid-stream leave gaps positions cannot express.
/// A record only ever gains newer items and loses older ones, so its count and first and last sequence identify what it
/// holds.
struct MessageTimelineCache {
    /// Items longer than this (in UTF-16 units) show unhighlighted: a timeline row is SwiftUI text, which lays out all
    /// of an item at once.
    static let highlightLimit = 20_000

    private var startedAt: Date?
    private var entries: [MessageTimelineEntry] = []

    mutating func entries<Source>(
        of sources: [Source],
        startedAt: Date,
        sequence: (Source) -> Int,
        item: (Source) -> TimelineItem
    ) -> [MessageTimelineEntry] {
        if startedAt != self.startedAt {
            self.startedAt = startedAt
            entries = []
        }
        let isUnchanged = entries.count == sources.count
            && entries.first?.id == sources.first.map(sequence)
            && entries.last?.id == sources.last.map(sequence)
        if isUnchanged {
            return entries
        }
        let known = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        entries = sources.map { source in
            known[sequence(source)] ?? Self.entry(item(source))
        }
        return entries
    }

    private static func entry(_ item: TimelineItem) -> MessageTimelineEntry {
        let highlights = item.isJSON && (item.text as NSString).length <= highlightLimit
        return MessageTimelineEntry(item: item, tokens: highlights ? SyntaxTokenizer.tokens(in: item.text, language: .json) : [])
    }
}

extension MessageTreeCache {
    mutating func timeline(for call: GRPCCallRecord, startedAt: Date) -> MessageTimeline {
        // The codec only writes valid JSON, so a message that ends early was cut to fit the run history.
        timeline(of: call.events, startedAt: startedAt, allowsTruncation: true, sequence: \.sequence, item: TimelineItem.init)
    }

    mutating func timeline(for stream: EventStreamRecord, startedAt: Date, isCacheShortened: Bool) -> MessageTimeline {
        timeline(of: stream.entries, startedAt: startedAt, allowsTruncation: isCacheShortened, sequence: \.sequence, item: TimelineItem.init)
    }
}

extension MessageTimelineCache {
    mutating func entries(for call: GRPCCallRecord, startedAt: Date) -> [MessageTimelineEntry] {
        entries(of: call.events, startedAt: startedAt, sequence: \.sequence, item: TimelineItem.init)
    }

    mutating func entries(for stream: EventStreamRecord, startedAt: Date) -> [MessageTimelineEntry] {
        entries(of: stream.entries, startedAt: startedAt, sequence: \.sequence, item: TimelineItem.init)
    }
}
