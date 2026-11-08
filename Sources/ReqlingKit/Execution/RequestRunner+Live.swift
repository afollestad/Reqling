import Foundation

/// A run that publishes partial exchanges into `RequestRunner.latest` while it is open: a gRPC call (`GRPCLiveCall`),
/// an event stream (`EventStreamLive`), or a WebSocket connection (`WebSocketLive`).
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

    /// Whether `key` has an open gRPC call, event stream, or WebSocket, whose partial exchange in `latest` is newer
    /// than anything the history holds or drops.
    func isLive(_ key: RunKey) -> Bool {
        liveCalls[key] != nil || liveStreams[key]?.isOpen == true || liveSockets[key] != nil
    }

    /// Saves every open run as Reqling quits, which would otherwise end unrecorded: an established gRPC call as
    /// `CANCELLED`, an open event stream and an open WebSocket as stopped, the WebSocket closing with 1001 Going Away
    /// as it goes (best effort: the process may end first), and a run that ended but isn't recorded yet, its stream or
    /// post-response scripts perhaps still running, as it came back. Each carries its scripts' report, noting what
    /// they didn't finish. Runs that haven't reached a server, and unsaved ones, are left as they are. Synchronous, for
    /// `applicationWillTerminate`; each run is detached once recorded, so a late end can't record it again.
    public func recordLiveRuns(now: Date = Date()) {
        for (key, stamp) in liveStamps {
            var exchange: RequestExchange
            let report = quitReport(for: key)
            if let pending = pendingPostExchanges[key] {
                exchange = pending
                detach(key)
            } else if let call = liveCalls[key], call.hasReachedServer {
                exchange = call.finished(.failed(.cancelled), now: now)
                detach(key)
            } else if let stream = liveStreams[key], stream.hasOpened {
                exchange = stream.finished(.stopped, now: now)
                detach(key)
            } else if let socket = liveSockets[key], socket.isOpen {
                exchange = socket.quit(now: now)
                // Cancelling would close with Disconnect's 1000 instead.
                detach(key, cancels: false)
            } else {
                continue
            }
            exchange.scriptReport = report ?? exchange.scriptReport
            _ = record(stamp.applied(to: exchange))
        }
    }

    /// Forgets `key`'s live run, if any, so it can never publish again.
    func dropLive(_ key: RunKey) {
        liveCalls[key] = nil
        openStreams.remove(key)
        liveStreams[key] = nil
        eventStreams.remove(key)
        liveSockets[key] = nil
        openSockets.remove(key)
        liveStamps[key] = nil
    }

    /// Forgets every live run in `project`.
    func dropLive(in project: ProjectID) {
        liveCalls = liveCalls.filter { $0.key.projectID != project }
        openStreams = openStreams.filter { $0.projectID != project }
        liveStreams = liveStreams.filter { $0.key.projectID != project }
        eventStreams = eventStreams.filter { $0.projectID != project }
        liveSockets = liveSockets.filter { $0.key.projectID != project }
        openSockets = openSockets.filter { $0.projectID != project }
        liveStamps = liveStamps.filter { $0.key.projectID != project }
    }
}
