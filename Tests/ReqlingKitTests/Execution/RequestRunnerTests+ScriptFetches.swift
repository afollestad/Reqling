import Foundation
@testable import ReqlingKit
import ReqlingScriptProtocol
import ReqlingTemplating
import XCTest

/// Requests scripts send through runs: Reqling sends each, logs it in the console, and answers the script.
@MainActor
extension RequestRunnerTests {
    /// Answers /token with a token and a session cookie, /login with what it was sent as JSON, and /me with its
    /// Authorization and Cookie headers. /slow never answers, yielding to `slow` once it arrives.
    private func fetchServer(slow: AsyncStream<Void>.Continuation? = nil) async throws -> TestHTTPServer {
        let server = try await TestHTTPServer.start { request in
            if request.uri.hasPrefix("/token") {
                return .text(#"{"token": "fresh"}"#, headers: [("Content-Type", "application/json"), ("Set-Cookie", "session=abc; Path=/")])
            }
            if request.uri.hasPrefix("/login") {
                let sent = ["auth": request.header("Authorization"), "user": request.header("X-User"), "scripted": request.header("X-Scripted")]
                let json = (try? JSONEncoder().encode(sent.mapValues { $0 ?? "-" })).flatMap { String(bytes: $0, encoding: .utf8) } ?? "{}"
                return .text(json, headers: [("Content-Type", "application/json")])
            }
            if request.uri.hasPrefix("/slow") {
                slow?.yield()
                return .hang
            }
            return .text("\(request.header("Authorization") ?? "-") cookie=\(request.header("Cookie") ?? "-")")
        }
        servers.append(server)
        return server
    }

    private func preRequestConsole(_ exchange: RequestExchange) -> [ScriptConsoleEntry] {
        exchange.scriptReport?.phase(.preRequest)?.console ?? []
    }

    func testAPreRequestScriptRefreshesATokenThroughARequestItSendsWithItsSecretsMasked() async throws {
        let server = try await fetchServer()
        let project = try scriptedProject(base: server.baseURL)
        try fixture.library.mutate(project.id) { document in
            document.defaultEnvironment.variables.append(Variable(key: "clientSecret", value: "s3cr3t-value", isSecret: true))
        }
        try setScripts(project, request: project.profile.id, ScriptSet(preRequest: """
        const res = await rq.sendRequest({
          method: "POST", url: rq.variables.replaceIn("{{base}}/token?secret={{clientSecret}}"),
          headers: { "X-Client": "reqling" }, body: { grant: "refresh" }
        })
        rq.environment.set("token", res.json().token, { secret: true })
        rq.request.headers.upsert("Authorization", "Bearer " + rq.environment.get("token"))
        """))
        let runner = makeRunner()

        let exchange = await runner.run(project.profile.id, in: project.id)

        XCTAssertEqual(body(exchange), "Bearer fresh cookie=session=abc", "The token's cookie landed in the jar the request then sent")
        let token = try XCTUnwrap(server.requests.first)
        XCTAssertEqual(token.method, "POST")
        XCTAssertEqual(token.uri, "/token?secret=s3cr3t-value")
        XCTAssertEqual(token.header("X-Client"), "reqling")
        XCTAssertEqual(token.header("Content-Type"), "application/json")
        XCTAssertEqual(token.header("User-Agent"), "Reqling/1.0")
        XCTAssertEqual(String(bytes: token.body, encoding: .utf8), #"{"grant":"refresh"}"#)
        let line = try XCTUnwrap(preRequestConsole(exchange).first)
        XCTAssertEqual(line.severity, .info)
        XCTAssertTrue(line.text.hasPrefix("→ POST \(server.baseURL)/token?secret=\(TemplateResolver.mask) · 200 OK · "), line.text)
        XCTAssertTrue(line.text.hasSuffix(" ms"), line.text)
    }

    func testRunRequestSendsASavedRequestAsARunResolvesItWithoutItsScriptsOrHistory() async throws {
        let server = try await fetchServer()
        let project = try scriptedProject(base: server.baseURL)
        try fixture.library.mutate(project.id) { document in
            try document.updateFolder(project.folder.id) { $0.auth = .bearer(token: "{{apiKey}}") }
            try document.updateRequest(project.login.id) { login in
                login.kind = .http(HTTPRequestSpec(method: .post, url: "{{base}}/login", headers: [KeyValuePair(key: "X-User", value: "{{user}}")]))
                login.scripts = ScriptSet(preRequest: "rq.request.headers.upsert('X-Scripted', 'yes')")
            }
        }
        try setScripts(project, request: project.profile.id, ScriptSet(preRequest: """
        rq.variables.set("apiKey", "k3y")
        const json = (await rq.runRequest("Login", { variables: { user: "ada" } })).json()
        console.log(json.auth, json.user, json.scripted)
        """))
        let runner = makeRunner()

        let exchange = await runner.run(project.profile.id, in: project.id)

        let console = preRequestConsole(exchange).map(\.text)
        XCTAssertEqual(console.count, 2, "\(console)")
        XCTAssertTrue(console.first?.hasPrefix("→ “Login” POST \(server.baseURL)/login · 200 OK · ") ?? false, "\(console)")
        XCTAssertEqual(console.last, "Bearer k3y ada -")
        XCTAssertNil(runner.exchange(for: project.login.id, in: project.id))
        runner.flushHistory()
        XCTAssertTrue(runner.history.runs(for: project.login.id, in: project.id).isEmpty)
    }

    func testARequestAScriptCantSendFailsWithoutGoingOutAndIsLoggedAsAnError() async throws {
        let server = try await fetchServer()
        let project = try scriptedProject(base: server.baseURL)
        try fixture.library.mutate(project.id) { document in
            try document.insert(.request(RequestItem(name: "Twin", kind: .http(HTTPRequestSpec(url: "{{base}}/a")))), into: project.folder.id)
            try document.insert(.request(RequestItem(name: "Twin", kind: .http(HTTPRequestSpec(url: "{{base}}/b")))), into: nil)
            try document.insert(.request(RequestItem(name: "Stream", kind: .grpc(GRPCRequestSpec(target: "localhost:1")))), into: nil)
        }
        try setScripts(project, request: project.profile.id, ScriptSet(preRequest: """
        for (const name of ["Twin", "Nobody", "Stream"]) {
          try { await rq.runRequest(name) } catch (error) { console.log(error.message) }
        }
        for (const request of ["file://localhost/etc/hosts", { url: "http://example.test", body: "a" }]) {
          try { await rq.sendRequest(request) } catch (error) { console.log(error.message) }
        }
        """))

        let exchange = await makeRunner().run(project.profile.id, in: project.id)

        let messages = [
            ("“Twin”", "Several requests are named “Twin”: Users/Twin, Twin. Name one by its ID."),
            ("“Nobody”", "This project has no request named “Nobody”."),
            ("“Stream”", "“Stream” is a gRPC request; rq.runRequest sends HTTP requests."),
            ("GET file://localhost/etc/hosts", "Scripts send only http and https requests."),
            ("GET http://example.test", "A GET request can’t send a body.")
        ]
        let console = preRequestConsole(exchange)
        XCTAssertEqual(console.map(\.text), messages.flatMap { ["→ \($0.0) failed: \($0.1)", $0.1] })
        XCTAssertEqual(Set(console.enumerated().filter { $0.offset.isMultiple(of: 2) }.map(\.element.severity)), [.error])
        XCTAssertEqual(server.requests.map(\.uri), ["/me"], "Only the request itself went out")
    }

    func testTheTimeLimitCancelsARequestStillOutNotingItInTheConsole() async throws {
        let (arrivals, arrived) = AsyncStream<Void>.makeStream()
        let server = try await fetchServer(slow: arrived)
        let project = try scriptedProject(base: server.baseURL)
        try setScripts(project, request: project.profile.id, ScriptSet(preRequest: "await rq.sendRequest(rq.variables.replaceIn('{{base}}/slow'))"))
        let runner = makeRunner()

        let run = Task { await runner.run(project.profile.id, in: project.id) }
        for await _ in arrivals {
            break
        }
        await waitForDeadline(scriptDeadline)
        scriptDeadline.wake()
        let exchange = await run.value

        XCTAssertEqual(exchange.failure?.kind, .script)
        XCTAssertTrue(exchange.failure?.message.contains("didn't finish within 10 s") ?? false, exchange.failure?.message ?? "")
        let line = try XCTUnwrap(preRequestConsole(exchange).last)
        XCTAssertEqual(line.severity, .warn)
        XCTAssertEqual(line.text, "→ GET \(server.baseURL)/slow didn't finish before its script ended.")
    }

    /// The call ends at once, so the request may not have reached the server by then; either way it's cancelled and
    /// noted while the stream is still open, rather than holding its place in the queue until the phase ends.
    func testARequestAStreamCallLeftOutIsCancelledAsTheCallEnds() async throws {
        let events = StreamFeed()
        let server = try await TestHTTPServer.start { request in
            request.uri.hasPrefix("/slow") ? .hang : .stream(headers: [("Content-Type", "text/event-stream")], feed: events)
        }
        servers.append(server)
        let project = try scriptedProject(base: server.baseURL)
        try setScripts(project, request: project.login.id, ScriptSet(stream: """
        rq.onEvent(() => {
          rq.sendRequest(rq.variables.replaceIn("{{base}}/slow"))
          setTimeout(() => { throw new Error("gone") }, 0)
        })
        """))
        let key = RunKey(project.login.id, in: project.id)
        let runner = makeRunner()
        let unfinished = "→ GET \(server.baseURL)/slow didn't finish before its script ended."

        let run = Task { await runner.run(project.login.id, in: project.id) }
        await events.opened()
        try await events.send("data: 1\n\n")
        await waitUntil("the call's request shows as cancelled while the stream is open") {
            runner.latest[key]?.scriptReport?.phase(.stream)?.console.map(\.text) == [unfinished]
        }
        try await events.end()
        let exchange = await run.value

        XCTAssertEqual(exchange.scriptReport?.phase(.stream)?.levels.first?.error?.message, "gone")
        XCTAssertEqual(exchange.scriptReport?.phase(.stream)?.console.map(\.text), [unfinished])
    }

    func testARunsRequestsCarryTheCookiesItsScriptsSetAndKeepWhatTheyReceive() async throws {
        let server = try await fetchServer()
        let project = try scriptedProject(base: server.baseURL)
        try setScripts(project, request: project.profile.id, ScriptSet(preRequest: """
        const base = rq.variables.replaceIn("{{base}}")
        rq.cookies.for(base).set("pref", "dark")
        console.log((await rq.sendRequest(base + "/me")).text())
        await rq.sendRequest(base + "/token")
        console.log(rq.cookies.for(base).get("session"))
        """))
        let runner = makeRunner()

        let exchange = await runner.run(project.profile.id, in: project.id)

        let console = preRequestConsole(exchange).map(\.text)
        XCTAssertEqual(console.count, 4, "\(console)")
        XCTAssertEqual(console[1], "- cookie=pref=dark")
        XCTAssertEqual(console[3], "abc")
        XCTAssertEqual(Set(runner.cookieJar(for: project.id, creating: false)?.cookies(in: nil).map(\.name) ?? []), ["pref", "session"])
    }

    func testAPreviewSendsItsScriptsRequestsWithTheirCookiesButKeepsNoneOfThem() async throws {
        let server = try await fetchServer()
        let project = try scriptedProject(base: server.baseURL)
        try setScripts(project, request: project.profile.id, ScriptSet(preRequest: """
        const base = rq.variables.replaceIn("{{base}}")
        rq.cookies.for(base).set("pref", "dark")
        console.log((await rq.sendRequest(base + "/me")).text())
        await rq.sendRequest(base + "/token")
        console.log(rq.cookies.for(base).get("session"))
        """))
        let runner = makeRunner()

        let preview = try await runner.previewHTTP(project.profile.id, in: project.id, options: RunOptions())

        let console = preview.scriptReport?.phase(.preRequest)?.console.map(\.text) ?? []
        XCTAssertEqual(console.count, 4, "\(console)")
        XCTAssertEqual(console[1], "- cookie=pref=dark")
        XCTAssertEqual(console[3], "abc", "The scripts see what a run's would")
        XCTAssertEqual(server.requests.map(\.uri), ["/me", "/token"])
        XCTAssertEqual(runner.cookieJar(for: project.id, creating: false)?.cookies(in: nil) ?? [], [])
    }

    func testStoppingAStreamLetsAHandlersRequestFinish() async throws {
        let events = StreamFeed()
        let lookup = StreamFeed()
        let server = try await TestHTTPServer.start { request in
            request.uri.hasPrefix("/lookup")
                ? .stream(headers: [("Content-Type", "text/plain")], feed: lookup)
                : .stream(headers: [("Content-Type", "text/event-stream")], feed: events)
        }
        servers.append(server)
        let project = try scriptedProject(base: server.baseURL)
        try setScripts(project, request: project.login.id, ScriptSet(stream: """
        rq.onEvent(async (event) => {
          const res = await rq.sendRequest(rq.variables.replaceIn("{{base}}/lookup/") + event.data)
          console.log("found", res.text())
        })
        """))
        let runner = makeRunner()

        let run = Task { await runner.run(project.login.id, in: project.id) }
        await events.opened()
        try await events.send("data: 7\n\n")
        await lookup.opened()
        runner.cancel(project.login.id, in: project.id)
        try await lookup.send("ada")
        try await lookup.end()
        let exchange = await run.value

        let phase = try XCTUnwrap(exchange.scriptReport?.phase(.stream))
        let console = phase.console.map(\.text)
        XCTAssertEqual(console.count, 2, "\(console)")
        XCTAssertTrue(console.first?.hasPrefix("→ GET \(server.baseURL)/lookup/7 · 200 OK · ") ?? false, "\(console)")
        XCTAssertEqual(console.last, "found ada")
        XCTAssertEqual(phase.stream?.handledCount, 1)
        XCTAssertNil(phase.error)
    }
}
