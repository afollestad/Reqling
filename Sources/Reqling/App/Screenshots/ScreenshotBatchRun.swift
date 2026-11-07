#if DEBUG
import Foundation
import ReqlingKit

/// The `batch` scene's run of the Users folder, shown as finished without running anything: three iterations from a
/// data file, Create user failing one of its tests in the second. Every value is fixed, as the scene's alt text
/// describes it.
@MainActor
enum ScreenshotBatchRun {
    static func show(_ folder: RequestNodeID, in project: ProjectID, component: AppComponent) {
        guard let document = component.projectLibrary.document(project) else {
            return
        }
        let requests = document.requests(inFolder: folder)
        let rows = ["ada", "grace", "linus"].map { ["email": "\($0)@acme.dev"] }
        let plan = BatchRunPlan(
            scope: BatchRunScope(projectID: project, folderID: folder),
            requests: requests.map(\.id),
            iterations: .data(source: .inline, rows: rows)
        )
        var run = BatchRun(
            plan: plan,
            scopeName: document.folder(folder)?.name ?? "",
            environmentID: document.defaultEnvironment.id,
            environmentName: document.defaultEnvironment.name,
            state: .ended(.finished),
            iteration: rows.count - 1
        )
        for request in requests {
            var tally = BatchRequestTally(counts: BatchStepCounts(passed: rows.count))
            switch request.name {
            case "Get user":
                tally.tests = ScriptTestCounts(passed: 6)
            case "Create user":
                tally = BatchRequestTally(
                    counts: BatchStepCounts(passed: 2, failed: 1),
                    tests: ScriptTestCounts(passed: 5, failed: 1),
                    failedIterations: [1]
                )
                run.notableSteps = [BatchRunStep(
                    iteration: 1,
                    requestID: request.id,
                    requestName: request.name,
                    summary: nil,
                    result: .failed,
                    message: "A test failed: expected 201 to equal 409"
                )]
            default:
                break
            }
            run.tallies[request.id] = tally
            run.counts.passed += tally.counts.passed
            run.counts.failed += tally.counts.failed
        }
        component.batchRunner.show(run)
    }
}
#endif
