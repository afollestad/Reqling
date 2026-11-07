import Foundation
import ReqlingKit
import XCTest

@testable import Reqling

/// Running a folder or project from the window: what a command targets, the sheet's settings, its trust question,
/// data files, and the sidebar's "Failed in Last Run" filter. Requests aim at a closed loopback port, so each fails at
/// once without leaving the Mac.
@MainActor
extension AppModelTests {
    struct BatchFixture {
        let project: ProjectID
        let folder: RequestNodeID
        let nested: RequestNodeID
        let top: RequestNodeID
        let first: RequestNodeID
        let inner: RequestNodeID
        let last: RequestNodeID
    }

    /// A top-level request, then folder A holding one request, folder B (with one), and another request.
    func batchFixture() throws -> BatchFixture {
        let project = try makeProject()
        let top = RequestItem(name: "Top", kind: .http(HTTPRequestSpec(url: "http://127.0.0.1:1/top")))
        let first = RequestItem(name: "First", kind: .http(HTTPRequestSpec(url: "http://127.0.0.1:1/first")))
        let inner = RequestItem(name: "Inner", kind: .http(HTTPRequestSpec(url: "http://127.0.0.1:1/inner")))
        let last = RequestItem(name: "Last", kind: .http(HTTPRequestSpec(url: "http://127.0.0.1:1/last")))
        let nested = RequestFolder(name: "B", children: [.request(inner)])
        let folder = RequestFolder(name: "A", children: [.request(first), .folder(nested), .request(last)])
        try fixture.library.mutate(project) { document in
            try document.insert(.request(top), into: nil)
            try document.insert(.folder(folder), into: nil)
        }
        return BatchFixture(project: project, folder: folder.id, nested: nested.id, top: top.id, first: first.id, inner: inner.id, last: last.id)
    }

    func testARunTargetsTheSelectedFolderOrProjectOrASelectedRequestsFolder() throws {
        let batch = try batchFixture()
        let project = BatchRunScope(projectID: batch.project, folderID: nil)
        let folder = BatchRunScope(projectID: batch.project, folderID: batch.folder)

        XCTAssertEqual(model.batchTarget(for: .project(batch.project)), project)
        XCTAssertEqual(model.batchTarget(for: .node(batch.project, batch.folder)), folder)
        XCTAssertEqual(model.batchTarget(for: .node(batch.project, batch.first)), folder)
        XCTAssertEqual(model.batchTarget(for: .node(batch.project, batch.top)), project)
        XCTAssertEqual(model.batchRunTitle(for: folder), "Run Folder…")
        XCTAssertEqual(model.batchRunTitle(for: project), "Run Project…")
        XCTAssertTrue(model.canRunBatch(folder))
        try fixture.library.mutate(batch.project) { _ = try $0.removeNode(batch.inner) }
        XCTAssertFalse(model.canRunBatch(BatchRunScope(projectID: batch.project, folderID: batch.nested)), "An empty folder has nothing to run")
    }

    func testTheSheetGroupsRequestsUnderTheirFoldersInSidebarOrder() async throws {
        let batch = try batchFixture()
        let setup = BatchRunSetupModel(scope: BatchRunScope(projectID: batch.project, folderID: nil), app: model)

        await setup.load()

        XCTAssertEqual(setup.rows.map(\.name), ["Top", "First", "Inner", "Last"])
        XCTAssertEqual(setup.groups.map(\.title), [nil, "A", "A / B", "A"], "A subfolder splits its folder's requests")
        XCTAssertEqual(Set(setup.groups.map(\.id)).count, 4, "Each group is its own row in the form")
        XCTAssertEqual(setup.environmentID, model.activeEnvironmentID(for: batch.project))
        XCTAssertEqual(setup.note, "4 of 4 requests")
    }

    func testRunningRemembersTheSheetsSettingsAndClosesIt() async throws {
        let batch = try batchFixture()
        let scope = BatchRunScope(projectID: batch.project, folderID: batch.folder)
        model.openBatchRun(scope)
        let setup = BatchRunSetupModel(scope: scope, app: model)
        await setup.load()
        setup.rows[0].isIncluded = false
        setup.count = 2
        setup.stopsOnFailure = true

        let started = await setup.run()
        await waitUntil("the run ends") { !self.model.batches.isRunning }
        let reopened = BatchRunSetupModel(scope: scope, app: model)
        await reopened.load()

        XCTAssertTrue(started)
        XCTAssertNil(model.sheet)
        XCTAssertEqual(model.batches.run?.plan.requests, [batch.inner, batch.last])
        XCTAssertEqual(model.batches.run?.state, .ended(.stoppedOnFailure), "A refused connection fails the first step")
        XCTAssertEqual(reopened.count, 2)
        XCTAssertTrue(reopened.stopsOnFailure)
        XCTAssertEqual(reopened.rows.map(\.isIncluded), [false, true, true])
    }

    func testADismissedTrustQuestionLeavesTheSheetOpen() async throws {
        let batch = try batchFixture()
        try fixture.library.mutate(batch.project) { try $0.updateRequest(batch.first) { $0.scripts.preRequest = "rq.variables.set('a', '1')" } }
        fixture.component.workspaceState.updateProject(batch.project) { $0.scriptTrust = .unknown }
        let scope = BatchRunScope(projectID: batch.project, folderID: batch.folder)
        model.openBatchRun(scope)
        let setup = BatchRunSetupModel(scope: scope, app: model)
        await setup.load()

        let run = Task { await setup.run() }
        await waitUntil("the question shows") { self.model.scriptTrustPending != nil }
        XCTAssertEqual(model.scriptTrustPending?.files, ["A/First.pre.js"])
        XCTAssertFalse(setup.isRunEnabled)
        XCTAssertEqual(setup.note, "3 of 3 requests", "Its own run isn't another one")
        model.answerScriptTrust(nil)
        let started = await run.value

        XCTAssertFalse(started)
        XCTAssertEqual(model.sheet, .batchRun(scope))
        XCTAssertFalse(model.batches.isRunning)
        XCTAssertNil(model.batches.run)
    }

    func testADataFileIsReadAndDescribedOrItsProblemShown() async throws {
        let batch = try batchFixture()
        let directory = FileManager.default.temporaryDirectory.appending(path: "batch-data-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let good = directory.appending(path: "users.csv")
        let bad = directory.appending(path: "bad.json")
        try Data("email,name\nada@acme.dev,Ada\ngrace@acme.dev,Grace\n".utf8).write(to: good)
        try Data(#"{"email": "x"}"#.utf8).write(to: bad)
        fixture.system.filesToChoose = [good, bad]
        let setup = BatchRunSetupModel(scope: BatchRunScope(projectID: batch.project, folderID: nil), app: model)
        await setup.load()

        await setup.chooseDataFile()
        let read = setup.data
        let enabled = setup.isRunEnabled
        await setup.chooseDataFile()

        XCTAssertEqual(read, .read(rows: 2, columns: ["email", "name"]))
        XCTAssertTrue(enabled)
        XCTAssertEqual(setup.iterations, .dataFile)
        XCTAssertEqual(setup.data, .failed("The JSON must be an array of objects, one per iteration."))
        XCTAssertFalse(setup.isRunEnabled)
    }

    func testFailedInLastRunNarrowsTheSidebarUntilTheRunIsDismissed() async throws {
        let batch = try batchFixture()
        let scope = BatchRunScope(projectID: batch.project, folderID: batch.nested)
        var settings = model.batchRunSettings(for: scope)
        settings.count = 1

        let started = await model.beginBatchRun(scope, settings: settings)
        await waitUntil("the run ends") { !self.model.batches.isRunning }
        model.sidebar.showsLastRunFailures = true
        let narrowed = model.sidebar.sections.first?.items
        model.dismissBatchRun()

        XCTAssertTrue(started)
        XCTAssertEqual(narrowed?.map(\.name), ["A"])
        XCTAssertEqual(narrowed.flatMap { Self.requestNames(in: $0) }, ["Inner"])
        XCTAssertFalse(model.sidebar.showsLastRunFailures)
        XCTAssertFalse(model.batches.hasReport)
    }

    private static func requestNames(in nodes: [RequestNode]) -> [String] {
        nodes.flatMap { node -> [String] in
            switch node {
            case .request(let request): [request.name]
            case .folder(let folder): requestNames(in: folder.children)
            }
        }
    }
}
