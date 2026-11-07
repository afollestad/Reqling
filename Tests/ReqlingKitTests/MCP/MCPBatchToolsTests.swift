import Foundation
import MCP
@testable import ReqlingKit
import XCTest

/// `run_folder` against a loopback server that echoes each path, fails /fail with a 500, and never answers /hang.
@MainActor
final class MCPBatchToolsTests: XCTestCase {
    var fixture: MCPFixture!
    var server: TestHTTPServer!
    var project: ProjectID!

    override func setUp() async throws {
        fixture = try MCPFixture()
        server = try await TestHTTPServer.start { request in
            if request.uri.hasPrefix("/fail") {
                return .text("nope", status: .internalServerError)
            }
            if request.uri.hasPrefix("/hang") {
                return .hang
            }
            return .text(request.uri)
        }
        project = try await fixture.makeProject()
        _ = try await fixture.success("create_variables", ["project": .string(project.description), "variables": [
            ["key": "base", "value": .string(server.baseURL)],
            ["key": "path", "value": "default"]
        ]])
    }

    override func tearDown() async throws {
        fixture.batches.stop()
        try await server.shutdown()
        fixture.cleanUp()
    }

    /// A Flow folder holding a request per URL path, in order, named for the letters each path starts with.
    @discardableResult
    func folder(_ paths: [String], scripts: [String: ScriptSet] = [:]) throws -> (folder: RequestNodeID, requests: [String: RequestNodeID]) {
        let folder = RequestFolder(name: "Flow")
        var requests: [String: RequestNodeID] = [:]
        try fixture.library.mutate(project) { document in
            try document.insert(.folder(folder), into: nil)
            for path in paths {
                let name = String(path.prefix { $0.isLetter })
                var request = RequestItem(name: name, kind: .http(HTTPRequestSpec(url: "{{base}}/\(path)")))
                request.scripts = scripts[name] ?? ScriptSet()
                requests[name] = request.id
                try document.insert(.request(request), into: folder.id)
            }
        }
        return (folder.id, requests)
    }

    func run(_ folder: RequestNodeID, _ extra: [String: Value] = [:]) async throws -> [String: Value] {
        let arguments: [String: Value] = ["project": .string(project.description), "folder": .string(folder.description)]
        return try await fixture.success("run_folder", arguments.merging(extra) { $1 })
    }

    func testAFolderRunsOncePerDataRowAndReportsTotalsAndWhatDidntPass() async throws {
        let (folder, requests) = try folder(["users/{{id}}", "fail"])

        let result = try await run(folder, ["data": [["id": 1], ["id": "2"]]])

        XCTAssertEqual(server.requests.map(\.uri), ["/users/1", "/fail", "/users/2", "/fail"])
        XCTAssertEqual(result["ended"], "finished")
        XCTAssertEqual(result["iterations"], 2)
        XCTAssertEqual(result["totals"]?["passed"], 2)
        XCTAssertEqual(result["totals"]?["failed"], 2)
        let perRequest = try XCTUnwrap(result["requests"]?.arrayValue)
        XCTAssertEqual(perRequest.map { $0["name"] }, ["users", "fail"])
        XCTAssertEqual(perRequest.last?["failedIterations"], [0, 1])
        let notPassed = try XCTUnwrap(result["notPassed"]?.arrayValue)
        XCTAssertEqual(notPassed.map { $0["iteration"] }, [0, 1])
        XCTAssertEqual(notPassed.first?["request"]?.stringValue, requests["fail"]?.description)
        XCTAssertEqual(notPassed.first?["status"], 500)
        XCTAssertEqual(notPassed.first?["result"], "failed")
        let run = try XCTUnwrap(notPassed.first?["run"]?.stringValue)
        let request = try XCTUnwrap(notPassed.first?["request"]?.stringValue)
        _ = try await fixture.success("get_run", ["project": .string(project.description), "request": .string(request), "run": .string(run)])
        XCTAssertEqual(fixture.batches.run?.state, .ended(.finished), "The window's sidebar shows the agent's run")
    }

    func testTheActiveEnvironmentAppliesWhenNoneIsNamedAndVariablesBeatIt() async throws {
        _ = try await fixture.success("create_environment", ["project": .string(project.description), "name": "Staging", "variables": [
            ["key": "path", "value": "staging"]
        ]])
        let staging = try XCTUnwrap(try fixture.document(project).environments.first?.id)
        fixture.workspace.updateProject(project) { $0.activeEnvironmentID = staging }
        let (folder, _) = try folder(["{{path}}"])

        let active = try await run(folder)
        _ = try await run(folder, ["variables": ["path": "override"]])

        XCTAssertEqual(active["environment"], "Staging")
        XCTAssertEqual(server.requests.map(\.uri), ["/staging", "/override"])
    }

    func testWhatOneStepsScriptsMadeSecretIsMaskedWhereALaterOneShowsIt() async throws {
        let (folder, _) = try folder(["sign", "use"], scripts: [
            "sign": ScriptSet(postResponse: "rq.variables.set('sig', 's3cr3t-signature', { secret: true })"),
            "use": ScriptSet(preRequest: "throw new Error('leaked ' + rq.variables.get('sig'))")
        ])

        let result = await fixture.call("run_folder", ["project": .string(project.description), "folder": .string(folder.description)])

        XCTAssertFalse(result.isError, result.text)
        XCTAssertTrue(result.text.contains("leaked"), result.text)
        XCTAssertFalse(result.text.contains("s3cr3t-signature"), result.text)
    }

    func testArgumentsAreCheckedAndASecondRunIsRefused() async throws {
        let (folder, _) = try folder(["hang"])
        let stray = try await fixture.success("create_request", [
            "project": .string(project.description), "name": "Stray", "http": ["url": "{{base}}/x"]
        ])
        let strayID = try XCTUnwrap(stray["request"]?["id"]?.stringValue)

        let both = await fixture.failure("run_folder", [
            "project": .string(project.description), "folder": .string(folder.description), "iterations": 2, "data": [["a": 1]]
        ])
        let outside = await fixture.failure("run_folder", [
            "project": .string(project.description), "folder": .string(folder.description), "requests": [.string(strayID)]
        ])
        let arguments: [String: Value] = ["project": .string(project.description), "folder": .string(folder.description)]
        let call = Task { await self.fixture.call("run_folder", arguments) }
        await waitUntil("the first run is going") { self.fixture.batches.isRunning }
        let second = await fixture.failure("run_folder", arguments)
        call.cancel()
        let cancelled = await call.value
        await waitUntil("the first run stops") { !self.fixture.batches.isRunning }

        XCTAssertTrue(both.contains("not both"), both)
        XCTAssertTrue(outside.contains("isn't in folder “Flow”"), outside)
        XCTAssertTrue(second.contains("Another folder or project run is going"), second)
        XCTAssertNotNil(cancelled)
        XCTAssertEqual(fixture.batches.run?.state, .ended(.stopped), "Cancelling the call stops the run")
    }
}
