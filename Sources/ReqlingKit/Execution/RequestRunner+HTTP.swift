import Foundation

/// When to stop an event stream early: once `maxDuration` has passed since it opened, or after `maxEvents` events,
/// whichever comes first. An agent's run waits for the stream to end, so it always carries one.
public struct StreamLimit: Hashable, Sendable {
    public var maxDuration: Duration?
    public var maxEvents: Int?

    public init(maxDuration: Duration? = nil, maxEvents: Int? = nil) {
        self.maxDuration = maxDuration
        self.maxEvents = maxEvents
    }
}

/// HTTP runs: one exchange, or, when the response is an event stream (`HTTPExecutor.executeStreaming`), the stream
/// kept open and published as it goes until it ends, is stopped, or reaches its `StreamLimit`.
///
/// Only a GET stream reconnects, as a browser's `EventSource` does (it only ever sends GET): whenever it ends, after the
/// server's `retry:` or `defaultReconnectDelay`, sending `Last-Event-ID`, until a reconnect is answered with anything
/// but a stream. Reconnecting another method would send its body again: a POST to an LLM API would run the whole
/// generation a second time.
extension RequestRunner {
    /// How long a GET stream waits to reconnect when the server has sent no `retry:`. The spec leaves it to the client;
    /// browsers wait a few seconds.
    static let defaultReconnectDelay: Duration = .seconds(3)

    /// What every connection of one HTTP run shares.
    struct HTTPRun {
        let preparation: PreparedRun
        let live: EventStreamLive
        let key: RunKey
        /// False for an unsaved run, which records its events without showing them.
        let publishes: Bool

        var reconnects: Bool {
            preparation.prepared.summary.method.uppercased() == "GET"
        }
    }

    /// The whole of an HTTP run, inside the run's task: its pre-request scripts, preparing the request with what they
    /// left, and sending it. Post-response scripts run after (`finishScripts`), outside this task, so a stopped stream
    /// still runs them.
    func executeHTTP(_ key: RunKey, options: RunOptions, stamp: RunStamp, session: ScriptSession?) async -> RequestExchange {
        let request = key.requestID
        let project = key.projectID
        if let session, let failure = await runPreRequestScripts(session, key: key, options: options) {
            return failedExchange(request, in: project, startedAt: stamp.startedAt, failure)
        }
        // A newer run replaced this one while its scripts ran; it must not take the newer run's place.
        guard !Task.isCancelled else {
            return failedExchange(request, in: project, startedAt: stamp.startedAt, Self.failure(for: HTTPExecutionError.cancelled))
        }
        let preparation: PreparedRun
        do {
            preparation = try prepareRun(request, in: project, options: options, session: session)
        } catch {
            return failedExchange(request, in: project, startedAt: stamp.startedAt, error)
        }
        let executor = executor(for: project)
        let live = EventStreamLive(context: EventStreamLive.Context(
            runID: stamp.id,
            projectID: project,
            requestID: request,
            startedAt: stamp.startedAt,
            environmentName: preparation.environmentName,
            request: preparation.prepared.summary,
            unresolvedVariables: preparation.prepared.unresolvedVariables,
            limit: options.streamLimit,
            scriptReport: session?.shownReport
        ))
        liveStreams[key] = live
        let run = HTTPRun(preparation: preparation, live: live, key: key, publishes: options.unsaved == nil)
        let exchange = await runHTTP(run, executor: executor)
        if liveStreams[key] === live {
            liveStreams[key] = nil
            eventStreams.remove(key)
        }
        return exchange
    }

    /// The whole of an HTTP run, inside the run's task so `cancel` and `forget` reach every await. Until a response
    /// opens a stream, this is one ordinary exchange.
    private func runHTTP(_ run: HTTPRun, executor: HTTPExecutor) async -> RequestExchange {
        let live = run.live
        var attempt = run.preparation.prepared
        while true {
            let request = attempt
            let connection = Task {
                try await executor.executeStreaming(request, tls: run.preparation.tls) { event in
                    await self.receive(event, on: run)
                }
            }
            live.interrupt = { connection.cancel() }
            let result = await withTaskCancellationHandler {
                await connection.result
            } onCancel: {
                connection.cancel()
            }
            live.interrupt = nil
            let delay = live.retryMilliseconds.map { Duration.milliseconds($0) } ?? Self.defaultReconnectDelay
            if let exchange = settle(result, of: run, delay: delay) {
                return exchange
            }
            guard await wait(delay, live: live) else {
                return live.finished(live.reachedLimit ? .limit : .stopped)
            }
            attempt = run.preparation.prepared
            if !live.lastEventID.isEmpty {
                attempt.urlRequest.setValue(live.lastEventID, forHTTPHeaderField: "Last-Event-ID")
            }
        }
    }

    /// What a connection's end means for the run: its final exchange, or `nil` to reconnect after `delay`.
    private func settle(_ result: Result<HTTPExecution, any Error>, of run: HTTPRun, delay: Duration) -> RequestExchange? {
        let live = run.live
        switch result {
        case .failure(let error):
            let failure = Self.failure(for: error).redacting(run.preparation.prepared.redaction)
            guard live.hasOpened else {
                return exchange(of: run, outcome: .failure(failure))
            }
            guard failure.kind != .cancelled else {
                return live.finished(live.reachedLimit ? .limit : .stopped)
            }
            // A reconnect that got no response at all: the spec keeps trying.
            note("Couldn't reconnect: \(failure.message) Retrying in \(Self.describe(delay)).", on: run)
            return nil
        case .success(.response(let response)):
            guard live.hasOpened else {
                return exchange(of: run, outcome: .response(response))
            }
            if response.statusCode == 204 {
                live.note("The server answered 204 No Content, which ends the stream.")
            }
            return live.finished(Self.refusal(response))
        case .success(.stream(let head, let end, let receivedByteCount)):
            live.connectionEnded(head: head, receivedByteCount: receivedByteCount)
            guard end != .stopped, !live.reachedLimit, !Task.isCancelled else {
                return live.finished(live.reachedLimit ? .limit : .stopped)
            }
            guard run.reconnects else {
                return live.finished(end)
            }
            let reason = Self.describe(end, timeout: run.preparation.prepared.urlRequest.timeoutInterval)
            let id = live.lastEventID.isEmpty ? "" : " with Last-Event-ID \(live.lastEventID)"
            note("\(reason) Reconnecting in \(Self.describe(delay))\(id).", on: run)
            return nil
        }
    }

    private func receive(_ event: HTTPStreamEvent, on run: HTTPRun) {
        let live = run.live
        // A replaced or forgotten run keeps streaming until its cancellation lands; it must not publish.
        guard liveStreams[run.key] === live else {
            return
        }
        let wasOpened = live.hasOpened
        live.apply(event)
        if !wasOpened, live.hasOpened {
            if run.publishes {
                eventStreams.insert(run.key)
            }
            if let maxDuration = live.context.limit?.maxDuration {
                let sleep = self.sleep
                live.limitTimer = Task { [weak live] in
                    guard (try? await sleep(maxDuration)) != nil else {
                        return
                    }
                    live?.stopAtLimit()
                }
            }
        }
        if let maxEvents = live.context.limit?.maxEvents, live.eventCount >= maxEvents {
            live.stopAtLimit()
        }
        if run.publishes {
            publishThrottled(live, key: run.key) { [weak self] in self?.liveStreams[run.key] === live }
        }
    }

    /// Notes what happened to the connection, shown at once: nothing else publishes while the run waits to reconnect.
    private func note(_ text: String, on run: HTTPRun) {
        run.live.note(text)
        if run.publishes, liveStreams[run.key] === run.live {
            publish(run.live, key: run.key)
        }
    }

    /// Waits out a reconnect's delay; false when the run was stopped or reached its limit meanwhile.
    private func wait(_ delay: Duration, live: EventStreamLive) async -> Bool {
        let sleep = self.sleep
        let waiting = Task {
            try await sleep(delay)
        }
        live.interrupt = { waiting.cancel() }
        defer { live.interrupt = nil }
        let result = await withTaskCancellationHandler {
            await waiting.result
        } onCancel: {
            waiting.cancel()
        }
        if case .failure = result {
            return false
        }
        return !live.reachedLimit && !Task.isCancelled
    }

    /// A run that never opened a stream: one exchange, as every HTTP run was before streams.
    private func exchange(of run: HTTPRun, outcome: RequestExchange.Outcome) -> RequestExchange {
        RequestExchange(
            projectID: run.key.projectID,
            requestID: run.key.requestID,
            startedAt: run.live.context.startedAt,
            environmentName: run.preparation.environmentName,
            request: run.preparation.prepared.summary,
            outcome: outcome,
            unresolvedVariables: run.preparation.prepared.unresolvedVariables
        )
    }

    /// Why a reconnect answered without a stream ends it, as the spec has it: 204 means the server wants no more, and
    /// anything else fails the stream.
    private static func refusal(_ response: HTTPResponseRecord) -> EventStreamRecord.End {
        guard response.statusCode != 204 else {
            return .closed
        }
        let type = response.header("Content-Type").map { " (\($0))" } ?? ""
        let message = "Reconnecting got \(response.statusCode) \(response.reasonPhrase)\(type) instead of an event stream."
        return .failed(message: message)
    }

    private static func describe(_ end: EventStreamRecord.End, timeout: TimeInterval) -> String {
        switch end {
        case .closed, .stopped, .limit: "The server closed the stream."
        case .timedOut: "No data for \(describe(.milliseconds(Int(timeout * 1_000)))), the request's timeout."
        case .failed(let message): "Connection lost: \(message)"
        }
    }

    /// Like `ResponseStatusBar.duration`, which shows times the same way in every locale.
    private static func describe(_ delay: Duration) -> String {
        let milliseconds = Int(delay / .milliseconds(1))
        guard milliseconds >= 1_000 else {
            return "\(milliseconds) ms"
        }
        return String(format: "%g s", Double(milliseconds) / 1_000)
    }

    nonisolated static func failure(for error: any Error) -> RunFailure {
        switch error as? HTTPExecutionError {
        case .cancelled:
            RunFailure(kind: .cancelled, message: HTTPExecutionError.cancelled.localizedDescription)
        case .timedOut:
            RunFailure(kind: .timedOut, message: HTTPExecutionError.timedOut.localizedDescription)
        case .untrustedServer(let reason):
            RunFailure(kind: .tls, message: reason)
        case .transport(let message):
            RunFailure(kind: .transport, message: message)
        case nil:
            RunFailure(kind: .transport, message: error.localizedDescription)
        }
    }
}
