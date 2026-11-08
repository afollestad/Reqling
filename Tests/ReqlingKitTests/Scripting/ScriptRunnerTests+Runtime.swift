import CryptoKit
import Foundation
@testable import ReqlingKit
import ReqlingScriptProtocol
import ReqlingTemplating
import XCTest

extension ScriptRunnerTests {
    private func httpResponse(_ body: Data, code: Int = 200) -> ScriptResponseSnapshot {
        .http(ScriptHTTPResponse(
            code: code,
            status: "OK",
            headers: [ScriptRow(name: "Content-Type", value: "application/json")],
            body: ScriptBlob(index: 0, size: body.count),
            size: body.count,
            truncated: false,
            responseTime: 12
        ))
    }

    func testExpectCoversChaisCommonChainsAndRefusesTheRest() async {
        let checks = [
            "rq.expect(2).to.be.above(1).and.below(3)",
            "rq.expect({ a: { b: 1 } }).to.deep.equal({ a: { b: 1 } })",
            "rq.expect({ a: 1, b: 2 }).to.eql({ b: 2, a: 1 })",
            "rq.expect([1, 2, 3]).to.have.lengthOf(3).and.include(2)",
            "rq.expect({ id: 7 }).to.have.property('id', 7)",
            "rq.expect('abc').to.be.a('string').and.match(/b/)",
            "rq.expect(null).to.be.null",
            "rq.expect(undefined).to.not.exist",
            "rq.expect([]).to.be.empty",
            "rq.expect(5).to.be.oneOf([4, 5])",
            "rq.expect({ a: 1, b: 2 }).to.have.keys('a', 'b')",
            "rq.expect(() => { throw new Error('bad input') }).to.throw(/bad/)",
            "rq.expect(1).to.not.equal(1)",
            "rq.expect({ id: 7 }).to.have.property('name')",
            "rq.expect(1).to.be.frobnicated"
        ]
        let source = checks.enumerated().map { "rq.test(\"\($0.offset)\", () => { \($0.element) })" }.joined(separator: "\n")

        let run = await fixtures.run(ScriptFixtures.input(.preRequest, [source]))

        XCTAssertEqual(run.tests.map(\.result), Array(repeating: .passed, count: 12) + [.failed, .failed, .failed])
        XCTAssertEqual(run.tests.suffix(3).map(\.message), [
            "expected 1 to not equal 1",
            #"expected {"id": 7} to have property "name""#.replacingOccurrences(of: #"{"id": 7}"#, with: "{\n  \"id\": 7\n}"),
            "expect(…).frobnicated is not supported in Reqling scripts."
        ])
    }

    func testCryptoMatchesTheReferenceVectorsAndBase64RoundTrips() async {
        let run = await fixtures.run(ScriptFixtures.input(.preRequest, ["""
        console.log(rq.crypto.md5("abc"), rq.crypto.sha1("abc"))
        console.log(rq.crypto.sha256("abc", { encoding: "base64" }))
        console.log(rq.crypto.hmac("sha256", "Jefe", "what do ya want for nothing?"))
        console.log(rq.crypto.hmac("SHA1", "0b0b", "Hi", { keyEncoding: "hex" }).length)
        console.log(btoa("hello"), atob("aGVsbG8"), btoa("é"))
        try { btoa("€") } catch (error) { console.log(error.message) }
        const bytes = crypto.getRandomValues(new Uint8Array(16))
        console.log(bytes.length, typeof crypto.randomUUID(), rq.crypto.randomUUID().length)
        try { rq.crypto.sha3("x") } catch (error) { console.log(error.constructor.name) }
        try { rq.crypto.md5("zz", { inputEncoding: "hex" }) } catch (error) { console.log(error.message) }
        """]))

        XCTAssertEqual(run.console, [
            "900150983cd24fb0d6963f7d28e17f72 a9993e364706816aba3e25717850c26c9cd0d89d",
            "ungWv48Bz+pBQUDeXa4iI7ADYaOWF3qctBD/YfIAFa0=",
            "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843",
            "40",
            "aGVsbG8= hello 6Q==",
            "btoa: the text has a character outside Latin-1; encode it as UTF-8 first.",
            "16 string 36",
            "TypeError",
            "The text isn't valid hex."
        ])
    }

    func testVendoredLibrariesLoadOnFirstUseOnly() async {
        let run = await fixtures.run(ScriptFixtures.input(.preRequest, ["""
        console.log(CryptoJS.HmacSHA256("what do ya want for nothing?", "Jefe").toString())
        console.log(CryptoJS.enc.Base64.stringify(CryptoJS.enc.Utf8.parse("hi")), CryptoJS.lib.WordArray.random(16).sigBytes)
        console.log(JSON.stringify(_.chunk([1, 2, 3], 2)), require("lodash") === _, require("crypto-js") === CryptoJS)
        try { require("fs") } catch (error) { console.log(error.message) }
        """]))

        XCTAssertEqual(run.console, [
            "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843",
            "aGk= 16",
            "[[1,2],[3]] true true",
            #"require("fs") isn't available in Reqling scripts. Available: crypto-js, lodash."#
        ])
    }

    func testARunawayRecursionFailsTheLevelWithAShortStack() async {
        let run = await fixtures.run(ScriptFixtures.input(.preRequest, ["function deep() { deep() }\ndeep()"]))

        XCTAssertEqual(run.failures[0]?.name, "RangeError")
        XCTAssertEqual(run.failures[0]?.line, 1)
        XCTAssertLessThanOrEqual(run.failures[0]?.stack?.utf16.count ?? .max, 4_097)
    }

    func testALargeEventCrossesThePipeWhole() async {
        let run = await fixtures.run(ScriptFixtures.input(.preRequest, ["throw new Error('x'.repeat(1000000))"]))

        XCTAssertEqual(run.failures[0]?.message.count, 1_000_000)
    }

    func testThePostmanShimMapsOntoRqAndRefusesWhatItLacks() async {
        let body = Data(#"{"token": "t0k", "user": {"id": 7}}"#.utf8)
        let run = await fixtures.run(ScriptFixtures.input(.postResponse, ["""
        pm.test("status", () => pm.response.to.have.status(200))
        pm.test("header", () => pm.response.to.have.header("content-type", "application/json"))
        pm.test("json body", () => pm.response.to.have.jsonBody("user.id", 7))
        pm.test("not 404", () => pm.response.to.not.have.status(404))
        pm.test("ok", () => pm.response.to.be.ok)
        pm.environment.set("token", pm.response.json().token)
        pm.collectionVariables.set("shared", "1")
        pm.variables.set("local", "2")
        console.log(pm.info.eventName, pm.info.requestName, pm.environment.get("token"), pm.variables.replaceIn("{{local}}"))
        try { pm.sendRequest("https://x", () => {}) } catch (error) { console.log(error.message) }
        try { pm.request.headers.add({ key: "X", value: "1" }) } catch (error) { console.log(error.message) }
        """], response: httpResponse(body)), blobs: [body])

        XCTAssertEqual(run.tests.map(\.result), [.passed, .passed, .passed, .passed, .passed])
        XCTAssertEqual(run.writes.map(\.scope), [.environment, .defaultEnvironment, .local])
        XCTAssertEqual(run.console, [
            "test Login t0k 2",
            "pm.sendRequest isn't supported in Reqling scripts: scripts can't make network calls.",
            "Only pre-request scripts can change the request."
        ])
    }

    func testScriptsReadTheIterationAndItsDataRowAsText() async {
        let variables = VariableLayers(overrides: ["email": "override@acme.dev"], iterationData: ["email": "ada@acme.dev", "age": "36"])
        let run = await fixtures.run(ScriptFixtures.input(.preRequest, ["""
        console.log(rq.info.iteration, rq.info.iterationCount, pm.info.iteration, pm.info.iterationCount)
        console.log(rq.iterationData.get("age"), typeof rq.iterationData.get("age"), rq.iterationData.has("nope"))
        console.log(JSON.stringify(Object.entries(pm.iterationData.toObject()).sort()), rq.variables.get("age"), rq.variables.get("email"))
        console.log(pm.iterationData.get("email"), pm.iterationData.has("age"), pm.iterationData.has("nope"))
        """], variables: variables, iteration: (2, 5)))
        let alone = await fixtures.run(ScriptFixtures.input(.preRequest, ["""
        console.log(rq.info.iteration, rq.info.iterationCount, JSON.stringify(rq.iterationData.toObject()), rq.iterationData.get("id"))
        console.log(rq.iterationData.has("id"), pm.iterationData.get("id"), pm.info.iterationCount)
        """]))

        XCTAssertEqual(run.console, [
            "2 5 2 5",
            "36 string false",
            #"[["age","36"],["email","ada@acme.dev"]] 36 override@acme.dev"#,
            "ada@acme.dev true false"
        ], "Data reads as text, and one-run overrides beat it as `{{name}}` resolves")
        XCTAssertEqual(alone.console, ["0 1 {} undefined", "false undefined 1"], "A request run on its own is iteration 0 of 1, with no data")
    }

    func testFlowRequestsAreReportedOncePerChangeAndSkipOnlyBeforeTheRequest() async {
        let pre = await fixtures.run(ScriptFixtures.input(.preRequest, ["""
        for (let i = 0; i < 1000; i++) { rq.execution.setNextRequest("Login"); rq.execution.skipRequest() }
        pm.execution.setNextRequest(null)
        try { rq.execution.setNextRequest() } catch (error) { console.log(error.message) }
        """]))
        let post = await fixtures.run(ScriptFixtures.input(.postResponse, ["""
        try { pm.execution.skipRequest() } catch (error) { console.log(error.message) }
        """], response: httpResponse(Data())))

        XCTAssertEqual(pre.flow, [.setNextRequest("Login"), .skipRequest, .setNextRequest(nil)])
        XCTAssertEqual(pre.console, ["rq.execution.setNextRequest needs a request's name or ID, or null to end the iteration."])
        XCTAssertEqual(post.flow, [])
        XCTAssertEqual(post.console, ["rq.execution.skipRequest() works only in pre-request scripts."])
    }

    func testPreRequestScriptsChangeHeadersAndQueryForLaterLevels() async {
        let run = await fixtures.run(ScriptFixtures.input(.preRequest, [
            """
            rq.request.headers.upsert("X-Signature", rq.crypto.sha256(rq.variables.replaceIn(rq.request.body.raw)))
            rq.request.query.add("page", "2")
            rq.request.headers.remove("accept")
            """,
            """
            console.log(rq.request.method, rq.request.url, rq.request.headers.get("x-signature").length, rq.request.headers.has("Accept"))
            console.log(JSON.stringify(rq.request.query.all()))
            """
        ], variables: VariableLayers(defaultEnvironment: VariableLayer(saved: ["user": TemplateVariable(value: "ada")]))))

        XCTAssertEqual(run.changes.map(\.operation), [.upsert, .add, .remove])
        XCTAssertEqual(run.changes.first?.value, Data(#"{"user": "ada"}"#.utf8).sha256Hex)
        XCTAssertEqual(run.console, [
            "POST {{base}}/login 64 false",
            #"[{"name":"page","value":"1"},{"name":"page","value":"2"}]"#
        ])
    }

    func testGRPCCallsHaveMetadataButNoQuery() async {
        let run = await fixtures.run(ScriptFixtures.input(.preRequest, ["""
        rq.request.metadata.upsert("authorization", "Bearer x")
        console.log(rq.request.service, rq.request.rpc, rq.request.query === undefined, rq.request.headers === rq.request.metadata)
        """], request: ScriptFixtures.request("grpc")))

        XCTAssertEqual(run.console, ["greeter.Greeter SayHello true true"])
        XCTAssertEqual(run.changes.map(\.target), [.header])
    }

    /// The response is only a stream or post-response script's, and a runtime refusal points at the script's line that asked.
    func testReadingTheResponseBeforeTheRequestFailsAtTheCallersLine() async {
        let run = await fixtures.run(ScriptFixtures.input(.preRequest, ["const a = 1\nconst b = rq.response.code"]))

        XCTAssertEqual(run.failures[0]?.message, "rq.response is only available in stream and post-response scripts.")
        XCTAssertEqual(run.failures[0]?.line, 2)
    }

    func testEveryResponseKindReadsAsDocumented() async {
        let stream = ScriptResponseSnapshot.eventStream(ScriptEventStreamResponse(
            code: 200, status: "OK", headers: [], events: [ScriptStreamEvent(id: "1", event: "tick", data: #"{"n": 1}"#, retry: nil)],
            end: "closed", omittedEventCount: 0, responseTime: 5
        ))
        let call = ScriptResponseSnapshot.grpc(ScriptGRPCResponse(
            statusCode: 0, statusName: "ok", statusMessage: nil, metadata: [], trailers: [ScriptRow(name: "x-t", value: "1")],
            messages: [#"{"message": "hi"}"#], sentCount: 1, receivedCount: 1, responseTime: 5
        ))
        let socket = ScriptResponseSnapshot.webSocket(ScriptWebSocketResponse(
            code: 101, headers: [], subprotocol: nil,
            messages: [
                ScriptSocketMessage(direction: "received", text: #"{"ok": true}"#, base64: nil),
                ScriptSocketMessage(direction: "sent", text: nil, base64: "AAE=")
            ],
            closeCode: 1000, closeReason: "bye", end: "closed", responseTime: 5
        ))

        let streamed = await fixtures.run(ScriptFixtures.input(.postResponse, [
            "console.log(rq.response.events[0].json().n, rq.response.events[0].event, rq.response.end); rq.response.json()"
        ], response: stream))
        let called = await fixtures.run(ScriptFixtures.input(.postResponse, [
            "console.log(rq.response.code, rq.response.status.name, rq.response.json().message, rq.response.trailers.get('X-T'))"
        ], request: ScriptFixtures.request("grpc"), response: call))
        let connected = await fixtures.run(ScriptFixtures.input(.postResponse, [
            "const [first, second] = rq.response.messages; console.log(first.json().ok, second.isBinary, second.base64, rq.response.close.reason)"
        ], request: ScriptFixtures.request("websocket"), response: socket))

        XCTAssertEqual(streamed.console, ["1 tick closed"])
        XCTAssertEqual(streamed.failures[0]?.message, "An event stream has no single body; read rq.response.events.")
        XCTAssertEqual(called.console, ["0 ok hi 1"])
        XCTAssertEqual(connected.console, ["true true AAE= bye"])
    }

    func testLargeBodiesAndLineSeparatorsArriveIntact() async {
        let body = Data(repeating: UInt8(ascii: "a"), count: 8 * 1024 * 1024)
        let run = await fixtures.run(ScriptFixtures.input(.postResponse, ["""
        console.log(rq.response.text().length, rq.response.size)
        console.log("a\\u2028b\\u2029c")
        console.log({ nested: { list: [1, "two"] }, fn: function named() {} })
        const loop = {}; loop.self = loop; console.log(loop)
        """], response: httpResponse(body)), blobs: [body])

        XCTAssertEqual(run.console, [
            "8388608 8388608",
            "a\u{2028}b\u{2029}c",
            "{\n  \"nested\": {\n    \"list\": [\n      1,\n      \"two\"\n    ]\n  },\n  \"fn\": \"[Function named]\"\n}",
            "{\n  \"self\": \"[Circular]\"\n}"
        ])
    }

    func testConsoleAndTestsStopAtTheirLimits() async {
        var limits = ScriptLimits()
        limits.consoleEntries = 2
        limits.tests = 1
        let run = await fixtures.run(ScriptFixtures.input(.preRequest, [
            "for (let i = 0; i < 5; i++) { console.log(i) }\nrq.test('a', () => {}); rq.test('b', () => {})"
        ], limits: limits))

        XCTAssertEqual(run.console, [
            "0", "1", "Further console messages from this phase were not kept.", "Further tests in this phase were not reported."
        ])
        XCTAssertEqual(run.tests.map(\.name), ["a"])
    }

    func testAMissingRuntimeOrHelperFailsThePhase() async throws {
        let empty = try TemporaryDirectory()
        defer { empty.remove() }
        let noRuntime = HelperScriptRunner(executable: ScriptFixtures.helper, runtimeDirectory: empty.url)
        let noHelper = HelperScriptRunner(executable: nil, runtimeDirectory: ScriptFixtures.runtime)

        let missingRuntime = await noRuntime.run(ScriptFixtures.input(.preRequest, ["1"]), blobs: [], timeLimit: .seconds(10)).termination()
        let missingHelper = await noHelper.run(ScriptFixtures.input(.preRequest, ["1"]), blobs: [], timeLimit: .seconds(10)).termination()

        XCTAssertEqual(missingRuntime, .failed("Reqling's script runtime is missing. Reinstall Reqling."))
        XCTAssertEqual(missingHelper, .failed(HelperScriptRunner.missingMessage))
    }

    func testAnotherProtocolVersionIsRefused() async {
        var input = ScriptFixtures.input(.preRequest, ["1"])
        input.protocolVersion = 99

        let run = await fixtures.run(input)

        XCTAssertEqual(run.termination, .failed("Reqling's script runner couldn't read what to run."))
        XCTAssertTrue(run.events.isEmpty)
    }

    func testCancellingKillsTheHelper() async {
        let input = ScriptFixtures.input(.preRequest, ["console.log('started'); while (true) {}"])
        let execution = fixtures.runner.run(input, blobs: [], timeLimit: .seconds(10))
        for await event in execution.events {
            if case .console = event {
                execution.cancel()
            }
        }

        let termination = await execution.termination()
        XCTAssertEqual(termination, .cancelled)
    }
}

private extension Data {
    var sha256Hex: String {
        SHA256.hash(data: self).map { String(format: "%02x", $0) }.joined()
    }
}
