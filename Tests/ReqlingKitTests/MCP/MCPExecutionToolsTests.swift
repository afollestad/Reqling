import Foundation
import MCP
@testable import ReqlingKit
import XCTest

/// Runs against a loopback server that echoes the path and the `Authorization` header it received, so a test sees both
/// what was really sent and what the tool shows.
@MainActor
final class MCPExecutionToolsTests: XCTestCase {
    var fixture: MCPFixture!
    var server: TestHTTPServer!
    var project: ProjectID!
    var request: String!

    override func setUp() async throws {
        fixture = try MCPFixture()
        server = try await TestHTTPServer.start { request in
            .text("\(request.uri) auth=\(request.header("Authorization") ?? "-")", headers: [("X-Echo", request.header("Authorization") ?? "-")])
        }
        project = try await fixture.makeProject()
        _ = try await fixture.success("create_variables", ["project": .string(project.description), "variables": [
            ["key": "baseUrl", "value": .string(server.baseURL)],
            ["key": "path", "value": "default"],
            ["key": "token", "value": "t0ken-secret", "secret": true]
        ]])
        _ = try await fixture.success("create_environment", ["project": .string(project.description), "name": "Staging", "variables": [
            ["key": "path", "value": "staging"]
        ]])
        let created = try await fixture.success("create_request", [
            "project": .string(project.description),
            "name": "Echo",
            "http": ["url": "{{baseUrl}}/{{path}}", "auth": ["type": "bearer", "token": "{{token}}"]]
        ])
        request = try XCTUnwrap(created["request"]?["id"]?.stringValue)
    }

    override func tearDown() async throws {
        try await server.shutdown()
        fixture.cleanUp()
    }

    func execute(_ extra: [String: Value] = [:]) async throws -> [String: Value] {
        try await fixture.success("execute_request", ["project": .string(project.description), "request": .string(request)].merging(extra) { $1 })
    }

    func testVariablesResolveRunOverridesThenTheChosenEnvironmentThenDefault() async throws {
        let onDefault = try await execute()
        let onStaging = try await execute(["environment": "Staging"])
        let overridden = try await execute(["environment": "Staging", "variables": ["path": "override"]])

        XCTAssertEqual(onDefault["response"]?["body"]?.stringValue?.hasPrefix("/default "), true)
        XCTAssertEqual(onStaging["environment"], "Staging")
        XCTAssertEqual(onStaging["response"]?["body"]?.stringValue?.hasPrefix("/staging "), true)
        XCTAssertEqual(overridden["response"]?["body"]?.stringValue?.hasPrefix("/override "), true)
        XCTAssertEqual(overridden["response"]?["status"], 200)
    }

    func testTheSecretReachesTheServerButNeverTheAgent() async throws {
        let result = try await execute()

        XCTAssertEqual(server.requests.last?.header("Authorization"), "Bearer t0ken-secret")
        let text = MCPJSON.text(.object(result))
        XCTAssertFalse(text.contains("t0ken-secret"), "Masked in the resolved request, the echoed body, and the echoed header")
        XCTAssertEqual(result["response"]?["body"]?.stringValue?.contains("auth=Bearer ••••"), true, text)
    }

    /// The last response may come from any environment's run, so its echo is masked with every environment's secrets.
    func testALastResponseMasksAnotherEnvironmentsSecret() async throws {
        _ = try await fixture.success("create_variables", ["project": .string(project.description), "environment": "Staging", "variables": [
            ["key": "token", "value": "staging-only-secret", "secret": true]
        ]])
        _ = try await execute(["environment": "Staging"])

        let last = try await fixture.success("get_last_response", ["project": .string(project.description), "request": .string(request)])

        XCTAssertEqual(server.requests.last?.header("Authorization"), "Bearer staging-only-secret")
        XCTAssertFalse(MCPJSON.text(.object(last)).contains("staging-only-secret"))
    }

    func testAGlobalSecretIsMaskedAndGlobalIsNeverTheRunsEnvironment() async throws {
        _ = try await fixture.success("create_variables", ["environment": "Global", "variables": [
            ["key": "globalToken", "value": "g10bal-secret", "secret": true]
        ]])
        _ = try await fixture.success("update_request", [
            "project": .string(project.description),
            "request": .string(request),
            "spec": ["url": "{{baseUrl}}/{{path}}", "auth": ["type": "bearer", "token": "{{globalToken}}"]]
        ])

        let result = try await execute()
        let refused = await fixture.failure("execute_request", [
            "project": .string(project.description), "request": .string(request), "environment": "Global"
        ])

        XCTAssertEqual(server.requests.last?.header("Authorization"), "Bearer g10bal-secret")
        XCTAssertFalse(MCPJSON.text(.object(result)).contains("g10bal-secret"))
        XCTAssertTrue(refused.contains("Global applies to every request"), refused)
    }

    func testUndefinedVariablesFailFastUnlessAllowed() async throws {
        _ = try await fixture.success("update_request", [
            "project": .string(project.description),
            "request": .string(request),
            "spec": ["url": "{{baseUrl}}/{{missing}}"]
        ])

        let refused = try await execute()
        let allowed = try await execute(["allowUnresolved": true])

        XCTAssertEqual(refused["failure"]?["kind"], "invalidRequest")
        XCTAssertEqual(refused["failure"]?["message"]?.stringValue?.contains("{{missing}}"), true)
        XCTAssertTrue(server.requests.count == 1, "Only the allowed run was sent")
        XCTAssertEqual(allowed["unresolvedVariables"], ["missing"])
    }

    func testOverridesApplyToOneRunAndTheLastResponseIsKept() async throws {
        let patched = try await execute(["overrides": ["url": "{{baseUrl}}/patched"]])
        let last = try await fixture.success("get_last_response", ["project": .string(project.description), "request": .string(request)])

        XCTAssertEqual(patched["response"]?["body"]?.stringValue?.hasPrefix("/patched "), true)
        XCTAssertEqual(try fixture.document(project).allRequests.first?.request.kind.httpSpec?.url, "{{baseUrl}}/{{path}}")
        XCTAssertEqual(last["ran"], true)
        XCTAssertEqual(last["response"]?["body"], patched["response"]?["body"])
    }

    func testAnAdHocRunIsNeverRecorded() async throws {
        let result = try await fixture.success("execute_ad_hoc_request", [
            "project": .string(project.description),
            "http": ["url": "{{baseUrl}}/adhoc"]
        ])

        XCTAssertEqual(result["response"]?["body"]?.stringValue?.hasPrefix("/adhoc "), true)
        XCTAssertTrue(fixture.runner.latest.isEmpty)
        // Saves are written in the background; without the flush, a recorded run could still be on its way to disk.
        fixture.runner.flushHistory()
        let cached = (try? FileManager.default.contentsOfDirectory(atPath: fixture.storage.directory.file("Support/History").path)) ?? []
        XCTAssertTrue(cached.isEmpty, "\(cached)")
    }

    func testResolveShowsWhatWouldBeSentWithoutSending() async throws {
        let resolved = try await fixture.success("resolve_request", [
            "project": .string(project.description),
            "request": .string(request),
            "environment": "Staging"
        ])

        XCTAssertEqual(resolved["request"]?["url"], .string("\(server.baseURL)/staging"))
        XCTAssertFalse(MCPJSON.text(.object(resolved)).contains("t0ken-secret"))
        XCTAssertTrue(server.requests.isEmpty)
    }
}
