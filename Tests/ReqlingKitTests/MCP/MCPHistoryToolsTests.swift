import Foundation
import MCP
@testable import ReqlingKit
import XCTest

/// Runs recorded through `execute_request` against a loopback server that echoes the `Authorization` it received, so
/// a test sees that a stored run is masked like a live one.
@MainActor
final class MCPHistoryToolsTests: XCTestCase {
    private var fixture: MCPFixture!
    private var server: TestHTTPServer!
    private var project: ProjectID!
    private var request: String!

    override func setUp() async throws {
        fixture = try MCPFixture()
        server = try await TestHTTPServer.start { request in
            .text("\(request.uri) auth=\(request.header("Authorization") ?? "-")")
        }
        project = try await fixture.makeProject()
        _ = try await fixture.success("create_variables", ["project": .string(project.description), "variables": [
            ["key": "baseUrl", "value": .string(server.baseURL)],
            ["key": "token", "value": "t0ken-secret", "secret": true]
        ]])
        let created = try await fixture.success("create_request", [
            "project": .string(project.description),
            "name": "Echo",
            "http": ["url": "{{baseUrl}}/echo", "auth": ["type": "bearer", "token": "{{token}}"]]
        ])
        request = try XCTUnwrap(created["request"]?["id"]?.stringValue)
    }

    override func tearDown() async throws {
        try await server.shutdown()
        fixture.cleanUp()
    }

    func testRunsListNewestFirstAndReadBackMaskedWithTheirTemplate() async throws {
        let first = try await execute()
        let second = try await execute(["overrides": ["url": "{{baseUrl}}/again"]])

        let listed = try await fixture.success("list_runs", ["project": .string(project.description), "request": .string(request)])
        let runs = try XCTUnwrap(listed["runs"]?.arrayValue)
        XCTAssertEqual(runs.compactMap { $0["run"]?.stringValue }, [second["run"], first["run"]].compactMap { $0?.stringValue })
        XCTAssertEqual(runs.first?["status"], 200)
        XCTAssertEqual(runs.first?["outcome"], "succeeded")
        XCTAssertEqual(listed["total"], 2)

        let older = try await fixture.success("get_run", [
            "project": .string(project.description), "request": .string(request), "run": try XCTUnwrap(first["run"])
        ])
        let body = try XCTUnwrap(older["response"]?["body"]?.stringValue)
        XCTAssertTrue(body.hasPrefix("/echo "), body)
        XCTAssertFalse(body.contains("t0ken-secret"), "a stored run is masked like a live one: \(body)")
        XCTAssertEqual(older["spec"]?["http"]?["url"], "{{baseUrl}}/echo")
        XCTAssertEqual(older["spec"]?["http"]?["auth"]?["token"], "{{token}}", "the template, never its resolved value")
    }

    func testClearingARequestOrAProjectEmptiesItsHistory() async throws {
        _ = try await execute()

        _ = try await fixture.success("clear_history", ["project": .string(project.description), "request": .string(request)])
        let afterRequest = try await fixture.success("list_runs", ["project": .string(project.description), "request": .string(request)])
        XCTAssertEqual(afterRequest["total"], 0)

        _ = try await execute()
        _ = try await fixture.success("clear_history", ["project": .string(project.description)])
        let last = try await fixture.success("get_last_response", ["project": .string(project.description), "request": .string(request)])
        XCTAssertEqual(last["ran"], false)
    }

    func testAnUnknownRunIsRefused() async {
        let missing = await fixture.failure("get_run", [
            "project": .string(project.description), "request": .string(request), "run": .string(RunID().description)
        ])
        let malformed = await fixture.failure("get_run", ["project": .string(project.description), "request": .string(request), "run": "latest"])

        XCTAssertTrue(missing.contains("has no run"), missing)
        XCTAssertTrue(malformed.contains("run's ID"), malformed)
    }

    func testHistorySettingsReadAndChange() async throws {
        let changed = try await fixture.success("update_settings", ["historyRetention": "week", "historySizeLimit": "1GB"])
        let refused = await fixture.failure("update_settings", ["historyRetention": "fortnight"])

        XCTAssertEqual(changed["historyRetention"], "week")
        XCTAssertEqual(changed["historySizeLimit"], "1GB")
        XCTAssertEqual(fixture.settings.settings.historyRetention, .week)
        XCTAssertTrue(refused.contains("day, week, month, quarter, forever"), refused)
    }

    private func execute(_ extra: [String: Value] = [:]) async throws -> [String: Value] {
        try await fixture.success("execute_request", ["project": .string(project.description), "request": .string(request)].merging(extra) { $1 })
    }
}
