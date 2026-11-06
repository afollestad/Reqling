import ReqlingKit
import ReqlingScriptProtocol
import SwiftUI
import XCTest

@testable import Reqling

/// What a run's scripts did: the Tests tab, the status bar's tests, a failed pre-request script, a run without its
/// scripts, and test counts in the history.
extension SnapshotTests {
    private static let scriptResultsSize = CGSize(width: 820, height: 380)
    private static let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

    private static func testsReport(failing: Bool) -> ScriptReport {
        ScriptReport(phases: [
            ScriptPhaseReport(
                phase: .preRequest,
                levels: [ScriptLevelReport(kind: .project, name: "Sample API")],
                console: [ScriptConsoleEntry(level: 0, severity: .log, text: "Signed at 1700000000")]
            ),
            ScriptPhaseReport(
                phase: .postResponse,
                levels: [ScriptLevelReport(kind: .request, name: "List users", tests: [
                    ScriptTestReport(name: "returns users", result: .passed),
                    ScriptTestReport(name: "pages", result: .passed),
                    failing
                        ? ScriptTestReport(name: "is quick", result: .failed, message: "expected 142 to be below 100")
                        : ScriptTestReport(name: "is quick", result: .passed)
                ])],
                console: [ScriptConsoleEntry(level: 0, severity: .log, text: "{\n  \"users\": 2,\n  \"next\": \"page2\"\n}")]
            )
        ])
    }

    private static var usersResponse: HTTPResponseRecord {
        HTTPResponseRecord(
            statusCode: 200,
            headers: [KeyValuePair(key: "Content-Type", value: "application/json")],
            body: Data(#"{"users":[{"id":1},{"id":2}],"next":"page2"}"#.utf8),
            url: "https://api.example.com/users",
            startedAt: startedAt,
            duration: 0.142
        )
    }

    func testResponseTestsTab() throws {
        let project = try SnapshotProject.make(in: fixture)
        project.cacheExchange(.response(Self.usersResponse), for: project.listUsers, scriptReport: Self.testsReport(failing: true), in: fixture)
        let editor = try project.editor(project.listUsers, in: fixture)
        editor.response.tab = .tests

        assertBothAppearances(ResponseView(response: editor.response, model: fixture.model), size: Self.scriptResultsSize)
    }

    func testResponseStatusWithPassingTests() {
        let scripts = ScriptReportPresentation(Self.testsReport(failing: false))
        let exchange = RequestExchange(
            projectID: ProjectID(),
            requestID: RequestNodeID(),
            startedAt: Self.startedAt,
            environmentName: "Default",
            request: nil,
            outcome: .response(Self.usersResponse)
        )

        assertBothAppearances(ResponseStatusBar(exchange: exchange, isSending: false, scripts: scripts), size: CGSize(width: 820, height: 40))
    }

    /// The pre-request script that stopped the run, with what it printed first.
    func testResponsePreRequestScriptFailure() throws {
        let project = try SnapshotProject.make(in: fixture)
        let report = ScriptReport(phases: [ScriptPhaseReport(
            phase: .preRequest,
            levels: [ScriptLevelReport(
                kind: .folder,
                name: "Admin",
                error: ScriptError(name: "TypeError", message: "Cannot read properties of undefined (reading 'token')", line: 3)
            )],
            console: [ScriptConsoleEntry(level: 0, severity: .warn, text: "No session yet; run Login first.")]
        )])
        project.cacheExchange(
            .failure(RunFailure(kind: .script, message: report.phases[0].failureSummary ?? "")),
            for: project.listUsers,
            scriptReport: report,
            in: fixture
        )
        let editor = try project.editor(project.listUsers, in: fixture)

        assertBothAppearances(ResponseView(response: editor.response, model: fixture.model), size: Self.scriptResultsSize)
    }

    /// A run in a project whose scripts aren't trusted here says so, with a way to trust them.
    func testResponseScriptsOffNotice() throws {
        let project = try SnapshotProject.make(in: fixture)
        let report = ScriptReport(phases: [ScriptPhaseReport(phase: .preRequest, skipReason: .untrusted)])
        project.cacheExchange(.response(Self.usersResponse), for: project.listUsers, scriptReport: report, in: fixture)
        let editor = try project.editor(project.listUsers, in: fixture)

        assertBothAppearances(ResponseView(response: editor.response, model: fixture.model), size: CGSize(width: 820, height: 260))
    }

    /// Headers and query parameters a pre-request script set are marked as its.
    func testResponseRequestTabMarksScriptChanges() throws {
        let project = try SnapshotProject.make(in: fixture)
        let sent = ResolvedHTTPRequest(
            method: "GET",
            url: "https://api.example.com/users?page=1&ts=1700000000",
            headers: [
                KeyValuePair(key: "Accept", value: "application/json"),
                KeyValuePair(key: "X-Signature", value: "••••••"),
                KeyValuePair(key: "User-Agent", value: "Reqling/1.0")
            ],
            bodyPreview: nil,
            bodyByteCount: 0,
            scriptChangedHeaders: ["x-signature"],
            scriptChangedQuery: ["ts"]
        )
        project.cacheExchange(.response(Self.usersResponse), for: project.listUsers, sent: sent, in: fixture)
        let editor = try project.editor(project.listUsers, in: fixture)
        editor.response.tab = .request

        assertBothAppearances(ResponseView(response: editor.response, model: fixture.model), size: CGSize(width: 820, height: 300))
    }

    func testGRPCResponseTestsTab() throws {
        let project = try SnapshotProject.make(in: fixture)
        let request = try GRPCFixtures.addRequest(named: "Greet", spec: GRPCFixtures.descriptorSetSpec(), to: project.id, in: fixture)
        let record = GRPCCallRecord(
            target: "greeter.example.com:443",
            method: "\(GRPCFixtures.service)/SayHello",
            kind: .unary,
            sentMetadata: [KeyValuePair(key: "x-signature", value: "••••••")],
            scriptChangedMetadata: ["x-signature"],
            events: [GRPCMessageEvent(direction: .received, offset: 0.02, json: "{\n  \"message\": \"Hello, Ada\"\n}", byteCount: 12, sequence: 0)],
            status: GRPCStatusRecord(code: 0, name: "OK", message: ""),
            duration: 0.021
        )
        let report = ScriptReport(phases: [ScriptPhaseReport(
            phase: .postResponse,
            levels: [ScriptLevelReport(kind: .request, name: "Greet", tests: [
                ScriptTestReport(name: "is OK", result: .passed),
                ScriptTestReport(name: "greets Ada", result: .passed)
            ])]
        )])
        project.cacheExchange(.grpc(record), for: request, scriptReport: report, in: fixture)
        fixture.model.selection = .node(project.id, request)
        let response = try XCTUnwrap(fixture.model.editor?.asGRPC?.response)
        response.tab = .tests

        assertBothAppearances(GRPCResponseView(response: response, model: fixture.model), size: CGSize(width: 820, height: 300))
    }

    func testRunHistoryWithTests() throws {
        let project = try SnapshotProject.make(in: fixture)
        let base: TimeInterval = 1_700_000_000
        for (offset, failing) in [(-300.0, false), (0.0, true)] {
            _ = project.storeRun(
                .response(Self.usersResponse),
                for: project.listUsers,
                at: base + offset,
                scriptReport: Self.testsReport(failing: failing),
                in: fixture
            )
        }
        let history = RunHistoryViewModel(projectID: project.id, requestID: project.listUsers, app: fixture.model)

        assertBothAppearances(RunHistoryInspector(history: history), size: CGSize(width: 280, height: 220))
    }
}
