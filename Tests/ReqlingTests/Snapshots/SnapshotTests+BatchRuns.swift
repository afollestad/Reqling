import ReqlingKit
import SwiftUI
import XCTest

@testable import Reqling

/// Running a folder or project: the run sheet, and the sidebar's badges and bar.
extension SnapshotTests {
    /// Repeating three times, one request left out under its folder's header.
    func testBatchRunSheetRepeating() async throws {
        let project = try SnapshotProject.make(in: fixture)
        let setup = BatchRunSetupModel(scope: BatchRunScope(projectID: project.id, folderID: nil), app: fixture.model)
        await setup.load()
        setup.count = 3
        setup.rows[1].isIncluded = false

        assertBothAppearances(BatchRunSheet(setup: setup), size: CGSize(width: 560, height: 620))
    }

    /// A data file's rows and columns, and the stream limit set.
    func testBatchRunSheetWithADataFile() async throws {
        let project = try SnapshotProject.make(in: fixture)
        let directory = FileManager.default.temporaryDirectory.appending(path: "snapshot-data-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "users.csv")
        try Data("email,name\nada@acme.dev,Ada\ngrace@acme.dev,Grace\n".utf8).write(to: file)
        fixture.system.fileToChoose = file
        let setup = BatchRunSetupModel(scope: BatchRunScope(projectID: project.id, folderID: nil), app: fixture.model)
        await setup.load()
        await setup.chooseDataFile()
        setup.streamSeconds = 30
        setup.stopsOnFailure = true

        assertBothAppearances(BatchRunSheet(setup: setup), size: CGSize(width: 560, height: 620))
    }

    /// A finished run: a pass, a failure in one iteration with its tests, the folder rolled up, and the bar's actions.
    func testBatchRunSidebarAfterARun() throws {
        let project = try SnapshotProject.make(in: fixture)
        fixture.model.batches.show(try Self.batchRun(of: project, in: fixture, state: .ended(.finished)))

        assertBothAppearances(SidebarView(model: fixture.model), size: CGSize(width: 280, height: 420))
    }

    /// A run between steps, with Stop in its bar.
    func testBatchRunSidebarWhileRunning() throws {
        let project = try SnapshotProject.make(in: fixture)
        fixture.model.batches.show(try Self.batchRun(of: project, in: fixture, state: .running))

        assertBothAppearances(SidebarView(model: fixture.model), size: CGSize(width: 280, height: 420))
    }

    /// Three iterations of the whole project: List users passing its tests, Create user failing one in the second
    /// iteration, and Admin's Purge cache passing.
    private static func batchRun(of project: SnapshotProject, in fixture: AppFixture, state: BatchRun.State) throws -> BatchRun {
        let document = try XCTUnwrap(fixture.library.document(project.id))
        let requests = document.requests(inFolder: nil).map(\.id)
        let plan = BatchRunPlan(scope: BatchRunScope(projectID: project.id, folderID: nil), requests: requests, iterations: .count(3))
        var run = BatchRun(
            plan: plan,
            scopeName: document.name,
            environmentID: document.defaultEnvironment.id,
            environmentName: "Default",
            state: state,
            iteration: state == .running ? 1 : 2
        )
        let isRunning = state == .running
        run.tallies = [
            project.listUsers: BatchRequestTally(
                counts: BatchStepCounts(passed: isRunning ? 2 : 3),
                tests: ScriptTestCounts(passed: isRunning ? 4 : 6)
            ),
            project.createUser: BatchRequestTally(
                counts: BatchStepCounts(passed: 1, failed: 1),
                tests: ScriptTestCounts(passed: 3, failed: 1),
                failedIterations: [1]
            )
        ]
        if !isRunning, let purge = requests.last {
            run.tallies[purge] = BatchRequestTally(counts: BatchStepCounts(passed: 3))
            run.tallies[project.createUser]?.counts.passed = 2
        }
        for tally in run.tallies.values {
            run.counts.passed += tally.counts.passed
            run.counts.failed += tally.counts.failed
        }
        return run
    }
}
