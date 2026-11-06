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

/// The latest gRPC call of one request, shaped for display. An open call publishes a partial record (status `nil`) per
/// event, so `timeline` reuses each message's tokens across updates through `MessageTimelineCache`.
@MainActor
@Observable
final class GRPCResponseViewModel {
    var tab: GRPCResponseTab = .messages
    var messagesMode: MessageTimelineMode = .tree
    /// Searching the messages tree.
    let search = BodySearchModel()
    /// The section bar's Expand All and Collapse All, reaching the tree on screen.
    @ObservationIgnored let treeController = BodyTreeController()

    let requestID: RequestNodeID
    let projectID: ProjectID
    /// Which run shows: the latest, or one picked in the inspector.
    let history: RunHistoryViewModel
    @ObservationIgnored private let runner: RequestRunner
    @ObservationIgnored private var cache = MessageTimelineCache()
    @ObservationIgnored private var treeCache = MessageTreeCache()

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

    var timeline: [MessageTimelineEntry] {
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
