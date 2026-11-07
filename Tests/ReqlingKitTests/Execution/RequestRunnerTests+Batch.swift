import Foundation
@testable import ReqlingKit
import ReqlingTemplating
import Synchronization
import XCTest

/// Running a folder's requests in order through `BatchRunner`, with the real script helper.
@MainActor
extension RequestRunnerTests {
    struct BatchProject {
        let id: ProjectID
        let folder: RequestNodeID
        let requests: [String: RequestNodeID]

        subscript(name: String) -> RequestNodeID {
            requests[name] ?? RequestNodeID()
        }
    }

    /// A Flow folder holding one GET request per path, in order, against `base`, each named for the letters its path
    /// starts with.
    func batchProject(base: String, paths: [String], trust: ScriptTrust = .trusted) throws -> BatchProject {
        let id = try fixture.library.createProject(named: "Batch")
        let folder = RequestFolder(name: "Flow")
        var requests: [String: RequestNodeID] = [:]
        try fixture.library.mutate(id) { document in
            document.defaultEnvironment.variables = [Variable(key: "base", value: base)]
            try document.insert(.folder(folder), into: nil)
            for path in paths {
                let name = String(path.prefix { $0.isLetter })
                let request = RequestItem.http(name, url: "{{base}}/\(path)")
                requests[name] = request.id
                try document.insert(.request(request), into: folder.id)
            }
        }
        workspace.updateProject(id) { $0.scriptTrust = trust }
        return BatchProject(id: id, folder: folder.id, requests: requests)
    }

    func setScripts(_ scripts: ScriptSet, on request: RequestNodeID, in project: BatchProject) throws {
        try fixture.library.mutate(project.id) { try $0.updateRequest(request) { $0.scripts = scripts } }
    }

    /// Answers /login with a token, /fail with a 500, /hang never, and anything else with its URI and `X-Seen` header.
    func batchServer() async throws -> TestHTTPServer {
        let server = try await TestHTTPServer.start { request in
            if request.uri.hasPrefix("/login") {
                return .text(#"{"token": "t0k3n-value"}"#, headers: [("Content-Type", "application/json")])
            }
            if request.uri.hasPrefix("/fail") {
                return .text("nope", status: .internalServerError)
            }
            if request.uri.hasPrefix("/hang") {
                return .hang
            }
            return .text("\(request.uri) \(request.header("X-Seen") ?? "-")")
        }
        servers.append(server)
        return server
    }

    func plan(_ project: BatchProject, _ configure: (inout BatchRunPlan) -> Void = { _ in }) throws -> BatchRunPlan {
        let document = try XCTUnwrap(fixture.library.document(project.id))
        let requests = document.requests(inFolder: project.folder).map(\.id)
        var plan = BatchRunPlan(scope: BatchRunScope(projectID: project.id, folderID: project.folder), requests: requests)
        configure(&plan)
        return plan
    }

    func testAFolderRunsInSidebarOrderAndChainsThroughCurrentValues() async throws {
        let server = try await batchServer()
        let project = try batchProject(base: server.baseURL, paths: ["login", "me"])
        try setScripts(ScriptSet(postResponse: "rq.environment.set('token', rq.response.json().token)"), on: project["login"], in: project)
        try setScripts(ScriptSet(preRequest: "rq.request.headers.upsert('X-Seen', rq.environment.get('token'))"), on: project["me"], in: project)
        let runner = makeRunner()
        let batches = BatchRunner(runner: runner)

        let run = try await batches.begin(try plan(project), mayPromptForTrust: false).finished()

        XCTAssertEqual(run.state, .ended(.finished))
        XCTAssertEqual(run.counts, BatchStepCounts(passed: 2))
        XCTAssertEqual(server.requests.map(\.uri), ["/login", "/me"])
        XCTAssertEqual(server.requests.last?.header("X-Seen"), "t0k3n-value")
        XCTAssertEqual(batches.status(for: project["me"])?.phase, .passed)
        XCTAssertEqual(batches.status(for: project.folder)?.phase, .passed, "A folder rolls up its requests")
        XCTAssertFalse(batches.isRunning)
        runner.flushHistory()
        XCTAssertEqual(runner.history.runs(for: project["me"], in: project.id).count, 1, "Each step is recorded as a Send is")
    }

    func testRunLocalValuesCarryWithinAnIterationAndResetForTheNext() async throws {
        let server = try await batchServer()
        let project = try batchProject(base: server.baseURL, paths: ["first", "second"])
        try setScripts(ScriptSet(postResponse: """
        rq.variables.set("seen", "first-" + rq.info.iteration + (rq.variables.has("leaked") ? "-leaked" : ""))
        """), on: project["first"], in: project)
        try setScripts(ScriptSet(preRequest: """
        rq.variables.set("leaked", "1")
        rq.request.headers.upsert("X-Seen", rq.variables.get("seen") + "/" + rq.info.iterationCount)
        """), on: project["second"], in: project)
        let batches = BatchRunner(runner: makeRunner())

        _ = try await batches.begin(try plan(project) { $0.iterations = .count(2) }, mayPromptForTrust: false).finished()

        let seen = server.requests.filter { $0.uri == "/second" }.map { $0.header("X-Seen") }
        XCTAssertEqual(seen, ["first-0/2", "first-1/2"])
    }

    func testEachIterationReadsItsDataRowInScriptsAndTemplates() async throws {
        let server = try await batchServer()
        let project = try batchProject(base: server.baseURL, paths: ["users/{{id}}"])
        let script = ScriptSet(preRequest: "rq.request.headers.upsert('X-Seen', rq.iterationData.get('name'))")
        try setScripts(script, on: project["users"], in: project)
        let rows = [["id": "1", "name": "Ada"], ["id": "2", "name": "Grace"]]
        let batches = BatchRunner(runner: makeRunner())

        let request = try plan(project) { $0.iterations = .data(source: .inline, rows: rows) }
        let run = try await batches.begin(request, mayPromptForTrust: false).finished()

        XCTAssertEqual(server.requests.map(\.uri), ["/users/1", "/users/2"])
        XCTAssertEqual(server.requests.map { $0.header("X-Seen") }, ["Ada", "Grace"])
        XCTAssertEqual(batches.status(for: project["users"])?.iterationsPassed, 2)
        XCTAssertEqual(run.iteration, 1)
    }

    func testAFailureStopsTheRunOnlyWhenAskedTo() async throws {
        let server = try await batchServer()
        let project = try batchProject(base: server.baseURL, paths: ["fail", "me"])
        let batches = BatchRunner(runner: makeRunner())

        let stopped = try await batches.begin(try plan(project) { $0.stopsOnFailure = true }, mayPromptForTrust: false).finished()
        let pending = batches.status(for: project["me"])?.phase
        let continued = try await batches.begin(try plan(project), mayPromptForTrust: false).finished()

        XCTAssertEqual(stopped.state, .ended(.stoppedOnFailure))
        XCTAssertEqual(stopped.counts, BatchStepCounts(failed: 1))
        XCTAssertEqual(pending, .pending, "The request the run never reached")
        XCTAssertEqual(continued.state, .ended(.finished))
        XCTAssertEqual(continued.counts, BatchStepCounts(passed: 1, failed: 1))
        XCTAssertEqual(continued.notableSteps.map(\.requestName), ["fail"])
        XCTAssertEqual(batches.failedRequests, [project["fail"]])
        XCTAssertEqual(batches.status(for: project.folder)?.phase, .failed)
    }

    func testSetNextRequestJumpsAndLoopsWithinEachIteration() async throws {
        let server = try await batchServer()
        let project = try batchProject(base: server.baseURL, paths: ["a", "b", "c"])
        try setScripts(ScriptSet(postResponse: """
        if (!rq.variables.has("looped")) {
          rq.variables.set("looped", "1")
          rq.execution.setNextRequest("a")
        } else {
          rq.execution.setNextRequest("\(project["c"].description)")
        }
        """), on: project["a"], in: project)
        let batches = BatchRunner(runner: makeRunner())

        let run = try await batches.begin(try plan(project) { $0.iterations = .count(2) }, mayPromptForTrust: false).finished()

        XCTAssertEqual(server.requests.map(\.uri), ["/a", "/a", "/c", "/a", "/a", "/c"], "By name, then by ID; b is jumped over")
        XCTAssertEqual(batches.status(for: project["b"])?.phase, .pending, "b never ran")
        XCTAssertEqual(run.counts.passed, 6)
    }

    func testANullOrUnknownNextRequestEndsOnlyItsIteration() async throws {
        let server = try await batchServer()
        let project = try batchProject(base: server.baseURL, paths: ["a", "b"])
        try setScripts(ScriptSet(preRequest: """
        rq.execution.setNextRequest(rq.info.iteration === 0 ? null : "Nope")
        """), on: project["a"], in: project)
        let batches = BatchRunner(runner: makeRunner())

        let run = try await batches.begin(try plan(project) { $0.iterations = .count(2) }, mayPromptForTrust: false).finished()

        XCTAssertEqual(server.requests.map(\.uri), ["/a", "/a"])
        XCTAssertEqual(run.state, .ended(.finished))
        XCTAssertEqual(run.notes, ["No request “Nope” is in this run, so the iteration that named it ended there."])
    }

    func testASkippedStepCountsAsSkipped() async throws {
        let server = try await batchServer()
        let project = try batchProject(base: server.baseURL, paths: ["a", "b"])
        try setScripts(ScriptSet(preRequest: "rq.execution.skipRequest()"), on: project["a"], in: project)
        let batches = BatchRunner(runner: makeRunner())

        let run = try await batches.begin(try plan(project), mayPromptForTrust: false).finished()

        XCTAssertEqual(run.counts, BatchStepCounts(passed: 1, skipped: 1))
        XCTAssertEqual(server.requests.map(\.uri), ["/b"])
        XCTAssertEqual(batches.status(for: project["a"])?.phase, .skipped)
    }

    func testAnEventStreamStepEndsAtTheRunsStreamLimit() async throws {
        let feed = StreamFeed()
        let server = try await TestHTTPServer.start { request in
            request.uri.hasPrefix("/events") ? .stream(headers: [("Content-Type", "text/event-stream")], feed: feed) : .text("ok")
        }
        servers.append(server)
        let project = try batchProject(base: server.baseURL, paths: ["events", "after"])
        let batches = BatchRunner(runner: makeRunner())

        let handle = try await batches.begin(try plan(project), mayPromptForTrust: false)
        await feed.opened()
        try await feed.send("data: 1\n\n")
        let run = await handle.finished()

        XCTAssertEqual(run.counts, BatchStepCounts(passed: 2), "The limit, which this runner's sleep reaches at once, ends the stream")
        XCTAssertEqual(server.requests.map(\.uri), ["/events", "/after"])
    }

    func testTrustIsAskedOnceForEveryScriptInTheRun() async throws {
        let server = try await batchServer()
        let project = try batchProject(base: server.baseURL, paths: ["login", "me"], trust: .unknown)
        try setScripts(ScriptSet(postResponse: "rq.environment.set('token', 'x')"), on: project["login"], in: project)
        try setScripts(ScriptSet(preRequest: "rq.request.headers.upsert('X-Seen', 'scripted')"), on: project["me"], in: project)
        let runner = makeRunner()
        let decider = CountingTrustDecider(answer: true)
        runner.trustDecider = decider
        let batches = BatchRunner(runner: runner)

        let run = try await batches.begin(try plan(project), mayPromptForTrust: true).finished()

        XCTAssertEqual(decider.questions, 1)
        XCTAssertEqual(decider.lastFiles, ["Flow/login.post.js", "Flow/me.pre.js"])
        XCTAssertEqual(workspace.projectState(project.id).scriptTrust, .trusted)
        XCTAssertEqual(server.requests.last?.header("X-Seen"), "scripted")
        XCTAssertEqual(run.notes, [])
    }

    func testADismissedTrustQuestionStartsNothingButAnAgentsRunGoesWithoutScripts() async throws {
        let server = try await batchServer()
        let project = try batchProject(base: server.baseURL, paths: ["me"], trust: .unknown)
        try setScripts(ScriptSet(preRequest: "rq.request.headers.upsert('X-Seen', 'scripted')"), on: project["me"], in: project)
        let runner = makeRunner()
        let decider = CountingTrustDecider(answer: nil)
        runner.trustDecider = decider
        let batches = BatchRunner(runner: runner)

        let request = try plan(project)
        var refusal: BatchRunRefusal?
        do {
            _ = try await batches.begin(request, mayPromptForTrust: true)
        } catch {
            refusal = error
        }
        let agents = try await batches.begin(try plan(project), mayPromptForTrust: false).finished()

        XCTAssertEqual(refusal, .trustDismissed)
        XCTAssertEqual(decider.questions, 1)
        XCTAssertEqual(server.requests.count, 1, "Only the agent's run went out")
        XCTAssertNil(server.requests.first?.header("X-Seen"), "Without its scripts")
        XCTAssertEqual(agents.notes, [BatchRun.untrustedNote])
        XCTAssertEqual(workspace.projectState(project.id).scriptTrust, .unknown)
    }

    func testRevokingTrustMidRunTakesEffectAtTheNextStep() async throws {
        let server = try await batchServer()
        let project = try batchProject(base: server.baseURL, paths: ["hang", "me"])
        try setScripts(ScriptSet(preRequest: "rq.request.headers.upsert('X-Seen', 'scripted')"), on: project["me"], in: project)
        let runner = makeRunner()
        let batches = BatchRunner(runner: runner)

        let handle = try await batches.begin(try plan(project), mayPromptForTrust: false)
        await waitUntil("the step is in flight") { runner.isInFlight(project["hang"], in: project.id) }
        workspace.updateProject(project.id) { $0.scriptTrust = .declined }
        runner.cancel(project["hang"], in: project.id)
        _ = await handle.finished()

        XCTAssertEqual(server.requests.last?.uri, "/me")
        XCTAssertNil(server.requests.last?.header("X-Seen"))
    }

    func testAStopOnTheLastStepStillEndsTheRunAsStopped() async throws {
        let server = try await batchServer()
        let project = try batchProject(base: server.baseURL, paths: ["hang"])
        let runner = makeRunner()
        let batches = BatchRunner(runner: runner)

        let handle = try await batches.begin(try plan(project), mayPromptForTrust: false)
        await waitUntil("the step is in flight") { runner.isInFlight(project["hang"], in: project.id) }
        batches.stop()
        let run = await handle.finished()

        XCTAssertEqual(run.state, .ended(.stopped))
    }

    func testStopEndsTheRunAndInterruptsTheStepInFlight() async throws {
        let server = try await batchServer()
        let project = try batchProject(base: server.baseURL, paths: ["hang", "me"])
        let runner = makeRunner()
        let batches = BatchRunner(runner: runner)

        let handle = try await batches.begin(try plan(project), mayPromptForTrust: false)
        await waitUntil("the step is in flight") { runner.isInFlight(project["hang"], in: project.id) }
        let again = try plan(project)
        var second: BatchRunRefusal?
        do {
            _ = try await batches.begin(again, mayPromptForTrust: false)
        } catch {
            second = error
        }
        batches.stop()
        let run = await handle.finished()

        XCTAssertEqual(second, .alreadyRunning)
        XCTAssertEqual(run.state, .ended(.stopped))
        XCTAssertEqual(run.counts, BatchStepCounts(interrupted: 1))
        XCTAssertEqual(run.notableSteps.first?.message, "Stopped.")
        XCTAssertFalse(server.requests.contains { $0.uri == "/me" })
        XCTAssertEqual(batches.status(for: project["hang"])?.phase, .interrupted)
    }

    func testAStopInTheEditorInterruptsOnlyItsStep() async throws {
        let server = try await batchServer()
        let project = try batchProject(base: server.baseURL, paths: ["hang", "me"])
        let runner = makeRunner()
        let batches = BatchRunner(runner: runner)

        let handle = try await batches.begin(try plan(project) { $0.stopsOnFailure = true }, mayPromptForTrust: false)
        await waitUntil("the step is in flight") { runner.isInFlight(project["hang"], in: project.id) }
        runner.cancel(project["hang"], in: project.id)
        let run = await handle.finished()

        XCTAssertEqual(run.state, .ended(.finished), "No failure, so nothing stops the run")
        XCTAssertEqual(run.counts, BatchStepCounts(passed: 1, interrupted: 1))
        runner.flushHistory()
        XCTAssertEqual(runner.history.runs(for: project["hang"], in: project.id).count, 1, "The stopped run is still recorded")
    }

    func testASendOfTheRequestInFlightReplacesItsStepAndOneAlreadyRunningIsLeftAlone() async throws {
        let slowCalls = Mutex(0)
        let firstSlow = StreamFeed()
        let busyFeed = StreamFeed()
        let server = try await TestHTTPServer.start { request in
            if request.uri.hasPrefix("/busy") {
                return .stream(headers: [("Content-Type", "text/plain")], feed: busyFeed)
            }
            guard request.uri.hasPrefix("/slow") else {
                return .text("ok")
            }
            // The first call never finishes; any after it answers.
            return slowCalls.withLock { count in
                count += 1
                return count == 1 ? .stream(headers: [("Content-Type", "text/plain")], feed: firstSlow) : .text("sent")
            }
        }
        servers.append(server)
        let project = try batchProject(base: server.baseURL, paths: ["slow", "busy", "me"])
        let runner = makeRunner()
        let batches = BatchRunner(runner: runner)
        let busy = Task { await runner.run(project["busy"], in: project.id) }
        await busyFeed.opened()

        let handle = try await batches.begin(try plan(project), mayPromptForTrust: false)
        await firstSlow.opened()
        let sent = await runner.run(project["slow"], in: project.id)
        let run = await handle.finished()
        runner.cancel(project["busy"], in: project.id)
        _ = await busy.value

        XCTAssertEqual(body(sent), "sent")
        XCTAssertEqual(run.counts, BatchStepCounts(passed: 1, interrupted: 2))
        XCTAssertEqual(run.notableSteps.map(\.message), [
            "Another run of this request replaced it.",
            "It was already running, so the run left it alone."
        ])
    }

    func testARequestOrEnvironmentDeletedMidRunIsHandled() async throws {
        let server = try await batchServer()
        let project = try batchProject(base: server.baseURL, paths: ["hang", "gone", "me"])
        let staging = RequestEnvironment(name: "Staging")
        try fixture.library.mutate(project.id) { $0.environments.append(staging) }
        let runner = makeRunner()
        let batches = BatchRunner(runner: runner)

        var handle = try await batches.begin(try plan(project), mayPromptForTrust: false)
        await waitUntil("the step is in flight") { runner.isInFlight(project["hang"], in: project.id) }
        try fixture.library.mutate(project.id) { _ = try $0.removeNode(project["gone"]) }
        runner.cancel(project["hang"], in: project.id)
        let deleted = await handle.finished()
        handle = try await batches.begin(try plan(project) { $0.environmentID = staging.id }, mayPromptForTrust: false)
        await waitUntil("the step is in flight") { runner.isInFlight(project["hang"], in: project.id) }
        try fixture.library.mutate(project.id) { $0.environments.removeAll { $0.id == staging.id } }
        runner.cancel(project["hang"], in: project.id)
        let unpinned = await handle.finished()

        XCTAssertEqual(deleted.counts, BatchStepCounts(passed: 1, interrupted: 2))
        XCTAssertEqual(deleted.notableSteps.last?.message, "The request no longer exists.")
        runner.flushHistory()
        XCTAssertTrue(runner.history.runs(for: project["gone"], in: project.id).isEmpty, "A deleted request leaves no run behind")
        XCTAssertEqual(unpinned.state, .ended(.environmentRemoved))
    }

    func testTheTimeLimitStopsTheStepInFlight() async throws {
        let server = try await batchServer()
        let project = try batchProject(base: server.baseURL, paths: ["hang", "me"])
        let runner = makeRunner()
        let clock = TestSleeper(returnsAtOnce: false)
        let batches = BatchRunner(runner: runner, sleep: clock.sleep)

        let handle = try await batches.begin(try plan(project) { $0.timeLimit = .seconds(570) }, mayPromptForTrust: false)
        await waitUntil("the step is in flight") { runner.isInFlight(project["hang"], in: project.id) }
        var sleeps = clock.requests.makeAsyncIterator()
        _ = await sleeps.next()
        clock.wake()
        let run = await handle.finished()

        XCTAssertEqual(run.state, .ended(.timeLimit))
        XCTAssertEqual(run.counts, BatchStepCounts(interrupted: 1))
        XCTAssertEqual(clock.durations, [.seconds(570)])
    }

    func testASecretAnEarlierStepMadeIsMaskedAndWithheldOnceForgotten() async throws {
        let server = try await batchServer()
        let project = try batchProject(base: server.baseURL, paths: ["login", "echo?sig={{sig}}"])
        let echoID = project["echo"]
        try setScripts(ScriptSet(postResponse: "rq.variables.set('sig', 's3cret-sig', { secret: true })"), on: project["login"], in: project)
        let runner = makeRunner()
        let batches = BatchRunner(runner: runner)

        _ = try await batches.begin(try plan(project), mayPromptForTrust: false).finished()
        let echo = try XCTUnwrap(runner.latest[RunKey(echoID, in: project.id)])
        runner.flushHistory()
        let relaunched = makeRunner()
        let stored = try XCTUnwrap(relaunched.exchange(for: echoID, in: project.id))
        let description = MCPExecutionTools.describeRecorded(stored, mask: { $0 }, runner: relaunched)

        XCTAssertEqual(server.requests.last?.uri, "/echo?sig=s3cret-sig", "The next step resolves it")
        XCTAssertFalse(echo.request?.url.contains("s3cret-sig") ?? true, "Shown masked")
        XCTAssertEqual(echo.heldRunLocalSecrets, true)
        XCTAssertTrue(runner.scriptSecrets.secrets(of: echo.id)?.contains("s3cret-sig") ?? false)
        XCTAssertNotNil(description["withheld"], "Once Reqling no longer holds it, the response is left out")
        XCTAssertFalse(MCPJSON.text(.object(description)).contains("s3cret-sig"))
    }
}
