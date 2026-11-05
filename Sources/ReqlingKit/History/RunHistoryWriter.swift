import Foundation
import Synchronization

/// `RunHistory`'s path to `RunHistoryStore`, which takes saving and pruning off the main actor.
///
/// Saving JSON-encodes a whole exchange, body included, so a multi-megabyte response would hold the main actor until
/// its file was written. Saves and pruning run on one serial queue, which also keeps each index's read-modify-write
/// from losing an update. Everything else runs behind any of those still queued:
///
/// - Removals and moves are on disk by the time they return, so a run cleared or a project forgotten leaves nothing a
///   later read could bring back.
/// - Reads never miss a save queued before them, nor see a run removed after.
final class RunHistoryWriter: Sendable {
    /// Runs pruning took, by request.
    typealias Removal = [RunKey: Set<RunID>]

    private let store: RunHistoryStore
    private let queue = DispatchQueue(label: "com.afollestad.reqling.run-history", qos: .utility)
    /// Every request's entries, newest first: read from disk the first time pruning weighs them, then kept in step with
    /// each change. Only `queue` touches it; the lock only makes that checkable.
    private let catalog = Mutex<[RunKey: [RunHistoryStore.Entry]]?>(nil)

    init(store: RunHistoryStore) {
        self.store = store
    }

    /// Writes the run, then prunes under `policy`, reporting any runs that took.
    func save(
        _ exchange: RequestExchange,
        policy: RunHistoryPolicy,
        now: Date,
        onRemove: @escaping @Sendable (Removal) -> Void
    ) {
        queue.async { [self] in
            guard let entry = store.insert(exchange) else {
                return
            }
            let key = RunKey(exchange.requestID, in: exchange.projectID)
            catalog.withLock { catalog in
                catalog?[key, default: []].removeAll { $0.summary.id == entry.summary.id }
                catalog?[key, default: []].insert(entry, at: 0)
            }
            report(prunedOnQueue(policy, now: now), to: onRemove)
        }
    }

    func prune(policy: RunHistoryPolicy, now: Date, onRemove: @escaping @Sendable (Removal) -> Void) {
        queue.async { [self] in
            report(prunedOnQueue(policy, now: now), to: onRemove)
        }
    }

    func summaries(for request: RequestNodeID, in project: ProjectID) -> [RunSummary] {
        queue.sync { store.entries(for: request, in: project).map(\.summary) }
    }

    func latest(for request: RequestNodeID, in project: ProjectID) -> RequestExchange? {
        queue.sync { store.latest(for: request, in: project) }
    }

    /// Decodes on the queue, never the caller's thread: a stored run can be megabytes of JSON.
    func load(_ run: RunID, for request: RequestNodeID, in project: ProjectID) async -> RequestExchange? {
        await withCheckedContinuation { continuation in
            queue.async { [store] in
                continuation.resume(returning: store.load(run, for: request, in: project))
            }
        }
    }

    func outcomes(in project: ProjectID) -> [RequestNodeID: RunOutcomeKind] {
        queue.sync { store.outcomes(in: project) }
    }

    /// Bytes every request's runs take on disk.
    func totalSize() async -> Int {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                let size = catalog.withLock { catalog in
                    loaded(&catalog).values.joined().reduce(0) { $0 + $1.storedByteCount }
                }
                continuation.resume(returning: size)
            }
        }
    }

    func removeAll(for request: RequestNodeID, in project: ProjectID) {
        queue.sync {
            store.removeAll(for: request, in: project)
            _ = catalog.withLock { $0?.removeValue(forKey: RunKey(request, in: project)) }
        }
    }

    func removeAll(in project: ProjectID) {
        queue.sync {
            store.removeAll(in: project)
            catalog.withLock { catalog in
                catalog = catalog?.filter { $0.key.projectID != project }
            }
        }
    }

    func removeEverything() {
        queue.sync {
            store.removeEverything()
            catalog.withLock { $0 = [:] }
        }
    }

    func move(_ requests: [RequestNodeID], from source: ProjectID, to destination: ProjectID) {
        queue.sync {
            store.move(requests, from: source, to: destination)
            catalog.withLock { catalog in
                for request in requests {
                    let entries = catalog?.removeValue(forKey: RunKey(request, in: source))
                    catalog?[RunKey(request, in: destination)] = entries
                }
            }
        }
    }

    /// Waits for every queued save, as on quit, where the process could otherwise exit mid-write.
    func flush() {
        queue.sync {}
    }

    /// Which runs `policy` lets go, oldest first.
    ///
    /// Retention takes every run older than it allows except each request's newest, so a request's last response
    /// survives however long ago it ran. The size limit then takes the oldest runs across every project, a request's
    /// newest only once no older run is left anywhere.
    static func doomed(in catalog: [RunKey: [RunHistoryStore.Entry]], policy: RunHistoryPolicy, now: Date) -> Removal {
        var doomed: Removal = [:]
        var kept: [Candidate] = []
        let cutoff = policy.retention.map { now.addingTimeInterval(-$0) }
        for (key, entries) in catalog {
            for (index, entry) in entries.enumerated() {
                if index > 0, let cutoff, entry.summary.startedAt < cutoff {
                    doomed[key, default: []].insert(entry.summary.id)
                } else {
                    kept.append(Candidate(key: key, entry: entry, isNewest: index == 0))
                }
            }
        }
        var total = kept.reduce(0) { $0 + $1.entry.storedByteCount }
        guard total > policy.sizeLimit else {
            return doomed
        }
        kept.sort { lhs, rhs in
            lhs.isNewest == rhs.isNewest ? lhs.entry.summary.startedAt < rhs.entry.summary.startedAt : !lhs.isNewest
        }
        for candidate in kept {
            guard total > policy.sizeLimit else {
                break
            }
            doomed[candidate.key, default: []].insert(candidate.entry.summary.id)
            total -= candidate.entry.storedByteCount
        }
        return doomed
    }

    /// A run the size limit may take.
    private struct Candidate {
        let key: RunKey
        let entry: RunHistoryStore.Entry
        let isNewest: Bool
    }

    private func prunedOnQueue(_ policy: RunHistoryPolicy, now: Date) -> Removal {
        let removal = catalog.withLock { catalog -> Removal in
            let doomed = Self.doomed(in: loaded(&catalog), policy: policy, now: now)
            for (key, runs) in doomed {
                catalog?[key]?.removeAll { runs.contains($0.summary.id) }
                if catalog?[key]?.isEmpty == true {
                    catalog?[key] = nil
                }
            }
            return doomed
        }
        for (key, runs) in removal {
            store.remove(runs, for: key.requestID, in: key.projectID)
        }
        return removal
    }

    private func loaded(_ catalog: inout [RunKey: [RunHistoryStore.Entry]]?) -> [RunKey: [RunHistoryStore.Entry]] {
        if let catalog {
            return catalog
        }
        let entries = store.allEntries()
        catalog = entries
        return entries
    }

    private func report(_ removal: Removal, to onRemove: @Sendable (Removal) -> Void) {
        if !removal.isEmpty {
            onRemove(removal)
        }
    }
}
