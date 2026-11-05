import Foundation
import Observation
import ReqlingKit

/// Two runs being compared, older first.
struct RunPair: Hashable {
    let older: RunID
    let newer: RunID
}

/// Where comparing two runs has got to.
enum RunComparisonState {
    case loading
    case ready(RunComparison)
    /// Pruned or cleared since it was listed.
    case missing
}

extension RunComparisonState {
    var isLoading: Bool {
        if case .loading = self {
            return true
        }
        return false
    }
}

/// A selected run the response pane cannot show yet, or ever.
enum PinnedRunStatus: Equatable {
    case loading
    /// Pruned or cleared since it was listed.
    case missing
}

/// A restore waiting on the person to confirm that it replaces the request in the editor.
struct PendingRestore: Identifiable, Equatable {
    let run: RunSummary
    let spec: RequestKind

    var id: RunID {
        run.id
    }
}

/// One request's run history beside its editor: the runs selected in the inspector, which run the response pane shows,
/// and re-running, restoring, comparing, and clearing runs.
///
/// One selected run pins the response pane to it, loaded off the main actor from the view's `.task(id: pinnedRunID)`;
/// no selection, or the latest run alone, follows the latest exchange as before. Sending clears the selection, so a new
/// run always shows. Compare replaces the pane with the two selected runs' differences until the selection changes;
/// they are computed off the main actor from the comparison view's `.task(id: comparing)`.
@MainActor
@Observable
final class RunHistoryViewModel {
    let projectID: ProjectID
    let requestID: RequestNodeID
    var selection: Set<RunID> = [] {
        didSet {
            if let comparing, selection != [comparing.older, comparing.newer] {
                self.comparing = nil
            }
        }
    }
    /// Set by Compare; selecting anything else ends it.
    private(set) var comparing: RunPair?
    private(set) var comparison: (pair: RunPair, state: RunComparisonState)?
    /// The comparison's section shown, by title; `nil` shows the first.
    var comparisonSection: String?
    /// Searching the comparison's text, whichever section shows.
    let comparisonSearch = BodySearchModel()
    var restorePending: PendingRestore?
    private var pinned: (id: RunID, exchange: RequestExchange?)?

    /// `days(formats:)`' memo: grouping formats every run's time, and the inspector re-renders whenever any request
    /// records one.
    @ObservationIgnored private var daysCache: (key: DaysKey, days: [RunHistoryDay])?
    @ObservationIgnored private unowned let app: AppModel
    /// The editor a restore replaces the request in; set once that editor exists, which owns this.
    @ObservationIgnored weak var editor: (any RequestEditing)?

    init(projectID: ProjectID, requestID: RequestNodeID, app: AppModel) {
        self.projectID = projectID
        self.requestID = requestID
        self.app = app
    }

    /// The request's runs, newest first.
    var runs: [RunSummary] {
        app.runner.history.runs(for: requestID, in: projectID)
    }

    /// The runs grouped by the day they started, newest first, for the inspector.
    func days(formats: RunDateFormats, now: Date = Date()) -> [RunHistoryDay] {
        // Read the observable runs before consulting the cache, so observation keeps tracking them.
        let key = DaysKey(runs: runs, formats: formats, today: formats.calendar.startOfDay(for: now))
        if let daysCache, daysCache.key == key {
            return daysCache.days
        }
        let days = RunHistoryDay.group(key.runs, formats: formats, now: now)
        daysCache = (key, days)
        return days
    }

    /// The single selected run, unless it is the latest exchange, which the pane shows anyway.
    var pinnedRunID: RunID? {
        guard comparing == nil, selection.count == 1, let run = selection.first else {
            return nil
        }
        return run == latest?.id ? nil : run
    }

    /// The summary of the pinned run, for the bar that says which run shows.
    var pinnedRun: RunSummary? {
        pinnedRunID.flatMap { run in runs.first { $0.id == run } }
    }

    /// What the response pane shows: the pinned run once it has loaded, else the latest exchange.
    var shownExchange: RequestExchange? {
        let latest = latest
        guard let run = pinnedRunID else {
            return latest
        }
        return pinned?.id == run && isListed(run) ? pinned?.exchange : nil
    }

    /// Why the pinned run is not showing; `nil` once it is, or when none is pinned.
    var pinnedStatus: PinnedRunStatus? {
        guard let run = pinnedRunID else {
            return nil
        }
        guard isListed(run) else {
            return .missing
        }
        guard let pinned, pinned.id == run else {
            return .loading
        }
        return pinned.exchange == nil ? .missing : nil
    }

    var canCompare: Bool {
        selection.count == 2
    }

    /// The state of the comparison under way; `nil` when none is, or it is of other runs.
    var comparisonState: RunComparisonState? {
        guard let comparing else {
            return nil
        }
        guard isListed(comparing.older), isListed(comparing.newer) else {
            return .missing
        }
        guard let comparison, comparison.pair == comparing else {
            return .loading
        }
        return comparison.state
    }

    /// Whether `run` can be sent again or put back in the editor: it kept its template, and in this request's protocol.
    func canReplay(_ run: RunSummary) -> Bool {
        run.specKind != nil && run.specKind == editor?.kind
    }

    func canRestore(_ run: RunSummary) -> Bool {
        canReplay(run) && editor?.isReadOnly == false
    }

    /// Loads the pinned run, for the response view's `.task(id: pinnedRunID)`.
    func loadPinned() async {
        guard let run = pinnedRunID, pinned?.id != run else {
            return
        }
        let exchange = await app.runner.history.exchange(run, for: requestID, in: projectID)
        // The selection may have moved on while it loaded.
        if pinnedRunID == run {
            pinned = (run, exchange)
        }
    }

    func showLatest() {
        selection = []
    }

    /// The runs the inspector shows selected: the selection, or the latest run while the pane follows it, so Show Latest
    /// and Send leave the newest row highlighted and the highlight moves on as runs arrive.
    var displayedSelection: Set<RunID> {
        guard selection.isEmpty, let latest = latest?.id, runs.first?.id == latest else {
            return selection
        }
        return [latest]
    }

    /// Selects as the inspector's rows were picked. The latest run alone means following the latest, as no selection
    /// does; kept as a selection, it would pin the pane to that run once a newer one arrives.
    func select(_ picked: Set<RunID>) {
        if let latest = latest?.id, picked == [latest] {
            selection = []
        } else {
            selection = picked
        }
    }

    /// Compares the two selected runs.
    func compare() {
        let chosen = runs.filter { selection.contains($0.id) }
        guard chosen.count == 2 else {
            return
        }
        comparing = RunPair(older: chosen[1].id, newer: chosen[0].id)
    }

    func compareWithLatest(_ run: RunID) {
        guard let newest = runs.first?.id, newest != run else {
            return
        }
        selection = [run, newest]
        compare()
    }

    func endComparison() {
        comparing = nil
    }

    /// Loads both runs and diffs them off the main actor, for the comparison view's `.task(id: comparing)`; a large
    /// body takes a while, and leaving the comparison cancels it.
    func loadComparison() async {
        guard let pair = comparing else {
            return
        }
        // A finished comparison is reused; one left loading was cancelled with its view, and starts over.
        if let comparison, comparison.pair == pair, !comparison.state.isLoading {
            return
        }
        comparison = (pair, .loading)
        guard let older = await exchange(pair.older), let newer = await exchange(pair.newer) else {
            if comparing == pair {
                comparison = (pair, .missing)
            }
            return
        }
        let work = Task.detached(priority: .userInitiated) {
            try RunComparer.compare(older, newer)
        }
        let result = try? await withTaskCancellationHandler {
            try await work.value
        } onCancel: {
            work.cancel()
        }
        if comparing == pair, let result {
            comparison = (pair, .ready(result))
        }
    }

    /// Drops selected runs the history no longer lists, as after pruning or a clear.
    func retainSelection(in listed: [RunID]) {
        let kept = selection.intersection(listed)
        if kept != selection {
            selection = kept
        }
    }

    /// Sends the run's template again against its environment, or the active one when that is gone, as a new run.
    func rerun(_ run: RunSummary) {
        Task {
            await performRerun(run)
        }
    }

    func performRerun(_ run: RunSummary) async {
        guard canReplay(run), let exchange = await stored(run), let spec = exchange.spec else {
            return
        }
        let environment = exchange.environmentID.flatMap { app.library.document(projectID)?.environment($0)?.id }
        showLatest()
        let options = RunOptions(environmentID: environment, spec: spec, keepsStreamOpen: spec.grpcSpec != nil)
        await app.runner.run(requestID, in: projectID, options: options)
    }

    /// Puts the run's template back in the editor, asking first unless the editor already holds it.
    func requestRestore(_ run: RunSummary) {
        Task {
            await prepareRestore(run)
        }
    }

    func prepareRestore(_ run: RunSummary) async {
        guard canRestore(run), let exchange = await stored(run), let spec = exchange.spec, let editor, spec != editor.currentSpec else {
            return
        }
        restorePending = PendingRestore(run: run, spec: spec)
    }

    func confirmRestore(_ pending: PendingRestore) {
        restorePending = nil
        editor?.restore(pending.spec, from: pending.run.startedAt)
    }

    func requestClear() {
        app.historyClearPending = .request(projectID, requestID, name: editor?.name ?? "")
    }

    /// What an editor says after a restore.
    static func restoredNotice(sentAt date: Date) -> String {
        "Restored the request as it was sent \(date.formatted(date: .abbreviated, time: .shortened))."
    }

    /// Whether the history still lists `run`. A run cleared or pruned since it was picked no longer shows, even while
    /// the inspector, which drops it from the selection, is hidden.
    private func isListed(_ run: RunID) -> Bool {
        runs.contains { $0.id == run }
    }

    private var latest: RequestExchange? {
        app.runner.latest[RunKey(requestID, in: projectID)]
    }

    /// The stored run, or an alert when it is gone.
    private func stored(_ run: RunSummary) async -> RequestExchange? {
        guard let exchange = await exchange(run.id) else {
            app.alert = AppAlert(title: "Run No Longer Kept", message: "The history no longer has this run.")
            return nil
        }
        return exchange
    }

    /// The run in memory when it is the latest, else from the history.
    private func exchange(_ run: RunID) async -> RequestExchange? {
        if let latest, latest.id == run {
            return latest
        }
        return await app.runner.history.exchange(run, for: requestID, in: projectID)
    }
}

/// Everything `RunHistoryViewModel.days(formats:)` groups from; the day matters because it decides Today and Yesterday.
private struct DaysKey: Equatable {
    let runs: [RunSummary]
    let formats: RunDateFormats
    let today: Date
}
