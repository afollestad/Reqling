import Foundation
import Observation
import ReqlingKit

enum WebSocketResponseTab: String, CaseIterable, Identifiable {
    case messages = "Messages"
    case handshake = "Handshake"
    case request = "Request"
    case tests = "Tests"

    var id: Self {
        self
    }
}

/// The shown WebSocket run of one request, shaped for display. An open connection publishes a partial record (`end`
/// still `nil`) as it goes, so `timeline` reuses each entry's tokens across updates through `MessageTimelineCache`.
@MainActor
@Observable
final class WebSocketResponseViewModel {
    var tab: WebSocketResponseTab = .messages
    var messagesMode: MessageTimelineMode = .tree
    /// Searching the messages tree.
    let search = BodySearchModel()
    /// The section bar's Expand All and Collapse All, reaching the tree on screen.
    @ObservationIgnored private var scriptsCache = ScriptReportCache()
    @ObservationIgnored let treeController = BodyTreeController()

    let requestID: RequestNodeID
    let projectID: ProjectID
    /// Which run shows: the latest, or one picked in the inspector.
    let history: RunHistoryViewModel
    @ObservationIgnored private let runner: RequestRunner
    @ObservationIgnored private var cache = MessageTimelineCache()
    @ObservationIgnored private var treeCache = MessageTreeCache()
    /// `refusalBody`'s memo, by run: a refused handshake's body is bounded (`WebSocketExecutor.refusalBodyLimit`), but
    /// indexing it per render would still repeat work on every live update of another tab.
    @ObservationIgnored private var refusalCache: (id: RunID, document: TextDocument?)?

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

    /// What the Tests tab and the status bar show of the run's scripts; `nil` when it has no report.
    var scripts: ScriptReportPresentation? {
        scriptsCache.presentation(of: exchange?.scriptReport)
    }

    /// Every tab but Tests, which shows only for a run with a script report.
    var visibleTabs: [WebSocketResponseTab] {
        let hasScripts = scripts != nil
        return WebSocketResponseTab.allCases.filter { $0 != .tests || hasScripts }
    }

    /// The tab picked, or the first while the picked one is hidden, so picking Tests survives a run without scripts.
    var shownTab: WebSocketResponseTab {
        get { visibleTabs.contains(tab) ? tab : .messages }
        set { tab = newValue }
    }

    var record: WebSocketRecord? {
        exchange?.webSocket
    }

    var isSending: Bool {
        runner.isInFlight(requestID, in: projectID)
    }

    var timeline: [MessageTimelineEntry] {
        // Read the observable exchange before consulting the cache, so observation keeps tracking it.
        guard let exchange, let record = exchange.webSocket else {
            return []
        }
        return cache.entries(for: record, startedAt: exchange.startedAt)
    }

    /// A refused handshake's body, for the Handshake tab; `nil` when there is none.
    var refusalBody: TextDocument? {
        // Read the observable exchange before consulting the cache, so observation keeps tracking it.
        guard let exchange, let handshake = exchange.webSocket?.handshake, !handshake.body.isEmpty else {
            return nil
        }
        if let refusalCache, refusalCache.id == exchange.id {
            return refusalCache.document
        }
        let document = String(data: handshake.body, encoding: .utf8).map { text in
            TextDocument(text: text, language: ContentTypeLanguage.language(forContentType: handshake.header("Content-Type")))
        }
        refusalCache = (exchange.id, document)
        return document
    }

    /// The messages as one tree for Tree mode.
    var messageTree: BodyStructure? {
        // Read the observable exchange before consulting the cache, so observation keeps tracking it.
        guard let exchange, let record = exchange.webSocket else {
            return nil
        }
        return .messages(treeCache.timeline(for: record, startedAt: exchange.startedAt, isCacheShortened: exchange.isBodyTruncated))
    }
}
