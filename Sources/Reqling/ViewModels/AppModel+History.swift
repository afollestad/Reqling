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

/// The run history's window-wide state and commands: the inspector beside a request, clearing, and the History
/// settings.
extension AppModel {
    /// Remembered on this Mac, so the inspector stays open or closed across requests and launches.
    var showsRunHistory: Bool {
        get { workspace.state.showsRunHistory }
        set { workspace.update { $0.showsRunHistory = newValue } }
    }

    func toggleRunHistory() {
        showsRunHistory.toggle()
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
