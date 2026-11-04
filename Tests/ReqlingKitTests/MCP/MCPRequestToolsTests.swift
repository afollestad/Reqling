import Foundation
import MCP
@testable import ReqlingKit
import XCTest

@MainActor
final class MCPRequestToolsTests: XCTestCase {
    private var fixture: MCPFixture!
    private var project: ProjectID!

    override func setUp() async throws {
        fixture = try MCPFixture()
        project = try await fixture.makeProject()
    }

    override func tearDown() async throws {
        fixture.cleanUp()
    }

    private var projectArgument: Value {
        .string(project.description)
    }

    private func create(_ name: String, _ spec: Value? = nil, folder: String? = nil) async throws -> String {
        var arguments: [String: Value] = ["project": projectArgument, "name": .string(name)]
        arguments["http"] = spec
        arguments["folder"] = folder.map(Value.string)
        let created = try await fixture.success("create_request", arguments)
        return try XCTUnwrap(created["request"]?["id"]?.stringValue)
    }

    func testCreatedRequestsTakeDefaultsAndMoveAQueryStringIntoRows() async throws {
        let id = try await create("Search", ["method": "POST", "url": "{{baseUrl}}/search?q=a+b&limit=5"])

        let request = try XCTUnwrap(try fixture.document(project).request(XCTUnwrap(RequestNodeID(string: id))))
        let spec = try XCTUnwrap(request.kind.httpSpec)
        XCTAssertEqual(spec.method, .post)
        XCTAssertEqual(spec.url, "{{baseUrl}}/search")
        XCTAssertEqual(spec.queryParameters.map(\.key), ["q", "limit"])
        XCTAssertEqual(spec.queryParameters.first?.value, "a b")
        XCTAssertEqual(spec.auth, .inherit)

        let bad = await fixture.failure("create_request", ["project": projectArgument, "name": "Bad", "http": ["method": 5]])
        XCTAssertTrue(bad.contains("`http` is not valid"), bad)
    }

    func testListFiltersByFolderKindAndQuery() async throws {
        let folder = try await fixture.success("create_folder", ["project": projectArgument, "name": "Users"])
        let folderID = try XCTUnwrap(folder["folder"]?["id"]?.stringValue)
        _ = try await create("List users", ["url": "https://api/users"], folder: folderID)
        _ = try await create("Health", ["url": "https://api/health"])
        _ = try await fixture.success("create_request", [
            "project": projectArgument,
            "name": "Echo",
            "grpc": ["target": "localhost:50051", "service": "echo.Echo", "method": "Say"]
        ])

        let inFolder = try await fixture.success("list_requests", ["project": projectArgument, "folder": .string(folderID)])
        let grpc = try await fixture.success("list_requests", ["kind": "grpc"])
        let queried = try await fixture.success("list_requests", ["project": projectArgument, "query": "HEALTH"])

        XCTAssertEqual(inFolder["requests"]?.arrayValue?.map { $0["name"] }, ["List users"])
        XCTAssertEqual(inFolder["requests"]?.arrayValue?.first?["folderPath"], ["Users"])
        XCTAssertEqual(grpc["requests"]?.arrayValue?.map { $0["rpc"] }, ["echo.Echo/Say"])
        XCTAssertEqual(queried["requests"]?.arrayValue?.map { $0["name"] }, ["Health"])
    }

    func testUpdateMergesThePatchAndKeepsTheRest() async throws {
        let id = try await create("Create", [
            "method": "POST",
            "url": "https://api/users",
            "headers": [["key": "Accept", "value": "application/json"]],
            "body": ["mode": "raw", "raw": ["text": "{}", "contentType": "application/json"]]
        ])

        _ = try await fixture.success("update_request", [
            "project": projectArgument,
            "request": .string(id),
            "name": "Create user",
            "spec": ["body": ["raw": ["text": #"{"name": "{{name}}"}"#]], "headers": [["key": "X-Trace", "value": "1"]]]
        ])
        let invalid = await fixture.failure("update_request", ["project": projectArgument, "request": .string(id), "spec": ["method": []]])

        let request = try XCTUnwrap(try fixture.document(project).request(XCTUnwrap(RequestNodeID(string: id))))
        let spec = try XCTUnwrap(request.kind.httpSpec)
        XCTAssertEqual(request.name, "Create user")
        XCTAssertEqual(spec.method, .post, "Untouched fields keep their value")
        XCTAssertEqual(spec.body.raw.text, #"{"name": "{{name}}"}"#)
        XCTAssertEqual(spec.body.raw.contentType, "application/json", "Objects merge")
        XCTAssertEqual(spec.headers.map(\.key), ["X-Trace"], "Arrays replace")
        XCTAssertTrue(invalid.contains("`spec` is not valid"), invalid)
    }

    /// Rows named by `id` keep it and merge, so the editor's row merge still tells an agent's edit from the user's; new
    /// rows get fresh IDs, never ones derived from their position that a later row could share.
    func testRowListsMergeByIDAndNewRowsGetFreshIDs() async throws {
        let id = try await create("Rows", ["headers": [["key": "Accept", "value": "*/*"], ["key": "X-Old", "value": "1"]]])
        let stored = try XCTUnwrap(try fixture.document(project).request(XCTUnwrap(RequestNodeID(string: id)))?.kind.httpSpec)
        let accept = stored.headers[0]

        func update(_ headers: Value) async throws -> [KeyValuePair] {
            _ = try await fixture.success("update_request", ["project": projectArgument, "request": .string(id), "spec": ["headers": headers]])
            return try XCTUnwrap(try fixture.document(project).request(XCTUnwrap(RequestNodeID(string: id)))?.kind.httpSpec?.headers)
        }
        let first = try await update([["id": .string(accept.id.description), "value": "application/json"], ["key": "X-New", "value": "1"]])
        let second = try await update([["id": .string(accept.id.description)], ["key": "X-Newer", "value": "2"]])

        XCTAssertEqual(first.map(\.key), ["Accept", "X-New"], "X-Old, left out, is removed")
        XCTAssertEqual(first[0].id, accept.id)
        XCTAssertEqual(first[0].value, "application/json", "Fields not given keep their value; given ones change")
        XCTAssertEqual(second[0].value, "application/json")
        XCTAssertNotEqual(first[1].id, second[1].id, "Two rows added at the same place in separate updates are different rows")
    }

    func testDuplicateMoveAndDeleteKeepTheTreeConsistent() async throws {
        let folder = try await fixture.success("create_folder", ["project": projectArgument, "name": "Admin"])
        let folderID = try XCTUnwrap(folder["folder"]?["id"]?.stringValue)
        let id = try await create("Ping", ["url": "https://api/ping"])

        let copy = try await fixture.success("duplicate_request", ["project": projectArgument, "request": .string(id)])
        let copyID = try XCTUnwrap(copy["request"]?["id"]?.stringValue)
        _ = try await fixture.success("move_request", [
            "project": projectArgument,
            "request": .string(copyID),
            "destinationFolder": .string(folderID)
        ])
        let cycle = await fixture.failure("move_folder", [
            "project": projectArgument,
            "folder": .string(folderID),
            "destinationFolder": .string(folderID)
        ])
        _ = try await fixture.success("delete_request", ["project": projectArgument, "request": .string(id)])
        _ = try await fixture.success("delete_folder", ["project": projectArgument, "folder": .string(folderID)])

        XCTAssertEqual(copy["request"]?["name"], "Ping Copy")
        XCTAssertNotEqual(copyID, id)
        XCTAssertTrue(cycle.contains("can't move into itself"), cycle)
        XCTAssertTrue(try fixture.document(project).items.isEmpty)
        XCTAssertEqual(fixture.storage.trashedNames(), ["admin", "ping.json"])
    }

    func testCurlImportsAsARequestAndExportsMasked() async throws {
        _ = try await fixture.success("create_variables", ["project": projectArgument, "variables": [
            ["key": "token", "value": "hunter2-secret", "secret": true]
        ]])
        let imported = try await fixture.success("import_curl", [
            "project": projectArgument,
            "command": #"curl -X POST https://api.example.com/v1/users -H 'Authorization: Bearer {{token}}' --frobnicate -d '{"a":1}'"#
        ])
        let id = try XCTUnwrap(imported["request"]?["id"]?.stringValue)

        let exported = try await fixture.success("export_curl", ["project": projectArgument, "request": .string(id)])

        XCTAssertEqual(imported["request"]?["name"], "POST /v1/users")
        XCTAssertFalse(imported["warnings"]?.arrayValue?.isEmpty ?? true, "The unknown flag is reported")
        let command = try XCTUnwrap(exported["command"]?.stringValue)
        XCTAssertTrue(command.contains("https://api.example.com/v1/users"), command)
        XCTAssertFalse(command.contains("hunter2-secret"), command)
    }
}
