import Foundation
import Observation
import ReqlingKit

enum GRPCResponseTab: String, CaseIterable, Identifiable {
    case messages = "Messages"
    case metadata = "Metadata"
    case request = "Request"

    var id: Self {
        self
    }
}

/// How the Messages tab shows them: one tree over every message, or each message's JSON as text.
enum GRPCMessagesMode: String, CaseIterable, Identifiable {
    case tree = "Tree"
    case text = "Text"

    var id: Self {
        self
    }
}

/// One message on the response timeline, with its JSON tokenized for highlighting.
struct GRPCTimelineEntry: Identifiable, Equatable {
    let event: GRPCMessageEvent
    let tokens: [SyntaxToken]

    /// The message's `sequence`: its place in the whole call, the same in every update however the kept window moves.
    var id: Int {
        event.sequence
    }
}

/// The latest gRPC call of one request, shaped for display. An open call publishes a partial record (status `nil`) per
/// event, so `timeline` reuses each message's tokens across updates through `GRPCTimelineCache`.
@MainActor
@Observable
final class GRPCResponseViewModel {
    var tab: GRPCResponseTab = .messages
    var messagesMode: GRPCMessagesMode = .tree
    /// Searching the messages tree.
    let search = BodySearchModel()
    /// The section bar's Expand All and Collapse All, reaching the tree on screen.
    @ObservationIgnored let treeController = BodyTreeController()

    let requestID: RequestNodeID
    let projectID: ProjectID
    /// Which run shows: the latest, or one picked in the inspector.
    let history: RunHistoryViewModel
    @ObservationIgnored private let runner: RequestRunner
    @ObservationIgnored private var cache = GRPCTimelineCache()
    @ObservationIgnored private var treeCache = GRPCMessageTreeCache()

    init(requestID: RequestNodeID, projectID: ProjectID, runner: RequestRunner, history: RunHistoryViewModel) {
        self.requestID = requestID
        self.projectID = projectID
        self.runner = runner
        self.history = history
        _ = runner.exchange(for: requestID, in: projectID)
    }

    var exchange: RequestExchange? {
        history.shownExchange
    }

    var isSending: Bool {
        runner.isInFlight(requestID, in: projectID)
    }

    var timeline: [GRPCTimelineEntry] {
        // Read the observable exchange before consulting the cache, so observation keeps tracking it.
        guard let exchange, let call = exchange.grpc else {
            return []
        }
        return cache.entries(for: call, startedAt: exchange.startedAt)
    }

    /// The messages as one tree for Tree mode.
    var messageTree: BodyStructure? {
        // Read the observable exchange before consulting the cache, so observation keeps tracking it.
        guard let exchange, let call = exchange.grpc else {
            return nil
        }
        return .messages(treeCache.timeline(for: call, startedAt: exchange.startedAt))
    }
}

/// One call's messages as a tree timeline, keyed by `GRPCMessageEvent.sequence` as `GRPCTimelineCache` is: each
/// message's JSON is indexed once, and the call keeps one timeline identity while it streams, so the tree updates in
/// place.
struct GRPCMessageTreeCache {
    /// Messages larger than this aren't indexed for the tree; Text mode still shows them.
    static let indexLimit = 1 << 20

    private var startedAt: Date?
    private var id = UUID()
    private var timeline: MessageTimeline?

    mutating func timeline(for call: GRPCCallRecord, startedAt: Date) -> MessageTimeline {
        if startedAt != self.startedAt {
            self.startedAt = startedAt
            id = UUID()
            timeline = nil
        }
        let events = call.events
        if let timeline, timeline.messages.count == events.count, timeline.messages.first?.event.sequence == events.first?.sequence,
           timeline.messages.last?.event.sequence == events.last?.sequence {
            return timeline
        }
        let known = Dictionary((timeline?.messages ?? []).map { ($0.event.sequence, $0) }, uniquingKeysWith: { first, _ in first })
        let messages = events.map { event in
            known[event.sequence] ?? MessageTimeline.Message(event: event, index: Self.index(event))
        }
        let value = MessageTimeline(id: id, messages: messages)
        timeline = value
        return value
    }

    private static func index(_ event: GRPCMessageEvent) -> JSONStructureIndex? {
        guard event.json.utf8.count <= indexLimit else {
            return nil
        }
        // The codec only writes valid JSON, so a message that ends early was cut to fit the run history: keep what
        // came before the cut.
        return try? JSONStructureIndex.build(Data(event.json.utf8), allowsTruncation: true)
    }
}

/// One call's timeline entries, keyed by `GRPCMessageEvent.sequence` so tokenizing happens once per message.
///
/// Keyed by position, a full record (`GRPCCallRecord.eventLimit` events) would look unchanged as its window slides
/// forward, freezing the timeline on its first messages; and messages dropped mid-stream leave gaps positions cannot
/// express. A record only ever gains newer messages and loses older ones, so its count and first and last sequence
/// identify what it holds.
struct GRPCTimelineCache {
    /// Messages longer than this (in UTF-16 units) show unhighlighted: a timeline row is SwiftUI text, which lays out
    /// all of a message at once.
    static let highlightLimit = 20_000

    private var startedAt: Date?
    private var entries: [GRPCTimelineEntry] = []

    mutating func entries(for call: GRPCCallRecord, startedAt: Date) -> [GRPCTimelineEntry] {
        if startedAt != self.startedAt {
            self.startedAt = startedAt
            entries = []
        }
        let events = call.events
        let isUnchanged = entries.count == events.count
            && entries.first?.id == events.first?.sequence
            && entries.last?.id == events.last?.sequence
        if isUnchanged {
            return entries
        }
        let known = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        entries = events.map { event in
            known[event.sequence] ?? GRPCTimelineEntry(event: event, tokens: Self.tokens(for: event))
        }
        return entries
    }

    private static func tokens(for event: GRPCMessageEvent) -> [SyntaxToken] {
        (event.json as NSString).length <= highlightLimit ? SyntaxTokenizer.tokens(in: event.json, language: .json) : []
    }
}
