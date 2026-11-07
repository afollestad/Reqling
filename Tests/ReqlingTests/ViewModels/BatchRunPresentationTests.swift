import Foundation
import ReqlingKit
import XCTest

@testable import Reqling

/// What a row's badge and the sidebar's bar say about a folder or project run.
final class BatchRunPresentationTests: XCTestCase {
    func testABadgeCountsTestsElseIterationsAndNamesTheFailingIterations() throws {
        let failing = BatchItemStatus(phase: .failed, iterationsRun: 200, iterationsPassed: 196, failedIterations: [1, 4, 8, 20, 30, 199])
        let tested = BatchItemStatus(phase: .passed, tests: ScriptTestCounts(passed: 5, failed: 1), iterationsRun: 3, iterationsPassed: 3)

        let request = try XCTUnwrap(BatchBadgePresentation(failing, isRunGoing: false, isFolder: false))
        let withTests = try XCTUnwrap(BatchBadgePresentation(tested, isRunGoing: false, isFolder: false))

        XCTAssertEqual(request.count, "196/200")
        XCTAssertEqual(request.description, "Failed in iterations 2, 5, 9, and 3 more of 200.")
        XCTAssertEqual(withTests.count, "5/6")
        XCTAssertEqual(withTests.description, "Passed in all 3 iterations. 5 of 6 tests passed.")
    }

    func testARowTheRunNeverReachedShowsNothingOnceItEnds() {
        let pending = BatchItemStatus()

        XCTAssertEqual(BatchBadgePresentation(pending, isRunGoing: true, isFolder: false)?.symbol, .image("circle.dotted"))
        XCTAssertNil(BatchBadgePresentation(pending, isRunGoing: false, isFolder: false))
    }

    func testTheBarSaysWhereARunIsAndHowOneEnded() {
        let plan = BatchRunPlan(scope: BatchRunScope(projectID: ProjectID(), folderID: nil), requests: [], iterations: .count(3))
        var run = BatchRun(plan: plan, scopeName: "Auth", environmentID: EnvironmentID(), environmentName: "Staging", iteration: 1)
        run.counts = BatchStepCounts(passed: 5, failed: 1, interrupted: 2)

        let running = BatchBarPresentation(run: run, currentName: "Login")
        run.state = .ended(.stoppedOnFailure)
        let ended = BatchBarPresentation(run: run, currentName: nil)

        XCTAssertEqual(running.title, "Running Auth")
        XCTAssertEqual(running.progress, "Iteration 2 of 3 · Login")
        XCTAssertEqual(running.counts, "5 passed · 1 failed · 2 interrupted")
        XCTAssertEqual(ended.title, "Ran Auth")
        XCTAssertEqual(ended.progress, "Stopped at a failure")
        XCTAssertEqual(ended.announcement, "Ran Auth: 5 passed · 1 failed · 2 interrupted. Stopped at a failure.")
    }
}
