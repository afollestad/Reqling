import Foundation
@testable import ReqlingKit
import ReqlingScriptProtocol
import ReqlingTemplating
import Synchronization
import XCTest

/// How a stream phase's results add up across calls, from events a test writes, with no helper.
@MainActor
final class ScriptSessionStreamTests: XCTestCase {
    private var changes = 0
    /// One element per `ScriptStreamHooks.changed`, so a test can wait for the phase to take in what it wrote.
    private let changeSignals = AsyncStream<Void>.makeStream()

    private func session(secrets: [Variable] = []) -> ScriptSession {
        var document = ProjectDocument(name: "Feed")
        document.defaultEnvironment.variables = secrets
        let scope = VariableScope(global: .global(), document: document, activeEnvironmentID: nil, currentValues: .empty)
        let session = ScriptSession(
            project: ProjectID(),
            item: RequestItem.http("Feed"),
            mode: .run,
            scope: scope,
            environments: VariableScope.Environments(global: .global(), defaultEnvironment: document.defaultEnvironment, active: nil),
            levels: [.stream: [ScriptLevelSource(kind: .request, name: "Feed", path: "feed.stream.js", source: "")]],
            secretSink: nil,
            cookieJar: { _ in nil }
        )
        session.isTrusted = true
        return session
    }

    private func start(_ session: ScriptSession, _ runner: ScriptedStreamRunner) {
        session.startStream(
            .eventStream(code: 200, status: "OK", headers: []),
            canSend: false,
            runner: runner,
            timeLimit: .seconds(10),
            hooks: ScriptStreamHooks(
                changed: { [weak self] in
                    self?.changes += 1
                    self?.changeSignals.continuation.yield()
                },
                send: { _ in nil }
            )
        )
    }

    /// Writes `events`, ends the helper as `termination` says, and waits for the phase to end.
    private func run(
        _ events: [ScriptRunnerEvent],
        in session: ScriptSession,
        termination: ScriptStreamTermination = ScriptStreamTermination(reason: .finished, item: nil, abandoned: 0)
    ) async -> ScriptPhaseReport? {
        let runner = ScriptedStreamRunner(termination: termination)
        start(session, runner)
        runner.write(events)
        _ = await session.finishStream()
        return session.report.phase(.stream)
    }

    private func call(_ item: Int, _ events: [ScriptRunnerEvent]) -> [ScriptRunnerEvent] {
        [.callStarted(item: item)] + events + [.callFinished(item: item)]
    }

    func testRunsOfATestAcrossCallsAddUpToOneRowPerLevelAndName() async throws {
        var events: [ScriptRunnerEvent] = [.test(level: 0, name: "set up", result: .passed, message: nil), .registered(handlers: 1)]
        for item in 1...500 {
            let fails = item == 17 || item == 300
            events += call(item, [
                .test(level: 0, name: "is JSON", result: fails ? .failed : .passed, message: fails ? "bad \(item)" : nil),
                .test(level: 0, name: "later", result: .skipped, message: nil)
            ])
        }

        let report = await run(events, in: session())
        let phase = try XCTUnwrap(report)

        let tests = try XCTUnwrap(phase.levels.first?.tests)
        XCTAssertEqual(tests.map(\.name), ["set up", "is JSON", "later"])
        XCTAssertEqual(tests[1].result, .failed)
        XCTAssertEqual(tests[1].tally, ScriptTestCounts(passed: 498, failed: 2))
        XCTAssertEqual(tests[1].message, "bad 17", "The first failure's message")
        XCTAssertEqual(tests[1].firstFailedItem, 17)
        XCTAssertEqual(tests[2].result, .skipped)
        XCTAssertEqual(tests[0].tally, ScriptTestCounts(passed: 1))
        XCTAssertNil(tests[0].firstFailedItem)
        XCTAssertEqual(ScriptReport(phases: [phase]).testCounts, ScriptTestCounts(passed: 1, failed: 1, skipped: 1), "Rows count once")
        XCTAssertEqual(phase.stream?.handledCount, 500)
        XCTAssertEqual(changes, 502, "The top level, each call, and the end")
    }

    func testTheConsoleKeepsItsNewestEntriesAndChangesAreListedOnceEach() async throws {
        let session = session()
        var events: [ScriptRunnerEvent] = [.registered(handlers: 1)]
        events += call(1, (0..<1_005).map { .console(level: 0, severity: .log, text: "entry \($0)") })
        let cookie = ScriptCookieWrite.remove(ScriptCookieIdentity(name: "sid", domain: "example.com", isHostOnly: true, path: "/"))
        events += call(2, [
            .variable(VariableWrite(scope: .environment, key: "token", value: "a", isSecret: false)),
            .variable(VariableWrite(scope: .local, key: "n", value: "1", isSecret: true)),
            .variable(VariableWrite(scope: .environment, key: "token", value: "b", isSecret: false)),
            .variable(VariableWrite(scope: .environment, key: "token", value: nil, isSecret: false)),
            .variable(VariableWrite(scope: .local, key: "n", value: nil, isSecret: false)),
            .cookie(cookie),
            .cookie(cookie)
        ])

        let report = await run(events, in: session)
        let phase = try XCTUnwrap(report)

        XCTAssertEqual(phase.console.count, ScriptSession.streamConsoleLimit)
        XCTAssertEqual(phase.console.first?.text, "entry 5")
        XCTAssertTrue(phase.isConsoleTruncated)
        XCTAssertEqual(phase.variableChanges.map(\.key), ["token", "n", "token", "n"], "Each kind of change once")
        XCTAssertEqual(phase.variableChanges.map(\.isUnset), [false, false, true, true])
        XCTAssertTrue(ScriptReport(phases: [phase]).madeRunLocalSecrets, "Unsetting it later doesn't hide that it was made")
        XCTAssertEqual(phase.cookieChanges.count, 1)
        XCTAssertEqual(session.layers.lookup("token")?.variable.value, nil, "What handlers set is what later phases see")
    }

    func testALevelsHandlerFailuresKeepTheFirstAndCountTheRest() async throws {
        let error = ScriptError(name: "TypeError", message: "x is undefined", line: 2)
        var events: [ScriptRunnerEvent] = [.registered(handlers: 1)]
        for item in [3, 4, 9] {
            events += call(item, [.levelFailed(level: 0, error: ScriptError(name: "TypeError", message: "x is undefined", line: item))])
        }
        events[2] = .levelFailed(level: 0, error: error)

        let report = await run(events, in: session())
        let phase = try XCTUnwrap(report)

        let level = try XCTUnwrap(phase.levels.first)
        XCTAssertEqual(level.error, error)
        XCTAssertEqual(level.failedItem, 3)
        XCTAssertEqual(level.failedCallCount, 3)
        XCTAssertEqual(phase.failureSummary, "The stream script of the request failed on event 3 at line 2: TypeError: x is undefined")
    }

    func testWhatReachesNoHandlerIsCountedByWhyAndATimeoutNamesItsItem() async throws {
        let session = session()
        let runner = ScriptedStreamRunner(
            termination: ScriptStreamTermination(reason: .timedOut, item: 9, abandoned: 1),
            deliveries: [.queued(dropped: 2), .refused, .queued(dropped: 0)],
            waiting: 4
        )
        start(session, runner)
        for number in 1...3 {
            session.deliver(.event(ScriptStreamEvent(id: nil, event: nil, data: "", retry: nil)), number: number)
        }
        session.stopStream()
        runner.write([.registered(handlers: 1)])
        let outcome = await session.finishStream()

        let phase = try XCTUnwrap(session.report.phase(.stream))
        XCTAssertEqual(outcome, .failed)
        XCTAssertEqual(phase.stream?.droppedCount, 2)
        XCTAssertEqual(phase.stream?.skippedCount, 6, "One refused, four dropped by Stop, one the helper never got")
        XCTAssertEqual(phase.stream?.failedItem, 9)
        XCTAssertEqual(
            phase.error?.message,
            "Handling event 9 didn't finish within 10 s, the time limit in Settings ▸ Requests, so the stream scripts stopped."
        )
    }

    func testMaskingKeepsWhatAddsUpAndQuittingEndsThePhaseAtOnce() async throws {
        let session = session()
        let runner = ScriptedStreamRunner(termination: ScriptStreamTermination(reason: .cancelled, item: nil, abandoned: 0), waiting: 2)
        start(session, runner)
        runner.write([.registered(handlers: 1)] + call(1, [
            .variable(VariableWrite(scope: .local, key: "token", value: "s3cr3t", isSecret: true)),
            .test(level: 0, name: "sent s3cr3t", result: .failed, message: "got s3cr3t")
        ]))
        var signals = changeSignals.stream.makeAsyncIterator()
        _ = await signals.next()
        _ = await signals.next()
        XCTAssertEqual(session.report.phase(.stream)?.stream?.handledCount, 1, "The top level and the call are in")

        session.interruptStream()

        let shown = try XCTUnwrap(session.shownReport?.phase(.stream))
        let test = try XCTUnwrap(shown.levels.first?.tests.first)
        XCTAssertEqual(test.name, "sent \(TemplateResolver.mask)")
        XCTAssertEqual(test.message, "got \(TemplateResolver.mask)")
        XCTAssertEqual(test.tally, ScriptTestCounts(failed: 1))
        XCTAssertEqual(test.firstFailedItem, 1)
        XCTAssertEqual(shown.stream?.isInterrupted, true)
        XCTAssertEqual(shown.stream?.skippedCount, 2, "What waited at quit")
        XCTAssertTrue(runner.wasCancelled)
        runner.finish()
        let outcome = await session.finishStream()
        XCTAssertEqual(outcome, .cancelled)
    }
}

/// Hands a stream phase the events a test writes: each delivery's result in turn, what Stop finds waiting, and how
/// the helper ends once the test finishes writing.
private final class ScriptedStreamRunner: ScriptRunning {
    private let stream = AsyncStream<ScriptRunnerEvent>.makeStream()
    private let termination: ScriptStreamTermination
    private let deliveries: Mutex<[ScriptStreamDelivery]>
    private let waiting: Int
    private let cancelled = Mutex(false)

    init(termination: ScriptStreamTermination, deliveries: [ScriptStreamDelivery] = [], waiting: Int = 0) {
        self.termination = termination
        self.deliveries = Mutex(deliveries)
        self.waiting = waiting
    }

    var wasCancelled: Bool {
        cancelled.withLock { $0 }
    }

    /// Writes `events`, then ends the helper, unless it ends by being cancelled, which `finish` stands for.
    func write(_ events: [ScriptRunnerEvent]) {
        for event in events {
            stream.continuation.yield(event)
        }
        if termination.reason != .cancelled {
            finish()
        }
    }

    func finish() {
        stream.continuation.finish()
    }

    func run(_ input: ScriptRunnerInput, blobs: [Data], timeLimit: Duration) -> ScriptExecution {
        .failed("Only stream phases run here.")
    }

    func stream(_ input: ScriptRunnerInput, timeLimit: Duration) -> ScriptStreamExecution {
        ScriptStreamExecution(
            events: stream.stream,
            reply: { _, _ in },
            deliver: { _ in self.deliveries.withLock { $0.isEmpty ? .queued(dropped: 0) : $0.removeFirst() } },
            closeSending: {},
            stop: { self.waiting },
            end: {},
            termination: { self.termination },
            cancel: { self.cancelled.withLock { $0 = true } }
        )
    }
}
