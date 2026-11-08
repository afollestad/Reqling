import Foundation
import MCP
@testable import ReqlingKit
import ReqlingScriptProtocol
import XCTest

/// Script results in the execution and history tools, with what scripts made secret masked.
@MainActor
extension MCPExecutionToolsTests {
    private func setScripts(preRequest: String = "", postResponse: String = "") async throws {
        _ = try await fixture.success("update_request", [
            "project": .string(project.description),
            "request": .string(request),
            "scripts": ["preRequest": .string(preRequest), "postResponse": .string(postResponse)]
        ])
    }

    func testARunReturnsItsScriptsResultsWithWhatTheyMadeSecretMasked() async throws {
        try await setScripts(
            preRequest: """
            rq.variables.set("sig", "s1gn-4ture", { secret: true })
            rq.request.headers.upsert("Authorization", "Sig " + rq.variables.get("sig"))
            """,
            postResponse: """
            rq.test("ok", () => rq.expect(rq.response.code).to.equal(200))
            rq.test("echoes", () => rq.expect(rq.response.text()).to.include("Sig"))
            rq.test("never", () => rq.expect(1).to.equal(2))
            console.log("signed with", rq.variables.get("sig"))
            """
        )

        let result = try await execute()
        let runs = try await fixture.success("list_runs", ["project": .string(project.description), "request": .string(request)])

        XCTAssertEqual(server.requests.last?.header("Authorization"), "Sig s1gn-4ture")
        let text = MCPJSON.text(.object(result))
        XCTAssertFalse(text.contains("s1gn-4ture"), "Masked in the echoed body and header too, though no environment holds it: \\(text)")
        XCTAssertEqual(result["testSummary"], ["passed": 2, "failed": 1, "skipped": 0])
        XCTAssertEqual(result["tests"]?.arrayValue?.last, [
            "phase": "postResponse", "script": "the request", "name": "never", "result": "failed", "message": "expected 1 to equal 2"
        ])
        XCTAssertEqual(result["console"]?.arrayValue?.first?["text"], "signed with ••••••")
        XCTAssertEqual(runs["runs"]?.arrayValue?.first?["tests"], ["passed": 2, "failed": 1, "skipped": 0])
        XCTAssertEqual(runs["runs"]?.arrayValue?.first?["outcome"], "failed", "A failed test fails the run")
    }

    func testARunListsTheRequestsItsScriptsSentInItsConsoleMasked() async throws {
        try await setScripts(preRequest: """
        const res = await rq.sendRequest(rq.variables.replaceIn("{{baseUrl}}/side?key={{token}}"))
        console.log(res.text())
        """)

        let result = try await execute()

        let console = result["console"]?.arrayValue ?? []
        XCTAssertEqual(console.count, 2)
        XCTAssertEqual(console.first?["severity"], "info")
        let line = console.first?["text"]?.stringValue ?? ""
        XCTAssertTrue(line.hasPrefix("→ GET \(server.baseURL)/side?key=•••••• · 200 OK · "), line)
        XCTAssertEqual(console.last?["text"], "/side?key=•••••• auth=-")
        XCTAssertFalse(MCPJSON.text(.object(result)).contains("t0ken-secret"))
    }

    func testAPreviewRunsPreRequestScriptsOnlyWhenTheProjectIsTrusted() async throws {
        try await setScripts(preRequest: """
        rq.environment.set("seen", "1")
        rq.request.headers.upsert("X-Sig", "abc")
        console.log("previewing")
        """)
        fixture.workspace.updateProject(project) { $0.scriptTrust = .unknown }
        let untrusted = try await fixture.success("resolve_request", ["project": .string(project.description), "request": .string(request)])
        fixture.workspace.updateProject(project) { $0.scriptTrust = .trusted }
        let trusted = try await fixture.success("resolve_request", ["project": .string(project.description), "request": .string(request)])

        let untrustedHeaders = untrusted["request"]?["headers"]?.arrayValue ?? []
        XCTAssertFalse(untrustedHeaders.contains { $0["key"] == "X-Sig" })
        XCTAssertEqual(untrusted["scriptNotes"]?.arrayValue?.count, 1)
        XCTAssertTrue(trusted["request"]?["headers"]?.arrayValue?.contains { $0["key"] == "X-Sig" } ?? false)
        XCTAssertEqual(trusted["request"]?["scriptChangedHeaders"], ["x-sig"])
        XCTAssertEqual(trusted["console"]?.arrayValue?.first?["text"], "previewing")
        let defaultEnvironment = try fixture.document(project).defaultEnvironment.id
        XCTAssertTrue(fixture.library.currentValues.values(in: .environment(project, defaultEnvironment)).isEmpty, "A preview keeps nothing")
    }

    /// A past run is masked with what its scripts made secret too, while Reqling still holds those values; once it
    /// doesn't (after a relaunch), the response is left out rather than shown unmasked.
    func testAPastRunMasksItsScriptsSecretsOrWithholdsItsResponse() async throws {
        try await setScripts(preRequest: """
        rq.variables.set("sig", "s1gn-4ture", { secret: true })
        rq.request.headers.upsert("Authorization", "Sig " + rq.variables.get("sig"))
        """)
        let executed = try await execute()
        let run = try XCTUnwrap(executed["run"]?.stringValue)
        let arguments: [String: Value] = ["project": .string(project.description), "request": .string(request)]

        let last = try await fixture.success("get_last_response", arguments)
        let past = try await fixture.success("get_run", arguments.merging(["run": .string(run)]) { $1 })
        fixture.runner.flushHistory()
        let relaunched = RequestRunner(
            library: fixture.library,
            workspace: fixture.workspace,
            settings: fixture.settings,
            keychain: EmptyKeychain(),
            pkcs12Probe: TLSFixtures.probe,
            history: RunHistory(directory: fixture.storage.directory.file("Support/History"), settings: fixture.settings),
            userAgent: "Reqling/1.0",
            scripts: ScriptFixtures.realRunner
        )
        let requestID = try XCTUnwrap(RequestNodeID(string: request))
        let runID = try XCTUnwrap(RunID(string: run))
        let exchange = await relaunched.history.exchange(runID, for: requestID, in: project)
        let withheld = MCPExecutionTools.describeRecorded(
            try XCTUnwrap(exchange),
            mask: relaunched.maskingSecrets(in: project),
            runner: relaunched
        )

        for result in [last, past] {
            XCTAssertFalse(MCPJSON.text(.object(result)).contains("s1gn-4ture"))
            XCTAssertNotNil(result["response"]?["body"], "Masked, not left out, while Reqling holds the secret")
        }
        let text = MCPJSON.text(.object(withheld))
        XCTAssertFalse(text.contains("s1gn-4ture"))
        XCTAssertNil(withheld["response"]?["body"])
        XCTAssertNil(withheld["response"]?["headers"], "The server echoed it in a header too")
        XCTAssertEqual(withheld["response"]?["status"], 200)
        XCTAssertNotNil(withheld["withheld"])
    }
}

/// A stream phase's results as agents read them.
extension MCPExecutionToolsTests {
    func testAStreamPhaseReportsItsTalliesItemsAndWhatReachedNoHandler() throws {
        let report = ScriptReport(phases: [ScriptPhaseReport(
            phase: .stream,
            levels: [ScriptLevelReport(
                kind: .request,
                name: "Feed",
                tests: [ScriptTestReport(
                    name: "is JSON",
                    result: .failed,
                    message: "bad",
                    tally: ScriptTestCounts(passed: 3, failed: 1),
                    firstFailedItem: 4
                )],
                error: ScriptError(name: "TypeError", message: "x is undefined"),
                failedItem: 2,
                failedCallCount: 3
            )],
            stream: ScriptStreamReport(itemKind: .event, handledCount: 4, skippedCount: 2, failedItem: 9, isInterrupted: true)
        )])

        let described = MCPExecutionTools.scripts(report) { $0 }

        let test = try XCTUnwrap(described["tests"]?.arrayValue?.first)
        XCTAssertEqual(test["counts"], ["passed": 3, "failed": 1, "skipped": 0] as Value)
        XCTAssertEqual(test["firstFailedAt"], 4)
        XCTAssertEqual(described["testSummary"], ["passed": 0, "failed": 1, "skipped": 0] as Value, "A test counts once")
        let error = try XCTUnwrap(described["scriptErrors"]?.arrayValue?.first)
        XCTAssertEqual(error["item"], 2)
        XCTAssertEqual(error["count"], 3)
        XCTAssertEqual(described["streamScripts"], ["items": .string("events"), "handled": 4, "skipped": 2, "stoppedAt": 9] as Value)
        XCTAssertEqual(described["scriptNotes"], ["Reqling quit before the stream scripts finished."])
    }
}
