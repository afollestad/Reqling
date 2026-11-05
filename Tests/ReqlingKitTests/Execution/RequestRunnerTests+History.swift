import Foundation
@testable import ReqlingKit
import XCTest

/// What the runner records into the history, and how clearing, deleting, and moving requests keep it in step.
extension RequestRunnerTests {
    func testEveryRunIsKeptNewestFirstWithTheSpecAndEnvironmentItRan() async throws {
        let server = try await echoServer()
        let fixtureProject = try makeProject(base: server.baseURL)
        let project = fixtureProject.id
        let request = fixtureProject.request
        let document = try XCTUnwrap(fixture.library.document(project))
        let runner = makeRunner()

        let first = await runner.run(request, in: project)
        let second = await runner.run(request, in: project, options: RunOptions(environmentID: fixtureProject.staging))

        XCTAssertEqual(runner.history.runs(for: request, in: project).map(\.id), [second.id, first.id])
        XCTAssertEqual(first.spec, document.request(request)?.kind)
        XCTAssertEqual(first.environmentID, document.defaultEnvironment.id)
        XCTAssertEqual(second.environmentID, fixtureProject.staging)
        XCTAssertEqual(second.environmentName, "Staging")
        runner.flushHistory()
        let relaunched = makeRunner()
        XCTAssertEqual(relaunched.history.runs(for: request, in: project).map(\.id), [second.id, first.id])
        let stored = await relaunched.history.exchange(first.id, for: request, in: project)
        XCTAssertEqual(stored.flatMap(body), "GET /default -")
        XCTAssertEqual(stored?.spec, first.spec)
    }

    /// A one-run spec is what the run records, so running it again sends what that run sent.
    func testARunRecordsItsOneRunSpecSoItCanRunAgain() async throws {
        let server = try await echoServer()
        let fixtureProject = try makeProject(base: server.baseURL)
        let project = fixtureProject.id
        let request = fixtureProject.request
        var patched = try XCTUnwrap(fixture.library.document(project)?.request(request)?.kind.httpSpec)
        patched.headers.append(KeyValuePair(key: "X-Extra", value: "patched"))
        let runner = makeRunner()
        let past = await runner.run(request, in: project, options: RunOptions(environmentID: fixtureProject.staging, spec: .http(patched)))

        let again = await runner.run(request, in: project, options: RunOptions(environmentID: past.environmentID, spec: past.spec))

        XCTAssertEqual(past.spec, .http(patched))
        XCTAssertEqual(body(again), "GET /staging patched")
        XCTAssertEqual(runner.history.runs(for: request, in: project).count, 2)
    }

    func testClearingHistoryLeavesNoRunsNorOutcome() async throws {
        let server = try await echoServer()
        let fixtureProject = try makeProject(base: server.baseURL)
        let project = fixtureProject.id
        let request = fixtureProject.request
        let runner = makeRunner()
        _ = await runner.run(request, in: project)

        runner.clearHistory(for: request, in: project)

        XCTAssertNil(runner.exchange(for: request, in: project))
        XCTAssertEqual(runner.outcome(for: request, in: project), .notSent)
        XCTAssertEqual(runner.history.runs(for: request, in: project), [])

        _ = await runner.run(request, in: project)
        runner.clearHistory(in: project)
        XCTAssertNil(runner.exchange(for: request, in: project))

        _ = await runner.run(request, in: project)
        runner.clearAllHistory()
        runner.flushHistory()
        XCTAssertNil(makeRunner().exchange(for: request, in: project))
    }

    func testAnAdHocRunThatCannotBePreparedIsNotRecorded() async throws {
        let project = try makeProject(base: "http://127.0.0.1:1").id
        let item = RequestItem.http("Ad hoc", url: "{{missing}}/x")
        let runner = makeRunner()

        let exchange = await runner.runUnsaved(item, in: project)

        XCTAssertEqual(exchange.failure?.kind, .invalidRequest)
        XCTAssertTrue(runner.latest.isEmpty)
        XCTAssertEqual(runner.history.runs(for: item.id, in: project), [])
    }

    func testDeletingAFolderDropsTheHistoryOfEveryRequestInside() throws {
        let project = try fixture.library.createProject(named: "Tree")
        let inside = RequestItem.http("Inside")
        let outside = RequestItem.http("Outside")
        let folder = RequestFolder(name: "Folder", children: [.request(inside)])
        try fixture.library.mutate(project) { document in
            try document.insert(.folder(folder), into: nil)
            try document.insert(.request(outside), into: nil)
        }
        seedRun(for: inside.id, in: project)
        seedRun(for: outside.id, in: project)
        let runner = makeRunner()

        try makeLifecycle(runner).deleteNode(folder.id, in: project)

        XCTAssertEqual(runner.history.runs(for: inside.id, in: project), [])
        XCTAssertEqual(runner.history.runs(for: outside.id, in: project).count, 1)
    }

    /// A request keeps its history into another project when it keeps its ID there, and starts a copy's afresh.
    func testMovingARequestBetweenProjectsCarriesItsHistoryUnlessItIsCopied() throws {
        let source = try fixture.library.createProject(named: "Source")
        let destination = try fixture.library.createProject(named: "Destination")
        let taken = try fixture.library.createProject(named: "Taken")
        let request = RequestItem.http("Moving")
        try fixture.library.mutate(source) { try $0.insert(.request(request), into: nil) }
        try fixture.library.mutate(taken) { try $0.insert(.request(RequestItem(id: request.id, name: "Same ID", kind: request.kind)), into: nil) }
        let run = seedRun(for: request.id, in: source)
        let runner = makeRunner()
        let lifecycle = makeLifecycle(runner)

        let moved = try lifecycle.moveNode(request.id, from: source, to: destination, into: nil)

        XCTAssertEqual(moved.nodeID, request.id)
        XCTAssertEqual(runner.history.runs(for: request.id, in: source), [])
        XCTAssertEqual(runner.history.runs(for: request.id, in: destination).map(\.id), [run.id])
        XCTAssertEqual(runner.outcome(for: request.id, in: destination), .succeeded)
        XCTAssertEqual(runner.exchange(for: request.id, in: destination)?.projectID, destination)

        let copied = try lifecycle.moveNode(request.id, from: destination, to: taken, into: nil)

        XCTAssertNotEqual(copied.nodeID, request.id)
        XCTAssertEqual(runner.history.runs(for: request.id, in: destination), [])
        XCTAssertEqual(runner.history.runs(for: copied.nodeID, in: taken), [])
        XCTAssertEqual(runner.history.runs(for: request.id, in: taken), [], "the request already there keeps its own (empty) history")
    }

    /// A run pruned from the history leaves `latest` too, so the response pane never shows a run its history dropped.
    func testAPrunedRunLeavesTheLatestExchange() throws {
        let project = try fixture.library.createProject(named: "Pruned")
        let request = RequestItem.http("Pruned")
        try fixture.library.mutate(project) { try $0.insert(.request(request), into: nil) }
        let run = seedRun(for: request.id, in: project)
        let runner = makeRunner()
        XCTAssertEqual(runner.exchange(for: request.id, in: project)?.id, run.id)

        runner.history.onPrune?([RunKey(request.id, in: project): [run.id]])

        XCTAssertNil(runner.latest[RunKey(request.id, in: project)])
    }

    /// Stored the way a recorded run is, before any runner reads the history.
    @discardableResult
    private func seedRun(for request: RequestNodeID, in project: ProjectID) -> RequestExchange {
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let response = HTTPResponseRecord(statusCode: 200, headers: [], body: Data(), url: "https://example.com", startedAt: startedAt, duration: 0.1)
        let exchange = RequestExchange(
            projectID: project,
            requestID: request,
            startedAt: startedAt,
            environmentName: nil,
            request: nil,
            outcome: .response(response)
        )
        RunHistoryStore(directory: fixture.directory.file("Support/History")).save(exchange)
        return exchange
    }

    private func makeLifecycle(_ runner: RequestRunner) -> ProjectLifecycle {
        let protoWorkspaces = ProtoWorkspaceStore(environment: ProtoWorkspaceEnvironment(
            importer: ProtocImporter(cacheDirectory: fixture.directory.file("Support/ProtocCache")),
            locateProtoc: { nil },
            changes: { _ in AsyncStream { $0.finish() } }
        ))
        return ProjectLifecycle(library: fixture.library, runner: runner, workspace: workspace, protoWorkspaces: protoWorkspaces)
    }
}
