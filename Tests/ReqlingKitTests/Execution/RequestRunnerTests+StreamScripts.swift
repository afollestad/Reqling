import Foundation
@testable import ReqlingKit
import ReqlingScriptProtocol
import ReqlingTemplating
import XCTest

/// Stream scripts around event streams and WebSocket connections, through the real helper: handlers on each item as it
/// arrives, live results and values, Stop, time limits, replies, and runs that end early.
@MainActor
extension RequestRunnerTests {
    private func eventStreamServer() async throws -> (TestHTTPServer, StreamFeed) {
        let feed = StreamFeed()
        let server = try await TestHTTPServer.start { _ in .stream(headers: [("Content-Type", "text/event-stream")], feed: feed) }
        servers.append(server)
        return (server, feed)
    }

    private struct StreamProject {
        let project: ScriptedProject
        let key: RunKey
        let feed: StreamFeed
    }

    /// Login is a POST, so its stream never reconnects when the feed ends.
    private func streamProject(stream: String, postResponse: String = "", trust: ScriptTrust = .trusted) async throws -> StreamProject {
        let (server, feed) = try await eventStreamServer()
        let project = try scriptedProject(base: server.baseURL, trust: trust)
        try setScripts(project, request: project.login.id, ScriptSet(stream: stream, postResponse: postResponse))
        return StreamProject(project: project, key: RunKey(project.login.id, in: project.id), feed: feed)
    }

    /// Waits for the head, then writes a comment, which no handler sees: URLSession reports a response only once
    /// some of its body has arrived, so the stream, and its scripts, open only then.
    private func open(_ feed: StreamFeed) async throws {
        await feed.opened()
        try await feed.send(": open\n\n")
    }

    private func streamPhase(_ exchange: RequestExchange?) -> ScriptPhaseReport? {
        exchange?.scriptReport?.phase(.stream)
    }

    private func console(_ exchange: RequestExchange?) -> [String] {
        streamPhase(exchange)?.console.map(\.text) ?? []
    }

    private func currentValue(_ key: String, in project: ScriptedProject) -> CurrentVariable? {
        fixture.library.currentValues.values(in: .environment(project.id, project.defaultEnvironment))[key]
    }

    /// A handler busy forever on the first event, which only the time limit can end.
    private static let busyHandler = """
    console.log("ready")
    rq.onEvent((event) => { console.log("busy", event.data); while (true) {} })
    """

    func testStreamScriptsTestEachEventAsItArrivesAndPostResponseSeesWhatTheySet() async throws {
        let setup = try await streamProject(stream: """
            console.log("opened", rq.response.code)
            let seen = 0
            rq.onEvent((event) => {
              seen += 1
              rq.variables.set("seen", seen)
              rq.environment.set("last", event.data)
              rq.test("is JSON", () => event.json())
            })
            """, postResponse: "rq.test(\"handlers ran\", () => rq.expect(rq.variables.get(\"seen\")).to.equal(\"2\"))")
        let (project, key, feed) = (setup.project, setup.key, setup.feed)
        let runner = makeRunner()

        let run = Task { await runner.run(project.login.id, in: project.id) }
        await feed.opened()
        try await feed.send("data: {\"n\":1}\n\n")
        await waitUntil("the first event's test shows") {
            self.streamPhase(runner.latest[key])?.levels.last?.tests.first?.tally == ScriptTestCounts(passed: 1)
        }
        await waitUntil("what it set is kept") { self.currentValue("last", in: project) == .value(TemplateVariable(value: #"{"n":1}"#)) }
        XCTAssertEqual(runner.scriptPhases[key], .stream)
        try await feed.send("data: oops\n\n")
        try await feed.end()
        let exchange = await run.value

        let phase = try XCTUnwrap(streamPhase(exchange))
        let test = try XCTUnwrap(phase.levels.last?.tests.first)
        XCTAssertEqual(phase.console.map(\.text), ["opened 200"])
        XCTAssertEqual(test.tally, ScriptTestCounts(passed: 1, failed: 1))
        XCTAssertEqual(test.firstFailedItem, 2)
        XCTAssertEqual(phase.stream?.handledCount, 2)
        XCTAssertEqual(currentValue("last", in: project), .value(TemplateVariable(value: "oops")))
        XCTAssertEqual(exchange.scriptReport?.phase(.postResponse)?.levels.last?.tests.first?.result, .passed)
        XCTAssertEqual(exchange.scriptReport?.hasFailures, true)
        XCTAssertNil(runner.scriptPhases[key])
    }

    func testStoppingFinishesTheCallInHandAndCountsWhatWaited() async throws {
        let setup = try await streamProject(stream: Self.busyHandler, postResponse: "rq.test(\"ran\", () => {})")
        let (project, key, feed) = (setup.project, setup.key, setup.feed)
        let runner = makeRunner()

        let run = Task { await runner.run(project.login.id, in: project.id) }
        try await open(feed)
        await waitUntil("the handlers are registered") {
            return self.console(runner.latest[key]) == ["ready"]
        }
        try await feed.send("data: 1\n\ndata: 2\n\ndata: 3\n\n")
        await waitUntil("every event arrived") { runner.latest[key]?.response?.eventStream?.events.count == 3 }
        runner.cancel(project.login.id, in: project.id)
        await waitForDeadline(scriptDeadline)
        scriptDeadline.wake()
        let exchange = await run.value

        let phase = try XCTUnwrap(streamPhase(exchange))
        XCTAssertEqual(exchange.response?.eventStream?.end, .stopped)
        XCTAssertEqual(phase.stream?.skippedCount, 2, "Events 2 and 3 waited")
        XCTAssertEqual(phase.stream?.failedItem, 1)
        XCTAssertEqual(
            phase.error?.message,
            "Handling event 1 didn't finish within 10 s, the time limit in Settings ▸ Requests, so the stream scripts stopped."
        )
        XCTAssertEqual(exchange.scriptReport?.phase(.postResponse)?.levels.last?.tests.first?.result, .passed)
    }

    func testAReachedEventLimitEndsStreamScriptsAsStopDoes() async throws {
        let setup = try await streamProject(stream: Self.busyHandler)
        let (project, key, feed) = (setup.project, setup.key, setup.feed)
        let runner = makeRunner()

        let run = Task { await runner.run(project.login.id, in: project.id, options: RunOptions(streamLimit: StreamLimit(maxEvents: 2))) }
        try await open(feed)
        await waitUntil("the handlers are registered") { self.console(runner.latest[key]) == ["ready"] }
        try await feed.send("data: 1\n\ndata: 2\n\ndata: 3\n\n")
        await waitForDeadline(scriptDeadline)
        scriptDeadline.wake()
        let exchange = await run.value

        XCTAssertEqual(exchange.response?.eventStream?.end, .limit)
        XCTAssertEqual(streamPhase(exchange)?.stream?.skippedCount, 1, "Event 2 waited; event 3 was past the limit")
        XCTAssertEqual(streamPhase(exchange)?.stream?.failedItem, 1)
    }

    func testStreamScriptsNeverRunUntrustedAndAScriptWithoutHandlersCountsNothing() async throws {
        let scripts = ScriptFixtures.countingRunner()
        let runner = makeRunner(scripts: scripts)
        let untrusted = try await streamProject(stream: "rq.onEvent(() => {})", trust: .declined)
        let idle = try await streamProject(stream: "console.log(\"no handlers\")")

        let runs = [untrusted, idle].map { stream in Task { await runner.run(stream.project.login.id, in: stream.project.id) } }
        for stream in [untrusted, idle] {
            await stream.feed.opened()
            try await stream.feed.send("data: 1\n\n")
            try await stream.feed.end()
        }
        let declined = await runs[0].value
        let quiet = await runs[1].value

        XCTAssertEqual(scripts.streamLaunches, 1)
        XCTAssertEqual(streamPhase(declined)?.skipReason, .untrusted)
        XCTAssertEqual(console(quiet), ["no handlers"])
        XCTAssertEqual(streamPhase(quiet)?.stream, ScriptStreamReport(itemKind: .event))
    }

    func testQuittingWhileStreamScriptsRunRecordsWhatTheyNeverFinished() async throws {
        let setup = try await streamProject(stream: Self.busyHandler, postResponse: "rq.test(\"later\", () => {})")
        let (project, key, feed) = (setup.project, setup.key, setup.feed)
        let runner = makeRunner()

        let run = Task { await runner.run(project.login.id, in: project.id) }
        try await open(feed)
        await waitUntil("the handlers are registered") { self.console(runner.latest[key]) == ["ready"] }
        try await feed.send("data: 1\n\ndata: 2\n\n")
        await waitUntil("both events arrived") { runner.latest[key]?.response?.eventStream?.events.count == 2 }
        runner.recordLiveRuns()
        _ = await run.value
        runner.flushHistory()

        let recorded = try XCTUnwrap(runner.history.latest(for: project.login.id, in: project.id))
        XCTAssertEqual(streamPhase(recorded)?.stream?.isInterrupted, true)
        XCTAssertEqual(streamPhase(recorded)?.stream?.skippedCount, 1, "Event 2 waited")
        XCTAssertEqual(recorded.scriptReport?.phase(.postResponse)?.skipReason, .quit)
    }

    /// A newer run of the request kills the older one's helper, which would otherwise wait out its handler's time limit.
    func testReplacingARunKillsItsStreamScripts() async throws {
        let setup = try await streamProject(stream: Self.busyHandler)
        let (project, key, feed) = (setup.project, setup.key, setup.feed)
        let runner = makeRunner()

        let first = Task { await runner.run(project.login.id, in: project.id) }
        try await open(feed)
        await waitUntil("the handlers are registered") { self.console(runner.latest[key]) == ["ready"] }
        try await feed.send("data: 1\n\n")
        await waitUntil("the event arrived") { runner.latest[key]?.response?.eventStream?.events.count == 1 }
        let second = Task { await runner.run(project.login.id, in: project.id) }
        let replaced = await first.value
        runner.cancel(project.login.id, in: project.id)
        _ = await second.value

        XCTAssertNil(streamPhase(replaced)?.error, "Killed at once, not at the time limit")
    }

    func testAWebSocketHandlerPastTheTimeLimitStopsTheScriptsButNotTheConnection() async throws {
        let server = try await socketServer()
        let key = try makeSocketProject(url: "\(server.url)/chat")
        workspace.updateProject(key.projectID) { $0.scriptTrust = .trusted }
        try fixture.library.mutate(key.projectID) { document in
            try document.updateRequest(key.requestID) { request in
                request.scripts = ScriptSet(stream: """
                    console.log("ready")
                    rq.onMessage((message) => {
                      if (message.text === "slow") while (true) {}
                      console.log("got", message.text)
                    })
                    """, postResponse: "rq.test(\"ran\", () => {})")
            }
        }
        let runner = makeRunner(sleep: patientSleeper)
        let send = { (text: String) in try runner.sendWebSocketMessage(WebSocketMessage(text: text), to: key.requestID, in: key.projectID) }

        let run = Task { await runner.run(key.requestID, in: key.projectID) }
        await waitUntil("the handlers are registered") { self.console(runner.latest[key]) == ["ready"] }
        try send("fast")
        await waitUntil("the first message is handled") { self.console(runner.latest[key]) == ["ready", "got fast"] }
        try send("slow")
        try send("after")
        await waitUntil("both echoed") { self.texts(runner.latest[key]?.webSocket, .received).count == 3 }
        await waitForDeadline(scriptDeadline)
        scriptDeadline.wake()
        await waitUntil("the scripts stopped") { self.streamPhase(runner.latest[key])?.stream?.failedItem == 2 }
        XCTAssertTrue(runner.openSockets.contains(key), "The connection stays open")
        try send("later")
        await waitUntil("the last one is counted") { self.streamPhase(runner.latest[key])?.stream?.skippedCount == 2 }
        runner.cancel(key.requestID, in: key.projectID)
        let exchange = await run.value

        XCTAssertEqual(
            streamPhase(exchange)?.error?.message,
            "Handling message 2 didn't finish within 10 s, the time limit in Settings ▸ Requests, so the stream scripts stopped."
        )
        XCTAssertEqual(exchange.scriptReport?.phase(.postResponse)?.levels.last?.tests.first?.result, .passed)
    }

    /// `rq.send` goes out as written, masked on the timeline; what a handler sets resolves in the sends after it.
    func testAWebSocketHandlerRepliesAndWhatItSetsResolvesInLaterSends() async throws {
        let server = try await socketServer()
        let key = try makeSocketProject(url: "\(server.url)/chat")
        workspace.updateProject(key.projectID) { $0.scriptTrust = .trusted }
        try fixture.library.mutate(key.projectID) { document in
            try document.updateRequest(key.requestID) { request in
                request.scripts.stream = """
                    rq.send("hi {{token}}")
                    rq.onMessage((message) => {
                      if (!message.text.startsWith("hi")) return
                      rq.variables.set("v", "from-handler")
                      rq.environment.set("key", "k3y-value", { secret: true })
                      rq.send("reply " + rq.environment.get("key"))
                    })
                    """
            }
        }
        let runner = makeRunner(sleep: patientSleeper)
        let defaultEnvironment = try XCTUnwrap(fixture.library.document(key.projectID)).defaultEnvironment.id

        let run = Task { await runner.run(key.requestID, in: key.projectID) }
        await waitUntil("the reply is echoed") { self.texts(runner.latest[key]?.webSocket, .received).count == 2 }
        try runner.sendWebSocketMessage(WebSocketMessage(text: "{{v}}"), to: key.requestID, in: key.projectID)
        await waitUntil("the person's message is echoed") { self.texts(runner.latest[key]?.webSocket, .received).count == 3 }
        await waitUntil("what the handler set is kept") {
            self.fixture.library.currentValues.values(in: .environment(key.projectID, defaultEnvironment))["key"] != nil
        }
        let open = runner.latest[key]
        runner.cancel(key.requestID, in: key.projectID)
        _ = await run.value

        XCTAssertEqual(texts(open?.webSocket, .sent), ["hi {{token}}", "reply \(TemplateResolver.mask)", "from-handler"])
        XCTAssertEqual(
            fixture.library.currentValues.values(in: .environment(key.projectID, defaultEnvironment))["key"],
            .value(TemplateVariable(value: "k3y-value", isSecret: true))
        )
    }
}
