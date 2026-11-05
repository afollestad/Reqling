import Foundation
import Observation

/// Every request's past runs on this Mac, newest first, kept under `AppSettings`' retention and size limit.
///
/// `RequestRunner` records into it and clears it, keeping its `latest` exchanges in step; everything else reads it.
/// Lists and outcomes are read from disk once per request and project, then kept current in memory, so recording a run
/// never waits on its file being written.
@MainActor
@Observable
public final class RunHistory {
    /// Bumped whenever any request's runs or outcome change; `runs(for:in:)` and `outcome(for:in:)` read it, so views
    /// showing either follow along.
    public private(set) var revision = 0
    /// Bytes every request's runs take on disk; `nil` until pruning first weighs them, as it does at launch.
    public private(set) var storedBytes: Int?

    @ObservationIgnored private let writer: RunHistoryWriter
    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let now: @Sendable () -> Date
    /// Lists read so far; a request missing here is read from disk on first use.
    @ObservationIgnored private var lists: [RunKey: [RunSummary]] = [:]
    @ObservationIgnored private var outcomes: [ProjectID: [RequestNodeID: RunOutcomeKind]] = [:]
    /// Told what pruning took, after the lists catch up; `RequestRunner` drops those runs from its `latest`.
    @ObservationIgnored var onPrune: ((RunHistoryWriter.Removal) -> Void)?

    public init(directory: URL, settings: SettingsStore, now: @escaping @Sendable () -> Date = { Date() }) {
        writer = RunHistoryWriter(store: RunHistoryStore(directory: directory))
        self.settings = settings
        self.now = now
        // Ends with the writer, which finishes the stream when this history goes.
        let sizes = writer.sizes
        Task { [weak self] in
            for await size in sizes {
                self?.storedBytes = size
            }
        }
    }

    /// The request's runs, newest first.
    public func runs(for request: RequestNodeID, in project: ProjectID) -> [RunSummary] {
        _ = revision
        let key = RunKey(request, in: project)
        if let list = lists[key] {
            return list
        }
        let list = writer.summaries(for: request, in: project)
        lists[key] = list
        return list
    }

    /// How the request's latest run went; `.notSent` when it has none on this Mac.
    public func outcome(for request: RequestNodeID, in project: ProjectID) -> RunOutcomeKind {
        _ = revision
        return projectOutcomes(project)[request] ?? .notSent
    }

    /// One stored run, decoded off the main actor; `nil` once pruning or a clear has taken it.
    public func exchange(_ run: RunID, for request: RequestNodeID, in project: ProjectID) async -> RequestExchange? {
        await writer.load(run, for: request, in: project)
    }

    /// Prunes under the current settings, as at launch and after they change; a recorded run prunes on its own.
    public func prune() {
        writer.prune(policy: policy, now: now(), onRemove: removalHandler)
    }

    /// Waits for every run still being written. Call it before quitting, and in tests that read a run's files.
    public func flush() {
        writer.flush()
    }

    func latest(for request: RequestNodeID, in project: ProjectID) -> RequestExchange? {
        writer.latest(for: request, in: project)
    }

    func record(_ exchange: RequestExchange) {
        let key = RunKey(exchange.requestID, in: exchange.projectID)
        // Loaded before the save is queued, which the read would otherwise wait out. A list not yet read needs nothing:
        // reading it waits for this save.
        _ = projectOutcomes(exchange.projectID)
        let summary = RunSummary(exchange)
        lists[key]?.removeAll { $0.id == summary.id }
        lists[key]?.insert(summary, at: 0)
        outcomes[exchange.projectID]?[exchange.requestID] = summary.outcomeKind
        writer.save(exchange, policy: policy, now: now(), onRemove: removalHandler)
        revision += 1
    }

    func clear(for request: RequestNodeID, in project: ProjectID) {
        writer.removeAll(for: request, in: project)
        lists[RunKey(request, in: project)] = []
        outcomes[project]?[request] = nil
        revision += 1
    }

    func clear(in project: ProjectID) {
        writer.removeAll(in: project)
        lists = lists.filter { $0.key.projectID != project }
        outcomes[project] = nil
        revision += 1
    }

    func clearAll() {
        writer.removeEverything()
        lists = [:]
        outcomes = [:]
        revision += 1
    }

    func move(_ requests: [RequestNodeID], from source: ProjectID, to destination: ProjectID) {
        writer.move(requests, from: source, to: destination)
        for request in requests {
            lists[RunKey(request, in: source)] = nil
            lists[RunKey(request, in: destination)] = nil
        }
        outcomes[source] = nil
        outcomes[destination] = nil
        revision += 1
    }

    private var policy: RunHistoryPolicy {
        RunHistoryPolicy(retention: settings.settings.historyRetention, sizeLimit: settings.settings.historySizeLimit)
    }

    private func projectOutcomes(_ project: ProjectID) -> [RequestNodeID: RunOutcomeKind] {
        if let loaded = outcomes[project] {
            return loaded
        }
        let loaded = writer.outcomes(in: project)
        outcomes[project] = loaded
        return loaded
    }

    /// Pruning reports from the writer's queue; the runs are gone from disk by then.
    private var removalHandler: @Sendable (RunHistoryWriter.Removal) -> Void {
        { [weak self] removal in
            Task { @MainActor in
                self?.didPrune(removal)
            }
        }
    }

    private func didPrune(_ removal: RunHistoryWriter.Removal) {
        for (key, runs) in removal {
            lists[key]?.removeAll { runs.contains($0.id) }
            // Pruning takes a request's newest run only with all the rest, so its outcome may be gone; reread it.
            outcomes[key.projectID] = nil
        }
        onPrune?(removal)
        revision += 1
    }
}
