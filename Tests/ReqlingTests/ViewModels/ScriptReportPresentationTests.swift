import Foundation
import ReqlingKit
import ReqlingScriptProtocol
import XCTest

@testable import Reqling

/// How a run's script report reads in the Tests tab, the status bar, and a failed run.
@MainActor
final class ScriptReportPresentationTests: XCTestCase {
    private static let report = ScriptReport(phases: [
        ScriptPhaseReport(
            phase: .preRequest,
            levels: [
                ScriptLevelReport(kind: .project, name: "API"),
                ScriptLevelReport(kind: .folder, name: "Users", tests: [ScriptTestReport(name: "has a token", result: .passed)])
            ],
            console: [ScriptConsoleEntry(level: 1, severity: .log, text: "signing")]
        ),
        ScriptPhaseReport(
            phase: .postResponse,
            levels: [ScriptLevelReport(
                kind: .request,
                name: "Me",
                tests: [
                    ScriptTestReport(name: "is OK", result: .passed),
                    ScriptTestReport(name: "is quick", result: .failed, message: "expected 900 to be below 500"),
                    ScriptTestReport(name: "later", result: .skipped)
                ],
                error: ScriptError(name: "TypeError", message: "x is undefined", line: 4)
            )],
            console: [ScriptConsoleEntry(level: 0, severity: .warn, text: "slow")]
        )
    ])

    func testResultsGroupByPhaseAndScriptAndTheConsoleReadsAsOneText() throws {
        let scripts = ScriptReportPresentation(Self.report)

        XCTAssertEqual(
            scripts.groups.map(\.title),
            ["Pre-request · Folder “Users”", "Post-response · Request"],
            "A script with nothing to say has no group"
        )
        XCTAssertEqual(scripts.groups.last?.error, "TypeError: x is undefined (line 4)")
        XCTAssertEqual(scripts.groups.last?.tests.map(\.result), [.passed, .failed, .skipped])
        XCTAssertEqual(scripts.tabTitle, "Tests 2/3", "Passed of those that ran; a skipped test did neither")
        XCTAssertTrue(scripts.hasFailures)
        let console = try XCTUnwrap(scripts.console)
        XCTAssertEqual(String(bytes: console.bytes, encoding: .utf8), "// Pre-request\nsigning\n// Post-response\n[warn] slow")
    }

    func testScriptsThatDidntRunSayWhyOnce() {
        let untrusted = ScriptReport(phases: [
            ScriptPhaseReport(phase: .preRequest, skipReason: .untrusted),
            ScriptPhaseReport(phase: .postResponse, skipReason: .untrusted)
        ])

        let scripts = ScriptReportPresentation(untrusted)

        XCTAssertEqual(scripts.notes, [ScriptSkipReason.untrusted.message])
        XCTAssertTrue(scripts.isUntrusted)
        XCTAssertFalse(scripts.hasFailures)
        XCTAssertEqual(scripts.tabTitle, "Tests")
        XCTAssertNil(scripts.console)
    }

    func testTheTestsTabShowsOnlyForARunWithScripts() throws {
        let fixture = AppFixture()
        defer { fixture.tearDown() }
        fixture.model.createProject(named: "Responses")
        let project = try XCTUnwrap(fixture.model.selection?.projectID)
        fixture.model.newRequest()
        let response = try XCTUnwrap(fixture.model.editor?.asHTTP?.response)
        let runner = fixture.component.requestRunner
        func publish(_ report: ScriptReport?) {
            runner.forget(response.requestID, in: project)
            RunHistoryStore(directory: fixture.profile.historyDirectory).save(RequestExchange(
                projectID: project,
                requestID: response.requestID,
                startedAt: Date(timeIntervalSince1970: 1_700_000_000),
                environmentName: nil,
                request: nil,
                outcome: .failure(RunFailure(kind: .script, message: "The pre-request script failed.")),
                scriptReport: report
            ))
            _ = runner.exchange(for: response.requestID, in: project)
        }

        publish(Self.report)
        response.shownTab = .tests
        XCTAssertEqual(response.visibleTabs.last, .tests)
        XCTAssertEqual(response.shownTab, .tests)
        publish(nil)

        XCTAssertFalse(response.visibleTabs.contains(.tests))
        XCTAssertEqual(response.shownTab, .body, "A hidden tab shows the first")
        XCTAssertEqual(response.tab, .tests, "Picking Tests survives a run without scripts")
    }
}
