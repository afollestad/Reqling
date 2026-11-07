import Foundation
@testable import ReqlingKit
import ReqlingScriptProtocol
import ReqlingTemplating
import Synchronization
import XCTest

/// Pre-request and post-response scripts around HTTP runs, through the real helper.
@MainActor
extension RequestRunnerTests {
    private struct ScriptedProject {
        let id: ProjectID
        let folder: RequestFolder
        let login: RequestItem
        let profile: RequestItem
        let defaultEnvironment: EnvironmentID
    }

    /// A Users folder holding Login (POST /login) and Me (GET /me), against `base`.
    private func scriptedProject(base: String, trust: ScriptTrust = .trusted) throws -> ScriptedProject {
        let id = try fixture.library.createProject(named: "Scripted")
        let folder = RequestFolder(name: "Users")
        let login = RequestItem(name: "Login", kind: .http(HTTPRequestSpec(method: .post, url: "{{base}}/login")))
        let profile = RequestItem(name: "Me", kind: .http(HTTPRequestSpec(url: "{{base}}/me")))
        try fixture.library.mutate(id) { document in
            document.defaultEnvironment.variables = [Variable(key: "base", value: base)]
            try document.insert(.folder(folder), into: nil)
            try document.insert(.request(login), into: folder.id)
            try document.insert(.request(profile), into: folder.id)
        }
        workspace.updateProject(id) { $0.scriptTrust = trust }
        let defaultEnvironment = try XCTUnwrap(fixture.library.document(id)).defaultEnvironment.id
        return ScriptedProject(id: id, folder: folder, login: login, profile: profile, defaultEnvironment: defaultEnvironment)
    }

    private func setScripts(_ project: ScriptedProject, request: RequestNodeID, _ scripts: ScriptSet) throws {
        try fixture.library.mutate(project.id) { try $0.updateRequest(request) { $0.scripts = scripts } }
    }

    /// Answers /login with a token and echoes /me's Authorization header.
    private func authServer() async throws -> TestHTTPServer {
        let server = try await TestHTTPServer.start { request in
            if request.uri.hasPrefix("/login") {
                return .text(#"{"token": "t0k3n-value"}"#, headers: [("Content-Type", "application/json")])
            }
            return .text(request.header("Authorization") ?? "-")
        }
        servers.append(server)
        return server
    }

    func testAPostResponseScriptFeedsTheNextRequestThroughACurrentValue() async throws {
        let server = try await authServer()
        let project = try scriptedProject(base: server.baseURL)
        try setScripts(project, request: project.login.id, ScriptSet(postResponse: """
        rq.test("logged in", () => rq.expect(rq.response.code).to.equal(200))
        rq.environment.set("token", rq.response.json().token, { secret: true })
        console.log("token is", rq.environment.get("token"))
        """))
        try setScripts(project, request: project.profile.id, ScriptSet(preRequest: """
        rq.request.headers.upsert("Authorization", "Bearer " + rq.environment.get("token"))
        """))
        let runner = makeRunner()

        let login = await runner.run(project.login.id, in: project.id)
        let profile = await runner.run(project.profile.id, in: project.id)

        XCTAssertEqual(login.scriptReport?.testCounts, ScriptTestCounts(passed: 1))
        XCTAssertEqual(login.scriptReport?.phase(.postResponse)?.console.first?.text, "token is \(TemplateResolver.mask)")
        XCTAssertEqual(
            fixture.library.currentValues.values(in: .environment(project.id, project.defaultEnvironment))["token"],
            .value(TemplateVariable(value: "t0k3n-value", isSecret: true))
        )
        XCTAssertEqual(body(profile), "Bearer t0k3n-value")
        XCTAssertEqual(profile.request?.headers.first { $0.key == "Authorization" }?.value, "Bearer \(TemplateResolver.mask)")
        XCTAssertEqual(profile.request?.scriptChangedHeaders, ["authorization"])
        runner.flushHistory()
        XCTAssertEqual(runner.history.runs(for: project.login.id, in: project.id).first?.tests, ScriptTestCounts(passed: 1))
    }

    func testFolderAndProjectScriptsRunAroundTheRequestsOwnInOrder() async throws {
        let server = try await authServer()
        let project = try scriptedProject(base: server.baseURL)
        try fixture.library.mutate(project.id) { document in
            document.scripts.preRequest = "rq.variables.set('order', 'project')"
            try document.updateFolder(project.folder.id) { folder in
                folder.scripts.preRequest = "rq.variables.set('order', rq.variables.get('order') + ' folder')"
            }
            try document.updateRequest(project.profile.id) { request in
                request.scripts.preRequest = "rq.request.headers.upsert('Authorization', rq.variables.get('order') + ' request')"
            }
        }

        let ordered = await makeRunner().run(project.profile.id, in: project.id)
        try fixture.library.mutate(project.id) { try $0.updateRequest(project.profile.id) { $0.runsInheritedScripts = false } }
        let alone = await makeRunner().run(project.profile.id, in: project.id)

        XCTAssertEqual(body(ordered), "project folder request")
        XCTAssertEqual(body(alone), "undefined request")
    }

    func testAPreRequestFailureStopsTheRunBeforeAnythingIsSent() async throws {
        let server = try await authServer()
        let project = try scriptedProject(base: server.baseURL)
        try fixture.library.mutate(project.id) { document in
            try document.updateFolder(project.folder.id) { $0.scripts.preRequest = "rq.environment.set('kept', '1')\nthrow new Error('no token')" }
            try document.updateRequest(project.profile.id) { $0.scripts.postResponse = "rq.test('never', () => {})" }
        }

        let exchange = await makeRunner().run(project.profile.id, in: project.id)

        XCTAssertEqual(exchange.failure?.kind, .script)
        XCTAssertEqual(exchange.failure?.message, "The pre-request script of folder “Users” failed at line 2: Error: no token")
        XCTAssertTrue(server.requests.isEmpty)
        XCTAssertEqual(exchange.scriptReport?.phases.map(\.phase), [.preRequest], "No post-response phase for a request never sent")
        XCTAssertNotNil(fixture.library.currentValues.values(in: .environment(project.id, project.defaultEnvironment))["kept"])
        XCTAssertEqual(exchange.outcomeKind, .failed)
    }

    func testASkippedRequestIsNotSentThoughEveryPreRequestScriptRuns() async throws {
        let server = try await authServer()
        let project = try scriptedProject(base: server.baseURL)
        try fixture.library.mutate(project.id) { document in
            try document.updateFolder(project.folder.id) { $0.scripts.preRequest = "rq.execution.skipRequest()" }
            try document.updateRequest(project.profile.id) { request in
                request.scripts = ScriptSet(preRequest: "console.log('still runs')", postResponse: "rq.test('never', () => {})")
            }
        }
        let runner = makeRunner()

        let skipped = await runner.run(project.profile.id, in: project.id)
        let prepared = try await runner.prepare(project.profile.id, in: project.id)

        XCTAssertEqual(skipped.failure?.kind, .skipped)
        XCTAssertEqual(skipped.outcomeKind, .notSent)
        XCTAssertTrue(server.requests.isEmpty)
        XCTAssertEqual(skipped.scriptReport?.phase(.preRequest)?.console.map(\.text), ["still runs"])
        XCTAssertEqual(skipped.scriptReport?.phase(.postResponse)?.skipReason, .requestSkipped)
        XCTAssertEqual(prepared.urlRequest.url?.path, "/me", "A preview builds what a send would, skip or not")
    }

    func testAFailureOutweighsASkip() async throws {
        let server = try await authServer()
        let project = try scriptedProject(base: server.baseURL)
        try setScripts(project, request: project.login.id, ScriptSet(preRequest: """
        rq.execution.skipRequest()
        rq.test("fails", () => { throw new Error("x") })
        """))
        try setScripts(project, request: project.profile.id, ScriptSet(preRequest: "rq.execution.skipRequest()\nthrow new Error('boom')"))
        let runner = makeRunner()

        let failedTest = await runner.run(project.login.id, in: project.id)
        let thrown = await runner.run(project.profile.id, in: project.id)

        XCTAssertEqual(failedTest.failure?.kind, .skipped)
        XCTAssertEqual(failedTest.outcomeKind, .failed, "A failed test fails the run, skipped or not")
        XCTAssertEqual(thrown.failure?.kind, .script, "A throw beats the skip")
        XCTAssertTrue(server.requests.isEmpty)
    }

    func testAPreRequestScriptPastItsTimeLimitStopsTheRun() async throws {
        let server = try await authServer()
        let project = try scriptedProject(base: server.baseURL)
        try setScripts(project, request: project.profile.id, ScriptSet(preRequest: "while (true) {}"))
        let runner = makeRunner()

        let run = Task { await runner.run(project.profile.id, in: project.id) }
        for await _ in scriptDeadline.requests {
            scriptDeadline.wake()
            break
        }
        let exchange = await run.value

        XCTAssertEqual(exchange.failure?.kind, .script)
        XCTAssertTrue(exchange.failure?.message.contains("didn't finish within 10 s") ?? false, exchange.failure?.message ?? "")
        XCTAssertTrue(server.requests.isEmpty)
    }

    func testAPostResponseErrorFailsTheRunButKeepsTheResponse() async throws {
        let server = try await authServer()
        let project = try scriptedProject(base: server.baseURL)
        try setScripts(project, request: project.profile.id, ScriptSet(postResponse: "rq.test('fine', () => {})\nrq.response.json()"))

        let exchange = await makeRunner().run(project.profile.id, in: project.id)

        XCTAssertEqual(body(exchange), "-")
        XCTAssertEqual(exchange.outcomeKind, .failed)
        XCTAssertEqual(exchange.scriptReport?.phase(.postResponse)?.levels.first?.error?.name, "SyntaxError")
        XCTAssertEqual(runner(exchange: exchange), .failed)
    }

    func testAFailedRequestSkipsPostResponseScriptsAndSaysWhy() async throws {
        let project = try scriptedProject(base: "http://127.0.0.1:1")
        try setScripts(project, request: project.profile.id, ScriptSet(postResponse: "rq.test('never', () => {})"))

        let exchange = await makeRunner().run(project.profile.id, in: project.id)

        XCTAssertEqual(exchange.failure?.kind, .transport)
        XCTAssertEqual(exchange.scriptReport?.phase(.postResponse)?.skipReason, .requestFailed)
        XCTAssertFalse(exchange.scriptReport?.hasFailures ?? true)
    }

    func testAnUntrustedProjectRunsWithoutItsScripts() async throws {
        let server = try await authServer()
        let project = try scriptedProject(base: server.baseURL, trust: .unknown)
        try setScripts(project, request: project.profile.id, ScriptSet(preRequest: "rq.request.headers.upsert('Authorization', 'x')"))
        let decider = CountingTrustDecider(answer: true)
        let runner = makeRunner()
        runner.trustDecider = decider

        let unprompted = await runner.run(project.profile.id, in: project.id)
        workspace.updateProject(project.id) { $0.scriptTrust = .declined }
        let declined = await runner.run(project.profile.id, in: project.id, options: RunOptions(mayPromptForTrust: true))

        XCTAssertEqual(body(unprompted), "-")
        XCTAssertEqual(unprompted.scriptReport?.phase(.preRequest)?.skipReason, .untrusted)
        XCTAssertEqual(unprompted.outcomeKind, .succeeded)
        XCTAssertEqual(body(declined), "-")
        XCTAssertEqual(decider.questions, 0, "Neither an unprompted run nor a declined project asks")
    }

    func testConcurrentRunsShareOneTrustQuestionAndRememberTheAnswer() async throws {
        let server = try await authServer()
        let project = try scriptedProject(base: server.baseURL, trust: .unknown)
        try setScripts(project, request: project.profile.id, ScriptSet(preRequest: "rq.request.headers.upsert('Authorization', 'trusted')"))
        try setScripts(project, request: project.login.id, ScriptSet(preRequest: "rq.variables.set('x', '1')"))
        let decider = CountingTrustDecider(answer: true)
        let runner = makeRunner()
        runner.trustDecider = decider
        let options = RunOptions(mayPromptForTrust: true)

        async let first = runner.run(project.profile.id, in: project.id, options: options)
        async let second = runner.run(project.login.id, in: project.id, options: options)
        let (profile, _) = await (first, second)
        let again = await runner.run(project.profile.id, in: project.id, options: options)

        XCTAssertEqual(decider.questions, 1)
        XCTAssertEqual(decider.lastFiles, ["Users/Me.pre.js"])
        XCTAssertEqual(workspace.projectState(project.id).scriptTrust, .trusted)
        XCTAssertEqual(body(profile), "trusted")
        XCTAssertEqual(body(again), "trusted")
    }

    func testStoppingAStreamStillRunsPostResponseScriptsOnWhatArrived() async throws {
        let feed = StreamFeed()
        let server = try await TestHTTPServer.start { _ in .stream(headers: [("Content-Type", "text/event-stream")], feed: feed) }
        servers.append(server)
        let project = try scriptedProject(base: server.baseURL)
        try setScripts(project, request: project.profile.id, ScriptSet(postResponse: """
        rq.test("got one", () => rq.expect(rq.response.events.map((event) => event.json().n)).to.eql([1]))
        rq.test("stopped", () => rq.expect(rq.response.end).to.equal("stopped"))
        """))
        let runner = makeRunner()
        let key = RunKey(project.profile.id, in: project.id)

        let run = Task { await runner.run(project.profile.id, in: project.id) }
        await feed.opened()
        try await feed.send("data: {\"n\":1}\n\n")
        await waitUntil("the event shows") { runner.latest[key]?.response?.eventStream?.events.count == 1 }
        runner.cancel(project.profile.id, in: project.id)
        let exchange = await run.value

        XCTAssertEqual(exchange.scriptReport?.testCounts, ScriptTestCounts(passed: 2))
        XCTAssertNil(runner.scriptPhases[key])
    }

    /// An agent reading a stream still open can have what its pre-request scripts made secret masked.
    func testAStreamsScriptSecretsAreHeldWhileItIsOpen() async throws {
        let feed = StreamFeed()
        let server = try await TestHTTPServer.start { _ in .stream(headers: [("Content-Type", "text/event-stream")], feed: feed) }
        servers.append(server)
        let project = try scriptedProject(base: server.baseURL)
        try setScripts(project, request: project.profile.id, ScriptSet(preRequest: "rq.variables.set('sig', 's1gn-4ture', { secret: true })"))
        let runner = makeRunner()
        let key = RunKey(project.profile.id, in: project.id)

        let run = Task { await runner.run(project.profile.id, in: project.id) }
        await feed.opened()
        try await feed.send("data: 1\n\n")
        await waitUntil("the event shows") { runner.latest[key]?.response?.eventStream?.events.count == 1 }
        let open = try XCTUnwrap(runner.latest[key])

        XCTAssertEqual(runner.scriptSecrets.secrets(of: open.id), ["s1gn-4ture"])
        runner.cancel(project.profile.id, in: project.id)
        _ = await run.value
    }

    func testARunOpenAtQuitIsRecordedWithItsPostResponseScriptsNoted() async throws {
        let feed = StreamFeed()
        let server = try await TestHTTPServer.start { _ in .stream(headers: [("Content-Type", "text/event-stream")], feed: feed) }
        servers.append(server)
        let project = try scriptedProject(base: server.baseURL)
        try setScripts(project, request: project.profile.id, ScriptSet(postResponse: "rq.test('later', () => {})"))
        let runner = makeRunner()
        let key = RunKey(project.profile.id, in: project.id)

        let run = Task { await runner.run(project.profile.id, in: project.id) }
        await feed.opened()
        try await feed.send("data: 1\n\n")
        await waitUntil("the stream opens") { runner.eventStreams.contains(key) }
        runner.recordLiveRuns()
        _ = await run.value
        runner.flushHistory()

        let recorded = try XCTUnwrap(runner.history.latest(for: project.profile.id, in: project.id))
        XCTAssertEqual(recorded.scriptReport?.phase(.postResponse)?.skipReason, .quit)
    }

    func testScriptsRunAroundAWebSocketConnection() async throws {
        let server = try await socketServer()
        let key = try makeSocketProject(url: "\(server.url)/chat") { spec in
            spec.queryParameters = [KeyValuePair(key: "room", value: "{{room}}")]
            spec.messages = [WebSocketMessage(text: "hello")]
        }
        workspace.updateProject(key.projectID) { $0.scriptTrust = .trusted }
        try fixture.library.mutate(key.projectID) { document in
            try document.updateRequest(key.requestID) { request in
                request.scripts = ScriptSet(
                    preRequest: """
                    rq.request.headers.upsert("Authorization", "Bearer " + rq.environment.get("token"))
                    rq.request.query.upsert("room", "vip")
                    console.log("connecting")
                    """,
                    postResponse: """
                    const received = rq.response.messages.filter((message) => message.direction === "received")
                    rq.test("echoed", () => rq.expect(received.map((message) => message.text)).to.eql(["hello"]))
                    rq.test("stopped", () => rq.expect(rq.response.end).to.equal("stopped"))
                    """
                )
            }
        }
        let runner = makeRunner(sleep: patientSleeper)

        let run = Task { await runner.run(key.requestID, in: key.projectID) }
        await waitUntil("the echo arrives") { self.texts(runner.latest[key]?.webSocket, .received).count == 1 }
        let open = try XCTUnwrap(runner.latest[key])
        runner.cancel(key.requestID, in: key.projectID)
        let exchange = await run.value

        XCTAssertEqual(open.scriptReport?.phase(.preRequest)?.console.first?.text, "connecting", "An open connection shows its pre-request report")
        XCTAssertEqual(server.handshakes.first?.uri, "/chat?room=vip")
        XCTAssertEqual(server.handshakes.first?.header("Authorization"), "Bearer s3cr3t-token")
        XCTAssertEqual(exchange.request?.headers.first { $0.key == "Authorization" }?.value, "Bearer \(TemplateResolver.mask)")
        XCTAssertEqual(exchange.request?.scriptChangedQuery, ["room"])
        XCTAssertEqual(exchange.scriptReport?.testCounts, ScriptTestCounts(passed: 2))
    }

    func testAPreviewRunsPreRequestScriptsButKeepsAndRecordsNothing() async throws {
        let server = try await authServer()
        let project = try scriptedProject(base: server.baseURL)
        try setScripts(project, request: project.profile.id, ScriptSet(preRequest: """
        rq.environment.set("seen", "1")
        rq.request.headers.upsert("Authorization", "Bearer " + rq.environment.get("seen"))
        """))
        let runner = makeRunner()

        let prepared = try await runner.prepare(project.profile.id, in: project.id)
        try setScripts(project, request: project.profile.id, ScriptSet(preRequest: "throw new Error('nope')"))
        var failure: RunFailure?
        do {
            _ = try await runner.prepare(project.profile.id, in: project.id)
        } catch {
            failure = error
        }

        XCTAssertEqual(prepared.urlRequest.value(forHTTPHeaderField: "Authorization"), "Bearer 1")
        XCTAssertEqual(prepared.summary.scriptChangedHeaders, ["authorization"])
        XCTAssertTrue(fixture.library.currentValues.values(in: .environment(project.id, project.defaultEnvironment)).isEmpty)
        XCTAssertEqual(failure?.kind, .script)
        XCTAssertTrue(server.requests.isEmpty)
        XCTAssertNil(runner.latest[RunKey(project.profile.id, in: project.id)], "A preview is no run")
    }

    private func runner(exchange: RequestExchange) -> RunOutcomeKind {
        RunSummary(exchange).outcomeKind
    }
}

/// Answers every trust question the same, counting them; a second question while one is open shares its answer.
@MainActor
private final class CountingTrustDecider: ScriptTrustDeciding {
    let answer: Bool?
    private(set) var questions = 0
    private(set) var lastFiles: [String] = []

    init(answer: Bool?) {
        self.answer = answer
    }

    func decideScriptTrust(projectName: String, files: [String]) async -> Bool? {
        questions += 1
        lastFiles = files
        // Lets the other run reach its own trust check while this question is open.
        await Task.yield()
        return answer
    }
}
