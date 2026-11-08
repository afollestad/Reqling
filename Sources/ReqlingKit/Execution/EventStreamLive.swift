import Foundation

/// One running event stream as `RequestRunner` sees it: the record it grows from `HTTPExecutor.executeStreaming`'s
/// events across every reconnect, what the next reconnect sends, and what stops it early.
///
/// Each connection numbers its events from 0, so entries take their sequences from one counter across connections,
/// shared with the notes between them; it skips ahead by each drop the executor reports, so gaps show where events
/// were left out. Main-actor isolated like the runner, so each partial record goes straight into `latest`.
@MainActor
final class EventStreamLive: LiveRun {
    struct Context {
        let runID: RunID
        let projectID: ProjectID
        let requestID: RequestNodeID
        let startedAt: Date
        let environmentName: String?
        let request: ResolvedHTTPRequest
        let unresolvedVariables: [String]
        let limit: StreamLimit?
        /// The run's scripts, whose masked report every partial exchange carries: the pre-request phase's, and the
        /// stream phase's as it goes.
        var scripts: ScriptSession?
    }

    let context: Context
    /// The first connection's head, with its timing once that connection ends; `nil` until a stream opens. Later
    /// connections only add notes.
    private var head: HTTPResponseRecord?
    private var hasMetrics = false
    private var window = LiveWindow<EventStreamEntry>(limit: EventStreamRecord.entryLimit, byteLimit: GRPCLiveCall.byteLimit) {
        $0.byteCount
    }
    private var nextSequence = 0
    private(set) var eventCount = 0
    /// Drops and body bytes of the connections that ended, and the running totals of the open one.
    private var droppedBefore = 0
    private var droppedNow = 0
    private var receivedBefore = 0
    private var receivedNow = 0
    private var reconnectCount = 0
    /// What a reconnect sends as `Last-Event-ID`; empty sends none.
    private(set) var lastEventID = ""
    private(set) var retryMilliseconds: Int?
    private var end: EventStreamRecord.End?
    /// Seconds from the run's start to its latest activity, which the record's duration shows while it is open.
    private var activity: TimeInterval = 0
    /// A stream bound (`Context.limit`) was reached; the stream stops as `.limit`, taking no more events.
    private(set) var reachedLimit = false
    /// Cancels what the run is waiting on, the open connection or a reconnect's delay, so a reached limit stops it.
    var interrupt: (() -> Void)?
    /// Stops the stream once `limit.maxDuration` has passed since it opened.
    var limitTimer: Task<Void, Never>?
    var lastPublished: ContinuousClock.Instant?
    var isPublishPending = false

    init(context: Context) {
        self.context = context
    }

    /// A response turned out to be an event stream; until then the run is an ordinary request in flight.
    var hasOpened: Bool {
        head != nil
    }

    /// A stream opened and has not ended.
    var isOpen: Bool {
        head != nil && end == nil
    }

    func apply(_ event: HTTPStreamEvent) {
        switch event {
        case .opened(let head, let timestamp):
            if self.head == nil {
                self.head = head
            } else {
                reconnectCount += 1
                note("Reconnected", at: timestamp)
            }
            activity = offset(at: timestamp)
        case .event(let event, _, let receivedByteCount, let timestamp):
            guard !reachedLimit else {
                return
            }
            eventCount += 1
            receivedNow = receivedByteCount
            append(.event(event), at: timestamp)
        case .lastEventID(let id):
            lastEventID = id
        case .retry(let milliseconds):
            retryMilliseconds = milliseconds
        case .omitted(let total):
            // Drops after a reached limit are events past it, which the stream no longer takes.
            guard !reachedLimit else {
                return
            }
            let newly = total - droppedNow
            droppedNow = total
            eventCount += newly
            nextSequence += newly
        }
    }

    /// One connection ended: its totals carry forward, and the first connection's metrics complete the head.
    func connectionEnded(head: HTTPResponseRecord, receivedByteCount: Int) {
        if !hasMetrics, var merged = self.head {
            merged.timing = head.timing
            merged.protocolName = head.protocolName
            merged.tlsVersion = head.tlsVersion
            merged.presentedClientCertificate = head.presentedClientCertificate
            merged.redirectCount = head.redirectCount
            self.head = merged
            hasMetrics = true
        }
        droppedBefore += droppedNow
        droppedNow = 0
        receivedBefore += receivedByteCount
        receivedNow = 0
    }

    /// Something happened to the connection, shown in place on the timeline.
    func note(_ text: String, at date: Date = Date()) {
        append(.note(text), at: date)
    }

    func stopAtLimit() {
        guard !reachedLimit else {
            return
        }
        reachedLimit = true
        interrupt?()
    }

    var exchange: RequestExchange {
        exchange(at: nil)
    }

    func finished(_ end: EventStreamRecord.End, now: Date = Date()) -> RequestExchange {
        self.end = end
        limitTimer?.cancel()
        return exchange(at: now)
    }

    var record: EventStreamRecord {
        let newest = window.newest
        return EventStreamRecord(
            entries: newest.entries,
            eventCount: eventCount,
            trimmedEntryCount: newest.trimmedCount,
            droppedEventCount: droppedBefore + droppedNow,
            receivedByteCount: receivedBefore + receivedNow,
            reconnectCount: reconnectCount,
            lastEventID: lastEventID.isEmpty ? nil : lastEventID,
            retryMilliseconds: retryMilliseconds,
            end: end
        )
    }

    /// `ended` is when the stream stopped; while it is open, the duration runs to its latest activity.
    private func exchange(at ended: Date?) -> RequestExchange {
        var response = head
            ?? HTTPResponseRecord(statusCode: 200, headers: [], body: Data(), url: context.request.url, startedAt: context.startedAt, duration: 0)
        response.duration = ended.map(offset) ?? activity
        response.eventStream = record
        return RequestExchange(
            id: context.runID,
            projectID: context.projectID,
            requestID: context.requestID,
            startedAt: context.startedAt,
            environmentName: context.environmentName,
            request: context.request,
            outcome: .response(response),
            unresolvedVariables: context.unresolvedVariables,
            scriptReport: context.scripts?.shownReport
        )
    }

    private func append(_ kind: EventStreamEntry.Kind, at date: Date) {
        activity = offset(at: date)
        window.append(EventStreamEntry(sequence: nextSequence, offset: activity, kind: kind))
        nextSequence += 1
    }

    private func offset(at date: Date) -> TimeInterval {
        max(0, date.timeIntervalSince(context.startedAt))
    }
}
