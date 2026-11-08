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

    func testAStreamScriptsResultsReadAsOneRowPerTestWithTheItemTheyFailedOn() throws {
        let stream = ScriptPhaseReport(
            phase: .stream,
            levels: [ScriptLevelReport(
                kind: .request,
                name: "Feed",
                tests: [
                    ScriptTestReport(
                        name: "is JSON",
                        result: .failed,
                        message: "bad",
                        tally: ScriptTestCounts(passed: 498, failed: 2),
                        firstFailedItem: 17
                    ),
                    ScriptTestReport(name: "once", result: .passed, tally: ScriptTestCounts(passed: 1)),
                    ScriptTestReport(name: "quiet", result: .failed, tally: ScriptTestCounts(failed: 1), firstFailedItem: 3)
                ],
                error: ScriptError(name: "TypeError", message: "x is undefined", line: 4),
                failedItem: 2,
                failedCallCount: 3
            )],
            stream: ScriptStreamReport(itemKind: .message, skippedCount: 12, droppedCount: 1, failedItem: 40)
        )

        let scripts = ScriptReportPresentation(ScriptReport(phases: [stream]))

        let group = try XCTUnwrap(scripts.groups.first)
        XCTAssertEqual(group.title, "Stream · Request")
        XCTAssertEqual(group.tests.map(\.tally), ["Passed 498 of 500", nil, nil], "Only a test run more than once")
        XCTAssertEqual(group.tests.map(\.message), ["Message 17: bad", nil, "Failed first at message 3"])
        XCTAssertEqual(group.error, "Message 2: TypeError: x is undefined (line 4)")
        XCTAssertEqual(group.errorDetail, "Threw for 3 messages")
        XCTAssertEqual(scripts.tabTitle, "Tests 1/3", "Each row counts once")
        XCTAssertEqual(scripts.notes, [
            "Stream scripts fell behind, so 1 message reached no handler.",
            "The stream scripts stopped at message 40, so 12 later messages reached no handler."
        ])
        let ended = ScriptStreamReport(itemKind: .event, skippedCount: 1)
        XCTAssertEqual(ScriptReportPresentation(ScriptReport(phases: [ScriptPhaseReport(phase: .stream, stream: ended)])).notes, [
            "The stream ended before its handlers caught up, so 1 event reached no handler."
        ])
    }

    /// A live stream's report changes with each call; its console, laid out once, stays while it stays the same.
    func testTheCacheKeepsTheConsoleWhileOnlyResultsChange() throws {
        var cache = ScriptReportCache()
        var report = ScriptReport(phases: [ScriptPhaseReport(
            phase: .stream,
            levels: [ScriptLevelReport(kind: .request, name: "Feed")],
            console: [ScriptConsoleEntry(level: 0, severity: .log, text: "open")],
            stream: ScriptStreamReport(itemKind: .event)
        )])

        let first = try XCTUnwrap(cache.presentation(of: report)?.console)
        report.phases[0].stream?.handledCount = 1
        let second = try XCTUnwrap(cache.presentation(of: report)?.console)
        report.phases[0].console.append(ScriptConsoleEntry(level: 0, severity: .log, text: "event"))
        let third = try XCTUnwrap(cache.presentation(of: report)?.console)

        XCTAssertEqual(first.id, second.id)
        XCTAssertNotEqual(second.id, third.id)
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
