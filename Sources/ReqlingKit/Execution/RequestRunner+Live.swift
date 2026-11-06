import Foundation

/// A run that publishes partial exchanges into `RequestRunner.latest` while it is open: a gRPC call (`GRPCLiveCall`)
/// or an event stream (`EventStreamLive`).
@MainActor
protocol LiveRun: AnyObject {
    /// The run so far, with the ID every partial exchange shares with the final one.
    var exchange: RequestExchange { get }
    /// When `RequestRunner` last published this run, and whether a trailing publish is scheduled.
    var lastPublished: ContinuousClock.Instant? { get set }
    var isPublishPending: Bool { get set }
}

/// What every live run shares: throttled publishing, and the bookkeeping that keeps a live run's `latest` entry from
/// being cleared under it.
extension RequestRunner {
    /// How often a live run republishes into `latest`. Each publish copies its record, so publishing per event would
    /// make a fast stream's cost grow with every message; between publishes, events only accumulate.
    static let livePublishInterval: Duration = .milliseconds(100)

    /// Publishes `live` now, or once `livePublishInterval` has passed since the last publish: one trailing publish
    /// shows whatever arrived in between, so the last events never wait for more. `isCurrent` says whether the run
    /// still owns `key`; a replaced or forgotten run must not publish.
    func publishThrottled(_ live: some LiveRun, key: RunKey, isCurrent: @escaping @MainActor () -> Bool) {
        let now = ContinuousClock.now
        guard let last = live.lastPublished, now - last < Self.livePublishInterval else {
            publish(live, key: key, at: now)
            return
        }
        guard !live.isPublishPending else {
            return
        }
        live.isPublishPending = true
        Task {
            try? await Task.sleep(until: last + Self.livePublishInterval)
            live.isPublishPending = false
            if isCurrent() {
                self.publish(live, key: key, at: .now)
            }
        }
    }

    func publish(_ live: some LiveRun, key: RunKey, at instant: ContinuousClock.Instant = .now) {
        live.lastPublished = instant
        latest[key] = live.exchange
    }

    /// Whether `key` has an open gRPC call or event stream, whose partial exchange in `latest` is newer than anything
    /// the history holds or drops.
    func isLive(_ key: RunKey) -> Bool {
        liveCalls[key] != nil || liveStreams[key]?.isOpen == true
    }

    /// Forgets `key`'s live run, if any, so it can never publish again.
    func dropLive(_ key: RunKey) {
        liveCalls[key] = nil
        openStreams.remove(key)
        liveStreams[key] = nil
        eventStreams.remove(key)
    }

    /// Forgets every live run in `project`.
    func dropLive(in project: ProjectID) {
        liveCalls = liveCalls.filter { $0.key.projectID != project }
        openStreams = openStreams.filter { $0.projectID != project }
        liveStreams = liveStreams.filter { $0.key.projectID != project }
        eventStreams = eventStreams.filter { $0.projectID != project }
    }
}
