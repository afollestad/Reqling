import Foundation

/// Clearing and moving the run history, and keeping `latest` in step with what the history drops: the paths
/// `Sources/ReqlingKit/History/AGENTS.md` sends every change through.
extension RequestRunner {
    /// Clears one request's history, leaving a run in flight to record when it finishes; an open gRPC call keeps
    /// showing as it goes.
    public func clearHistory(for request: RequestNodeID, in project: ProjectID) {
        let key = RunKey(request, in: project)
        history.clear(for: request, in: project)
        if liveCalls[key] == nil {
            latest[key] = nil
        }
    }

    /// Clears every request's history in a project, as `clearHistory(for:in:)` does one's.
    public func clearHistory(in project: ProjectID) {
        history.clear(in: project)
        latest = latest.filter { $0.key.projectID != project || liveCalls[$0.key] != nil }
    }

    /// Clears every project's history, as `clearHistory(for:in:)` does one request's.
    public func clearAllHistory() {
        history.clearAll()
        latest = latest.filter { liveCalls[$0.key] != nil }
    }

    /// Carries requests' history into another project, as when they move there keeping their IDs. Their runs in flight
    /// are cancelled and detached, since they resolve against the project being left.
    public func moveHistory(of requests: [RequestNodeID], from source: ProjectID, to destination: ProjectID) {
        for request in requests {
            let key = RunKey(request, in: source)
            detach(key)
            latest[key] = nil
        }
        history.move(requests, from: source, to: destination)
    }

    /// Drops runs the size limit or retention took from `latest`, so the window never shows a run its history dropped. An
    /// open gRPC call showing there is left alone: it is newer than anything pruned.
    func dropPruned(_ removal: RunHistoryWriter.Removal) {
        for (key, runs) in removal where liveCalls[key] == nil {
            if let shown = latest[key], runs.contains(shown.id) {
                latest[key] = nil
            }
        }
    }
}
