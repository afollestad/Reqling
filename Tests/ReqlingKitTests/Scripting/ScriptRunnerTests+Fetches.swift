import Foundation
@testable import ReqlingKit
import ReqlingScriptProtocol
import ReqlingTemplating
import XCTest

/// Requests scripts send through the real helper: each goes out as an event, and the fixture answers it as Reqling
/// would, so these check what the helper sends and what scripts make of the reply.
extension ScriptRunnerTests {
    func testRequestsGoOutAsGivenAndResolveWithTheirResponse() async {
        let run = await fixtures.run(ScriptFixtures.input(.preRequest, ["""
        const res = await rq.sendRequest({
          method: "post", url: "{{base}}/token", headers: { Accept: "application/json", "X-N": 7 }, body: { grant: "refresh" }
        })
        console.log(res.code, res.status, res.headers.get("content-type"), res.json().ok, res.text(), res.size, res.truncated, res.responseTime)
        console.log(res.base64(), Object.isFrozen(res))
        console.log((await rq.sendRequest("https://example.test/health")).code)
        await rq.sendRequest({ url: "https://example.test/bytes", method: "PUT", headers: [["X-A", "1"]], body: new Uint8Array([1, 2, 3]) })
        await rq.sendRequest({ url: "https://example.test/text", method: "Mkcol-ish", body: "plain" })
        console.log((await rq.runRequest("Login", { variables: { user: "ada", n: 2 } })).json().ok)
        """]))

        XCTAssertEqual(run.termination, .finished)
        XCTAssertEqual(run.failures.count, 0)
        XCTAssertEqual(run.console, [
            #"200 OK application/json true {"ok": true} 12 false 12"#,
            "\(Data(#"{"ok": true}"#.utf8).base64EncodedString()) true",
            "200",
            "true"
        ])
        XCTAssertEqual(run.fetches, [
            .send(ScriptFetchRequest(method: "POST", url: "{{base}}/token", headers: [
                ScriptRow(name: "Accept", value: "application/json"), ScriptRow(name: "X-N", value: "7"),
                ScriptRow(name: "Content-Type", value: "application/json")
            ], body: Data(#"{"grant":"refresh"}"#.utf8))),
            .send(ScriptFetchRequest(method: "GET", url: "https://example.test/health")),
            .send(ScriptFetchRequest(method: "PUT", url: "https://example.test/bytes", headers: [ScriptRow(name: "X-A", value: "1")],
                                     body: Data([1, 2, 3]))),
            .send(ScriptFetchRequest(method: "Mkcol-ish", url: "https://example.test/text", body: Data("plain".utf8))),
            .run(request: "Login", variables: ["user": "ada", "n": "2"])
        ])
    }

    func testAFailedRequestRejectsWhereItsAwaitedWhileAnyStatusResolvesAndBadArgumentsThrowAtTheCall() async {
        let run = await fixtures.run(ScriptFixtures.input(.preRequest, ["""
        const bad = [undefined, 7, { url: "" }, { url: "x", headers: 5 }, { url: "x", method: "BAD METHOD" }, { url: "x", nope: 1 },
                     { url: "x", body: () => 1 }]
        for (const request of bad) {
          try { rq.sendRequest(request) } catch (error) { console.log(error.message) }
        }
        for (const [request, options] of [["", undefined], ["Login", { vars: {} }], ["Login", { variables: [] }]]) {
          try { rq.runRequest(request, options) } catch (error) { console.log(error.message) }
        }
        try { await rq.sendRequest("https://example.test/down") } catch (error) { console.log(error.message) }
        const missing = await rq.sendRequest("https://example.test/missing")
        console.log(missing.code, missing.status)
        rq.sendRequest("https://example.test/down").then(() => console.log("resolved"), (error) => console.log("then:", error.message))
        """])) { fetch in
            guard case .send(let request) = fetch else {
                return nil
            }
            return request.url.hasSuffix("down") ? .failure("Could not connect to the server.") : .response(404, status: "Not Found")
        }

        XCTAssertEqual(run.failures.count, 0)
        XCTAssertEqual(run.console, [
            #"rq.sendRequest needs a URL, or a request such as { method: "POST", url, headers, body }."#,
            #"rq.sendRequest needs a URL, or a request such as { method: "POST", url, headers, body }."#,
            #"rq.sendRequest needs a URL, such as "https://api.example.com/token"."#,
            "rq.sendRequest's headers are an object of names and values, or [name, value] pairs.",
            #"rq.sendRequest: "BAD METHOD" isn't an HTTP method."#,
            #"rq.sendRequest takes method, url, headers, body, not "nope"."#,
            "rq.sendRequest sends text, bytes, or a value JSON can hold as a body, not [Function body].",
            "rq.runRequest needs a saved request's name or ID.",
            #"rq.runRequest takes { variables }, not "vars"."#,
            "rq.runRequest's variables are an object of names and values.",
            "Could not connect to the server.",
            "404 Not Found",
            "then: Could not connect to the server."
        ])
        XCTAssertEqual(run.fetches.count, 3, "Only the requests that were well formed go out")
    }

    func testAPendingCallbackKeepsItsLevelGoingAndOneThatThrowsFailsTheLevel() async {
        let run = await fixtures.run(ScriptFixtures.input(.preRequest, [
            """
            pm.sendRequest("https://example.test/a", (error, res) => {
              pm.environment.set("ok", res.json().ok)
              console.log("callback", error, res.code)
            })
            pm.sendRequest("https://example.test/down", (error, res) => console.log(error.message, res))
            """,
            """
            pm.sendRequest("https://example.test/b", () => { throw new Error("boom") })
            """
        ])) { fetch in
            if case .send(let request) = fetch, request.url.hasSuffix("down") {
                return .failure("Could not connect to the server.")
            }
            return .response()
        }

        XCTAssertEqual(run.console, ["callback null 200", "Could not connect to the server. undefined"])
        XCTAssertEqual(run.writes.map(\.key), ["ok"])
        XCTAssertEqual(run.writes.first?.value, "true")
        XCTAssertNil(run.failures[0])
        XCTAssertEqual(run.failures[1]?.message, "boom")
    }

    func testPostmanRequestsMapOntoRqForEachBodyMode() async throws {
        let run = await fixtures.run(ScriptFixtures.input(.preRequest, ["""
        await pm.sendRequest({ url: "https://example.test/raw", method: "POST", header: { "X-A": "1" },
                               body: { mode: "raw", raw: '{"a":1}', options: { raw: { language: "json" } } } })
        await pm.sendRequest({ url: { raw: "https://example.test/form" }, method: "POST",
                               header: [{ key: "X-B", value: "2" }, { key: "X-Off", value: "0", disabled: true }, "X-C: 3"],
                               body: { mode: "urlencoded", urlencoded: [{ key: "a b", value: "c&d" }, { key: "off", value: "1", disabled: true }] } })
        await pm.sendRequest({ url: "https://example.test/multi", method: "POST",
                               body: { mode: "formdata", formdata: [{ key: "name", value: "Ada" }] } })
        await pm.sendRequest({ url: "https://example.test/gql", method: "POST",
                               body: { mode: "graphql", graphql: { query: "{ me { id } }", variables: '{"a": 1}' } } })
        const res = await pm.sendRequest("https://example.test/plain")
        console.log(res.code, res.status, res.json().ok, res.headers.get("content-type"), res.size())
        pm.test("status", () => res.to.have.status(200))
        console.log((await pm.execution.runRequest("request-id", { variables: { a: 1 } })).code)
        """]))

        XCTAssertEqual(run.failures.count, 0)
        XCTAssertEqual(run.tests.map(\.result), [.passed])
        XCTAssertEqual(run.console, ["200 OK true application/json 12", "200"])
        let requests = run.fetches.compactMap { fetch -> ScriptFetchRequest? in
            if case .send(let request) = fetch {
                return request
            }
            return nil
        }
        XCTAssertEqual(requests.count, 5)
        XCTAssertEqual(requests[0], ScriptFetchRequest(method: "POST", url: "https://example.test/raw", headers: [
            ScriptRow(name: "X-A", value: "1"), ScriptRow(name: "Content-Type", value: "application/json")
        ], body: Data(#"{"a":1}"#.utf8)))
        XCTAssertEqual(requests[1], ScriptFetchRequest(method: "POST", url: "https://example.test/form", headers: [
            ScriptRow(name: "X-B", value: "2"), ScriptRow(name: "X-C", value: "3"),
            ScriptRow(name: "Content-Type", value: "application/x-www-form-urlencoded")
        ], body: Data("a+b=c%26d".utf8)))
        let multipart = try XCTUnwrap(requests[2].headers.first?.value)
        let boundary = try XCTUnwrap(multipart.components(separatedBy: "boundary=").last)
        XCTAssertTrue(multipart.hasPrefix("multipart/form-data; boundary=----ReqlingFormBoundary"))
        let part = "--\(boundary)\r\nContent-Disposition: form-data; name=\"name\"\r\n\r\nAda\r\n"
        XCTAssertEqual(requests[2].body, Data((part + "--\(boundary)--\r\n").utf8))
        XCTAssertEqual(requests[3].headers, [ScriptRow(name: "Content-Type", value: "application/json")])
        XCTAssertEqual(requests[3].body, Data(#"{"query":"{ me { id } }","variables":{"a":1}}"#.utf8))
        XCTAssertEqual(requests[4], ScriptFetchRequest(method: "GET", url: "https://example.test/plain"))
        XCTAssertEqual(run.fetches.last, .run(request: "request-id", variables: ["a": "1"]))
    }

    func testAPostmanRequestReqlingCantSendThrowsRatherThanGoingOutWithoutWhatItAsked() async {
        let run = await fixtures.run(ScriptFixtures.input(.preRequest, ["""
        const bad = [{ url: "x", auth: {} }, { url: "x", body: { mode: "file" } },
                     { url: "x", body: { mode: "formdata", formdata: [{ key: "f", type: "file", src: "/etc/hosts" }] } }]
        for (const request of bad) {
          try { pm.sendRequest(request) } catch (error) { console.log(error.message) }
        }
        """]))

        XCTAssertEqual(run.console, [
            #"pm.sendRequest takes a request's url, method, header, body in Reqling scripts, not "auth"."#,
            "pm.sendRequest can't send files from Reqling scripts.",
            "pm.sendRequest can't send files from Reqling scripts."
        ])
        XCTAssertTrue(run.fetches.isEmpty)
    }

    func testScriptsSeeTheJarARequestLeftWithTheChangesMadeSinceItWentOutOnTop() async {
        let run = await fixtures.run(ScriptFixtures.input(.preRequest, ["""
        const jar = rq.cookies.for("https://example.test")
        jar.set("mine", "x")
        console.log(JSON.stringify(Object.keys(jar.toObject()).sort()))
        const login = rq.sendRequest("https://example.test/login")
        jar.set("late", "y")
        await login
        console.log(JSON.stringify(Object.keys(jar.toObject()).sort()), jar.get("session"))
        """], cookies: [ScriptCookie(name: "old", value: "1", domain: "example.test")])) { _ in
            // The server expired `old` and set `session`. Reqling had `mine`, reported before the request went out, but
            // not `late`, which the script set while it was out.
            .response(cookies: [
                ScriptCookie(name: "mine", value: "x", domain: "example.test"),
                ScriptCookie(name: "session", value: "abc", domain: "example.test")
            ])
        }

        XCTAssertEqual(run.console, [#"["mine","old"]"#, #"["late","mine","session"] abc"#])
        XCTAssertEqual(run.cookieWrites.count, 2, "Taking the jar from a reply reports nothing")
    }

    /// A stream phase's changes reach the jar as calls finish, so one an earlier call made isn't replayed over what a
    /// later response stored.
    func testAStreamCallSeesWhatAResponseStoredOverAnEarlierCallsChange() async {
        let run = await fixtures.stream(ScriptFixtures.input(.stream, ["""
        const jar = rq.cookies.for("https://example.test")
        rq.onEvent(async (event) => {
          if (event.data === "1") {
            jar.set("token", "mine")
          } else {
            await rq.sendRequest("https://example.test/refresh")
            console.log(jar.get("token"))
          }
        })
        """]), items: [ScriptFixtures.event("1", 1), ScriptFixtures.event("2", 2)]) { _ in
            .response(cookies: [ScriptCookie(name: "token", value: "server", domain: "example.test")])
        }

        XCTAssertEqual(run.console, ["server"])
    }

    func testRequestsPastTheLimitThrow() async {
        var limits = ScriptLimits()
        limits.fetches = 2
        limits.fetchBodyLength = 1_048_576
        let run = await fixtures.run(ScriptFixtures.input(.preRequest, ["""
        try {
          rq.sendRequest({ url: "https://example.test/big", method: "POST", body: "x".repeat(1048577) })
        } catch (error) {
          console.log(error.message)
        }
        await rq.sendRequest("https://example.test/1")
        await rq.runRequest("Login")
        try { rq.sendRequest("https://example.test/3") } catch (error) { console.log(error.message) }
        """], limits: limits))

        XCTAssertEqual(run.console, [
            "rq.sendRequest can send at most 1 MB in one body.",
            "Scripts can send at most 2 requests in one phase."
        ])
        XCTAssertEqual(run.fetches.count, 2)
    }

    func testAReplyALevelLeftBehindIsDroppedWhileTheNextLevelGetsItsOwn() async {
        let body = Data("{}".utf8)
        let input = ScriptFixtures.input(.postResponse, [
            """
            rq.sendRequest("https://example.test/slow").then(() => console.log("late"))
            setTimeout(() => { throw new Error("gone") }, 0)
            """,
            """
            const res = await rq.sendRequest("https://example.test/fast")
            console.log("got", res.json().which)
            """
        ], response: .http(ScriptHTTPResponse(
            code: 200, status: "OK", headers: [], body: ScriptBlob(index: 0, size: body.count), size: body.count, truncated: false, responseTime: 1
        )))
        let execution = fixtures.runner.run(input, blobs: [body], timeLimit: .seconds(10))
        var events: [ScriptRunnerEvent] = []
        for await event in execution.events {
            events.append(event)
            // The first level has given up on its request by the time the second sends one; only then does it answer.
            if case .fetch(let id, _, _) = event, id == 2 {
                let slow = ScriptFetchAnswer.response(body: #"{"which": "slow"}"#)
                let fast = ScriptFetchAnswer.response(body: #"{"which": "fast"}"#)
                execution.reply(slow.reply(1), slow.body)
                execution.reply(fast.reply(2), fast.body)
            }
        }
        let run = ScriptRun(events: events, termination: await execution.termination())

        XCTAssertEqual(run.termination, .finished)
        XCTAssertEqual(run.failures[0]?.message, "gone")
        XCTAssertNil(run.failures[1])
        XCTAssertEqual(run.console, ["got fast"])
    }

    func testStreamHandlersEachWaitForTheirOwnRequestsWithinTheirOwnLimit() async {
        var limits = ScriptLimits()
        limits.fetches = 1
        let run = await fixtures.stream(ScriptFixtures.input(.stream, ["""
        const config = await rq.sendRequest("https://example.test/config")
        rq.onEvent(async (event) => {
          const res = await rq.sendRequest(`https://example.test/item/${event.data}`)
          console.log("handled", event.data, res.code, config.json().ok)
          try { rq.sendRequest("https://example.test/again") } catch (error) { console.log(error.message) }
        })
        """], limits: limits), items: [ScriptFixtures.event("1", 1), ScriptFixtures.event("2", 2)]) { fetch in
            guard case .send(let request) = fetch else {
                return nil
            }
            return .response(request.url.hasSuffix("2") ? 201 : 200)
        }

        XCTAssertEqual(run.termination, .finished)
        XCTAssertEqual(run.calls, [1, 2])
        XCTAssertTrue(run.callFailures.isEmpty)
        XCTAssertEqual(run.console, [
            "handled 1 200 true", "Scripts can send at most 1 requests in one handler call.",
            "handled 2 201 true", "Scripts can send at most 1 requests in one handler call."
        ])
        XCTAssertEqual(run.fetches.count, 3)
    }

    func testARequestNeverAnsweredRunsIntoTheTimeLimit() async {
        let fixtures = fixtures
        let run = await fixtures.run(ScriptFixtures.input(.preRequest, ["""
        rq.environment.set("before", "1")
        await rq.sendRequest("https://example.test/never")
        rq.environment.set("after", "1")
        """])) { _ in
            fixtures.deadline.wake()
            return nil
        }

        XCTAssertEqual(run.termination, .timedOut)
        XCTAssertEqual(run.writes.map(\.key), ["before"])
    }

    /// The conformance walk never follows what a method returns, so this checks a request's response against the
    /// catalog's `IncomingResponse` both ways.
    func testARequestsResponseHasExactlyWhatTheCatalogDocuments() async throws {
        let run = await fixtures.run(ScriptFixtures.input(.preRequest, ["""
        const res = await rq.sendRequest("https://example.test")
        console.log(JSON.stringify(Object.keys(res).sort()))
        """]))

        let keys = try JSONDecoder().decode([String].self, from: Data(try XCTUnwrap(run.console.first).utf8))
        let documented = try XCTUnwrap(ScriptAPICatalog.standard.type("IncomingResponse")).members.map(\.name)
        XCTAssertEqual(keys, documented.sorted())
    }
}
