import Foundation
import ReqlingScriptProtocol

/// A run's stream phase: started when its stream opens, handed each item as it arrives without waiting, and finished
/// once the stream ends. Its report is in `ScriptSession.report` from the start and changes as calls finish, so an open
/// stream's Tests tab is live.
///
/// Results add up across calls rather than per call, so a stream's report stays bounded however long it runs: a test
/// is one row per level and name (`ScriptTestReport.tally`), a level's handler errors are its first with a count,
/// changed variables and cookies are listed once each, and the console keeps its newest entries.
extension ScriptSession {
    /// The newest console entries a stream phase keeps.
    static let streamConsoleLimit = ScriptLimits.standard.consoleEntries

    func startStream(_ opening: ScriptStreamOpening, canSend: Bool, runner: any ScriptRunning, timeLimit: Duration, hooks: ScriptStreamHooks) {
        guard stream == nil, mode == .run, isTrusted == true, let phaseLevels = levels[.stream], !phaseLevels.isEmpty else {
            return
        }
        let setup = ScriptStreamSetup(opening: opening, canSend: canSend)
        let execution = runner.stream(input(.stream, levels: phaseLevels, response: nil, stream: setup), timeLimit: timeLimit)
        let index = beginPhase(ScriptPhaseReport(
            phase: .stream,
            levels: levelReports(.stream),
            stream: ScriptStreamReport(itemKind: opening.kind == .eventStream ? .event : .message)
        ))
        let run = ScriptStreamRun(execution: execution, reportIndex: index, hooks: hooks)
        stream = run
        run.driver = Task {
            for await event in execution.events {
                if case .fetch(let id, _, _) = event {
                    execution.reply(Self.unansweredFetch(id), Data())
                    continue
                }
                self.apply(event, in: run)
            }
            return self.streamEnded(await execution.termination(), in: run, timeLimit: timeLimit)
        }
    }

    /// Hands the handlers what the stream received; returns at once, however far behind they are.
    func deliver(_ content: ScriptStreamItem.Content, number: Int) {
        guard let stream else {
            return
        }
        switch stream.execution.deliver(ScriptStreamItem(number: number, content: content)) {
        case .queued(let dropped) where dropped > 0:
            updateStream(stream) { $0.droppedCount += dropped }
        case .refused:
            updateStream(stream) { $0.skippedCount += 1 }
        default:
            break
        }
    }

    /// The connection or call no longer takes what `rq.send` sends. Only the first time tells the helper.
    func closeStreamSending() {
        guard let stream, !stream.isSendingClosed else {
            return
        }
        stream.isSendingClosed = true
        stream.execution.closeSending()
    }

    /// Stop, or a reached bound: the call in hand finishes, and what waits reaches no handler. Asked again while that
    /// call still runs, it stops the call too, so Stop never waits out a whole time limit twice.
    func stopStream() {
        guard let stream, !stream.isOver else {
            return
        }
        guard !stream.isStopped else {
            stream.execution.cancel()
            return
        }
        stream.isStopped = true
        let dropped = stream.execution.stop()
        if dropped > 0 {
            updateStream(stream) { $0.skippedCount += dropped }
        }
    }

    /// The stream ended: the handlers get what waits, then the phase ends.
    func endStream() {
        stream?.execution.end()
    }

    /// Waits for the stream phase to end, once `stopStream` or `endStream` let it; `nil` when none started.
    func finishStream() async -> PhaseOutcome? {
        await stream?.driver?.value
    }

    /// Kills the helper, as when the run is replaced or forgotten.
    func cancelStream() {
        stream?.execution.cancel()
    }

    /// Reqling is quitting: ends the phase at once, noting that what waited, and what the handlers were doing, never
    /// finished. Synchronous, for `RequestRunner.recordLiveRuns`.
    func interruptStream() {
        guard let stream, !stream.isOver else {
            return
        }
        stream.isOver = true
        let waiting = stream.execution.stop()
        stream.execution.cancel()
        updateStream(stream) { report in
            report.isInterrupted = true
            report.skippedCount += waiting
        }
    }

    /// Commits now, or once `RequestRunner.livePublishInterval` has passed since the last commit: a handler that sets a
    /// secret on every event then writes the Keychain at most ten times a second, while what it set still lands within
    /// that. The phase's end commits whatever is left (`RequestRunner.finishScripts`).
    func commitStream(to library: ProjectLibrary) {
        guard let stream else {
            commit(to: library)
            return
        }
        let interval = RequestRunner.livePublishInterval
        let now = ContinuousClock.now
        guard let last = stream.lastCommit, now - last < interval else {
            stream.lastCommit = now
            commit(to: library)
            return
        }
        guard !stream.isCommitPending else {
            return
        }
        stream.isCommitPending = true
        Task { [weak self] in
            try? await Task.sleep(until: last + interval)
            stream.isCommitPending = false
            stream.lastCommit = .now
            self?.commit(to: library)
        }
    }

    private func apply(_ event: ScriptRunnerEvent, in run: ScriptStreamRun) {
        switch event {
        case .callStarted(let item):
            run.currentItem = item
        case .callFinished:
            run.currentItem = nil
            updateStream(run) { $0.handledCount += 1 }
            run.hooks.changed()
        case .registered:
            run.hooks.changed()
        case .variable(let write):
            let change = absorb(write)
            updatePhase(at: run.reportIndex) { phase in
                run.listChange(change, in: &phase.variableChanges)
            }
        case .cookie(let write):
            let change = absorb(write)
            updatePhase(at: run.reportIndex) { phase in
                run.listChange(change, in: &phase.cookieChanges)
            }
        case .console(let level, let severity, let text):
            log(ScriptConsoleEntry(level: level, severity: severity, text: text), in: run)
        case .test(let level, let name, let result, let message):
            updatePhase(at: run.reportIndex) { phase in
                guard phase.levels.indices.contains(level) else {
                    return
                }
                if !run.tally(name: name, result: result, message: message, in: &phase.levels[level], level: level) {
                    phase.console.append(ScriptConsoleEntry(
                        level: level,
                        severity: .warn,
                        text: "Further tests in the stream scripts were not reported."
                    ))
                }
            }
        case .levelFailed(let level, let error):
            fail(level, error, in: run)
        case .send(let level, let message):
            switch run.hooks.send(message) {
            case .closed(let reason)?:
                log(ScriptConsoleEntry(level: level, severity: .warn, text: "rq.send: \(reason)"), in: run)
            case .invalid(let reason)?:
                fail(level, ScriptError(message: "rq.send: \(reason)"), in: run)
            case nil:
                break
            }
        case .flow(.setNextRequest(let request)):
            setNextRequest(request)
        default:
            break
        }
    }

    /// One level's failure: its top level's, or in a call, a handler's, counted with the first kept.
    private func fail(_ level: Int, _ error: ScriptError, in run: ScriptStreamRun) {
        updatePhase(at: run.reportIndex) { phase in
            guard phase.levels.indices.contains(level) else {
                return
            }
            guard let item = run.currentItem else {
                phase.levels[level].error = error
                return
            }
            if phase.levels[level].error == nil {
                phase.levels[level].error = error
                phase.levels[level].failedItem = item
            }
            phase.levels[level].failedCallCount = (phase.levels[level].failedCallCount ?? 0) + 1
        }
    }

    /// Keeps the newest entries, as a stream may print on every event for as long as it stays open.
    private func log(_ entry: ScriptConsoleEntry, in run: ScriptStreamRun) {
        updatePhase(at: run.reportIndex) { phase in
            phase.console.append(entry)
            if phase.console.count > Self.streamConsoleLimit {
                phase.console.removeFirst(phase.console.count - Self.streamConsoleLimit)
                phase.isConsoleTruncated = true
            }
        }
    }

    private func streamEnded(_ ended: ScriptStreamTermination, in run: ScriptStreamRun, timeLimit: Duration) -> PhaseOutcome {
        let wasInterrupted = run.isOver
        run.isOver = true
        var outcome: PhaseOutcome = .finished
        updatePhase(at: run.reportIndex) { phase in
            phase.stream?.skippedCount += ended.abandoned
            let noun = phase.stream?.itemKind.rawValue ?? "item"
            switch ended.reason {
            case .finished:
                break
            case .cancelled:
                outcome = .cancelled
            case .timedOut:
                let seconds = Int(timeLimit / .seconds(1))
                let limit = "within \(seconds) s, the time limit in Settings ▸ Requests"
                phase.error = ScriptError(name: "TimeoutError", message: ended.item.map {
                    "Handling \(noun) \($0) didn't finish \(limit), so the stream scripts stopped."
                } ?? "The stream scripts didn't finish \(limit).")
                phase.stream?.failedItem = ended.item
                outcome = .failed
            case .failed(let message):
                phase.error = ScriptError(message: message)
                phase.stream?.failedItem = ended.item
                outcome = .failed
            }
            if outcome == .finished, phase.levels.contains(where: { $0.error != nil }) {
                outcome = .failed
            }
        }
        secretSink?.collect(secretValues)
        if !wasInterrupted {
            run.hooks.changed()
        }
        return outcome
    }

    private func updateStream(_ run: ScriptStreamRun, _ change: (inout ScriptStreamReport) -> Void) {
        updatePhase(at: run.reportIndex) { phase in
            if var stream = phase.stream {
                change(&stream)
                phase.stream = stream
            }
        }
    }
}

/// How a stream phase reaches the run it belongs to.
struct ScriptStreamHooks {
    /// The phase's results or values changed: its top level ran, a call finished, or the phase ended.
    let changed: @MainActor () -> Void
    /// Sends what `rq.send` sent on the open connection or call; why it couldn't, when it couldn't.
    let send: @MainActor (ScriptOutgoingMessage) -> ScriptSendFailure?
}

/// Why a message `rq.send` sent didn't go out.
enum ScriptSendFailure: Equatable {
    /// The connection or call stopped taking messages before it arrived, which the script couldn't see: a warning.
    case closed(String)
    /// It can't be sent as given, such as JSON the gRPC method's input type doesn't take: the handler's failure.
    case invalid(String)
}

/// A running stream phase: its helper, where its report sits, and what adds its results up across calls.
@MainActor
final class ScriptStreamRun {
    let execution: ScriptStreamExecution
    let reportIndex: Int
    let hooks: ScriptStreamHooks
    var driver: Task<ScriptSession.PhaseOutcome, Never>?
    /// The item the helper is handling, which its tests and failures are about.
    var currentItem: Int?
    var isStopped = false
    var isSendingClosed = false
    /// The helper ended, or Reqling quit.
    var isOver = false
    var lastCommit: ContinuousClock.Instant?
    var isCommitPending = false
    /// Where each level's tests sit, by name.
    private var testRows: [Int: [String: Int]] = [:]
    private var hasDroppedTests = false

    init(execution: ScriptStreamExecution, reportIndex: Int, hooks: ScriptStreamHooks) {
        self.execution = execution
        self.reportIndex = reportIndex
        self.hooks = hooks
    }

    /// Adds a run of a test to its row, or a row for a new one. False, once, when a new one finds the report full.
    func tally(name: String, result: ScriptTestResult, message: String?, in level: inout ScriptLevelReport, level index: Int) -> Bool {
        guard let row = testRows[index]?[name] else {
            guard testRows.values.reduce(0, { $0 + $1.count }) < ScriptLimits.standard.tests else {
                defer { hasDroppedTests = true }
                return hasDroppedTests
            }
            testRows[index, default: [:]][name] = level.tests.count
            var tally = ScriptTestCounts()
            tally.add(result)
            level.tests.append(ScriptTestReport(
                name: name,
                result: result,
                message: message,
                tally: tally,
                firstFailedItem: result == .failed ? currentItem : nil
            ))
            return true
        }
        var test = level.tests[row]
        var tally = test.tally ?? ScriptTestCounts()
        if result == .failed, tally.failed == 0 {
            test.message = message
            test.firstFailedItem = currentItem
        }
        tally.add(result)
        test.tally = tally
        test.result = tally.failed > 0 ? .failed : tally.passed > 0 ? .passed : .skipped
        level.tests[row] = test
        return true
    }

    /// The variables, and the cookies, a stream phase lists.
    static let changeListLimit = 1_000

    /// Lists each kind of change to a variable or cookie once, as it last happened.
    func listChange<Change: ScriptListedChange>(_ change: Change, in changes: inout [Change]) {
        if let index = changes.firstIndex(where: { $0.listingKey == change.listingKey }) {
            changes[index] = change
        } else if changes.count < Self.changeListLimit {
            changes.append(change)
        }
    }
}

/// A change a stream phase lists once per variable or cookie and kind of change, so a set and an unset both show, and
/// a run-local secret a script made stays known (`ScriptReport.madeRunLocalSecrets`) whatever it did after.
protocol ScriptListedChange {
    var listingKey: [String] { get }
}

extension ScriptVariableChange: ScriptListedChange {
    var listingKey: [String] {
        [scope.rawValue, key, String(isUnset), String(isSecret)]
    }
}

extension ScriptCookieChange: ScriptListedChange {
    var listingKey: [String] {
        [name, domain, path, String(isRemoved)]
    }
}

private extension ScriptTestCounts {
    mutating func add(_ result: ScriptTestResult) {
        switch result {
        case .passed: passed += 1
        case .failed: failed += 1
        case .skipped: skipped += 1
        }
    }
}
