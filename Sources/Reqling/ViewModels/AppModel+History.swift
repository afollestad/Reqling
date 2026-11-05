import Foundation
import ReqlingKit

/// Which runs a clear takes, with the names its confirmation shows.
enum HistoryClearScope: Identifiable, Equatable {
    case request(ProjectID, RequestNodeID, name: String)
    case project(ProjectID, name: String)
    case all

    var id: String {
        switch self {
        case .request(let project, let request, _): "\(project)/\(request)"
        case .project(let project, _): project.description
        case .all: "all"
        }
    }

    var title: String {
        switch self {
        case .request(_, _, let name): "Clear the run history of “\(name)”?"
        case .project(_, let name): "Clear the run history of every request in “\(name)”?"
        case .all: "Clear the run history of every request?"
        }
    }
}

/// The run history's window-wide state and commands: the inspector beside a request (which also holds the GraphQL
/// schema browser), clearing, and the History settings.
extension AppModel {
    /// Whether the inspector shows beside the editor; remembered on this Mac, so it stays open or closed across requests
    /// and launches.
    var isInspectorShown: Bool {
        get { workspace.state.showsRunHistory }
        set { workspace.update { $0.showsRunHistory = newValue } }
    }

    /// The panel last chosen, remembered like `isInspectorShown`.
    var inspectorPanel: InspectorPanel {
        get { workspace.state.inspectorPanel }
        set { workspace.update { $0.inspectorPanel = newValue } }
    }

    /// What the inspector shows: the GraphQL schema only beside a request that has one, else the run history.
    var shownInspectorPanel: InspectorPanel {
        inspectorPanel == .graphQLSchema && editor?.asHTTP?.graphQL != nil ? .graphQLSchema : .history
    }

    var showsRunHistory: Bool {
        isInspectorShown && shownInspectorPanel == .history
    }

    var showsGraphQLSchema: Bool {
        isInspectorShown && shownInspectorPanel == .graphQLSchema
    }

    /// The toolbar button and View ▸ Show Inspector: shows or hides the inspector on whichever panel was last chosen,
    /// never switching it, unlike the commands that name a panel.
    func toggleInspector() {
        isInspectorShown.toggle()
    }

    func toggleRunHistory() {
        toggle(.history)
    }

    func toggleGraphQLSchema() {
        toggle(.graphQLSchema)
    }

    /// Closes the inspector when it already shows `panel`, and otherwise opens it on `panel`.
    private func toggle(_ panel: InspectorPanel) {
        if isInspectorShown, shownInspectorPanel == panel {
            isInspectorShown = false
        } else {
            inspectorPanel = panel
            isInspectorShown = true
        }
    }

    func requestClearHistory(of project: ProjectID) {
        historyClearPending = .project(project, name: library.project(project)?.name ?? "")
    }

    func requestClearHistory(of request: RequestNodeID, in project: ProjectID) {
        historyClearPending = .request(project, request, name: library.document(project)?.request(request)?.name ?? "")
    }

    /// Clears for good; the history lives only on this Mac, so nothing can bring the runs back.
    func clearHistory(_ scope: HistoryClearScope) {
        historyClearPending = nil
        switch scope {
        case .request(let project, let request, _):
            runner.clearHistory(for: request, in: project)
        case .project(let project, _):
            runner.clearHistory(in: project)
        case .all:
            runner.clearAllHistory()
        }
    }

    /// Changes take effect at once: runs the new limits no longer allow are pruned.
    func setHistoryRetention(_ retention: HistoryRetention) {
        settings.update { $0.historyRetention = retention }
        runner.history.prune()
    }

    func setHistorySizeLimit(_ limit: HistorySizeLimit) {
        settings.update { $0.historySizeLimit = limit }
        runner.history.prune()
    }
}
