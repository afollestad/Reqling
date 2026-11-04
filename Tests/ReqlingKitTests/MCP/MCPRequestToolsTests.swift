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

    /// Leaving out `destinationFolder` means the top level, of this project or of `destinationProject`, whose folders
    /// are the ones it names. Across projects the request keeps its ID, and its old file goes to the Trash.
    func testMovesOutOfAFolderAndIntoAnotherProject() async throws {
        let admin = try await fixture.success("create_folder", ["project": projectArgument, "name": "Admin"])
        let adminID = try XCTUnwrap(admin["folder"]?["id"]?.stringValue)
        let id = try await create("Ping", ["url": "https://api/ping"], folder: adminID)
        let web = try await fixture.makeProject("Web")
        let inbox = try await fixture.success("create_folder", ["project": .string(web.description), "name": "Inbox"])
        let inboxID = try XCTUnwrap(inbox["folder"]?["id"]?.stringValue)

        let out = try await fixture.success("move_request", ["project": projectArgument, "request": .string(id)])
        let wrongFolder = await fixture.failure("move_request", [
            "project": projectArgument,
            "request": .string(id),
            "destinationProject": "web",
            "destinationFolder": .string(adminID)
        ])
        let across = try await fixture.success("move_request", [
            "project": projectArgument,
            "request": .string(id),
            "destinationProject": "web",
            "destinationFolder": .string(inboxID)
        ])

        let requestID = try XCTUnwrap(RequestNodeID(string: id))
        XCTAssertEqual(out["folderPath"], .array([]))
        XCTAssertTrue(wrongFolder.contains("“Web” has no folder"), wrongFolder)
        XCTAssertEqual(across["moved"]?.stringValue, id)
        XCTAssertEqual(across["project"]?.stringValue, web.description)
        XCTAssertEqual(across["folderPath"], ["Inbox"])
        XCTAssertNil(across["warnings"])
        XCTAssertEqual(try fixture.document(project).items.map(\.name), ["Admin"])
        XCTAssertEqual(fixture.storage.relaunched().document(web)?.request(requestID)?.kind.httpSpec?.url, "https://api/ping")
        XCTAssertEqual(fixture.storage.trashedNames(), ["ping.json"])
    }

    /// A shared path stays shared while its file is inside the destination's folder or repository, and otherwise
    /// becomes a this-Mac-only path the result warns about. A this-Mac-only path stays one, recorded for the destination.
    func testMovingIntoAnotherProjectRepointsFileReferences() async throws {
        try FileManager.default.createDirectory(at: fixture.storage.directory.file("Projects/.git"), withIntermediateDirectories: true)
        let web = try await fixture.makeProject("Web")
        let elsewhere = fixture.storage.directory.file("Elsewhere")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let created = try await fixture.success("create_project", ["name": "Outside", "location": .string(elsewhere.path)])
        let outside = try XCTUnwrap(created["project"]?["id"]?.stringValue.flatMap(ProjectID.init(string:)))
        var spec = HTTPRequestSpec(url: "https://api/upload")
        spec.body.binary.file = .relative("data/body.bin")
        let certificate = fixture.workspace.addLocalPath("/Users/me/client.p12", in: project)
        spec.body.formData = [MultipartField(key: "cert", kind: .file, file: certificate)]
        let request = RequestItem(name: "Upload", kind: .http(spec))
        try fixture.library.mutate(project) { try $0.insert(.request(request), into: nil) }

        func move(from source: ProjectID, to destination: ProjectID) async throws -> (Value?, HTTPRequestSpec) {
            let result = try await fixture.success("move_request", [
                "project": .string(source.description),
                "request": .string(request.id.description),
                "destinationProject": .string(destination.description)
            ])
            return (result["warnings"], try XCTUnwrap(try fixture.document(destination).request(request.id)?.kind.httpSpec))
        }
        func localPath(_ reference: ProjectPathReference?, in project: ProjectID) -> String? {
            guard case .local(let id)? = reference else {
                return nil
            }
            return fixture.workspace.localPath(id, in: project)
        }
        let (repoWarnings, inWeb) = try await move(from: project, to: web)
        let (outsideWarnings, inOutside) = try await move(from: web, to: outside)

        let bodyPath = "Projects/\(fixture.storage.projectURL(project).lastPathComponent)/data/body.bin"
        XCTAssertNil(repoWarnings)
        XCTAssertEqual(inWeb.body.binary.file, .relative("../\(fixture.storage.projectURL(project).lastPathComponent)/data/body.bin"))
        XCTAssertEqual(localPath(inWeb.body.formData.first?.file, in: web), "/Users/me/client.p12")
        XCTAssertEqual(outsideWarnings?.arrayValue?.count, 1)
        XCTAssertTrue(outsideWarnings?.arrayValue?.first?.stringValue?.contains(bodyPath) == true, "\(String(describing: outsideWarnings))")
        XCTAssertTrue(localPath(inOutside.body.binary.file, in: outside)?.hasSuffix(bodyPath) == true)
        XCTAssertEqual(localPath(inOutside.body.formData.first?.file, in: outside), "/Users/me/client.p12")
    }

    /// A folder carries its whole tree, taking fresh IDs throughout when the destination already uses one of them, as a
    /// copied project folder would.
    func testMovingAFolderIntoAnotherProjectGivesFreshIDsOnACollision() async throws {
        let folder = try await fixture.success("create_folder", ["project": projectArgument, "name": "Admin"])
        let folderID = try XCTUnwrap(folder["folder"]?["id"]?.stringValue)
        let id = try await create("Ping", ["url": "https://api/ping"], folder: folderID)
        let requestID = try XCTUnwrap(RequestNodeID(string: id))
        let web = try await fixture.makeProject("Web")
        let copied = RequestItem(id: requestID, name: "Copied", kind: .http(HTTPRequestSpec()))
        try fixture.library.mutate(web) { try $0.insert(.request(copied), into: nil) }

        let moved = try await fixture.success("move_folder", [
            "project": projectArgument,
            "folder": .string(folderID),
            "destinationProject": .string(web.description)
        ])

        let movedID = try XCTUnwrap(moved["moved"]?.stringValue.flatMap(RequestNodeID.init(string:)))
        let document = try fixture.document(web)
        let child = try XCTUnwrap(document.folder(movedID)?.children.first)
        XCTAssertNotEqual(movedID.description, folderID)
        XCTAssertEqual(document.items.map(\.name), ["Copied", "Admin"])
        XCTAssertEqual(child.name, "Ping")
        XCTAssertNotEqual(child.id, requestID)
        XCTAssertTrue(try fixture.document(project).items.isEmpty)
    }

    /// A move whose source can't let go leaves the request in both projects rather than in neither, and says so.
    func testAMoveThatCantLeaveItsProjectLeavesItInBoth() async throws {
        let id = try await create("Ping", ["url": "https://api/ping"])
        let requestID = try XCTUnwrap(RequestNodeID(string: id))
        let web = try await fixture.makeProject("Web")
        fixture.storage.trash.isFailing = true

        let message = await fixture.failure("move_request", [
            "project": projectArgument,
            "request": .string(id),
            "destinationProject": .string(web.description)
        ])

        XCTAssertTrue(message.contains("so it is in both"), message)
        XCTAssertNotNil(try fixture.document(project).request(requestID))
        XCTAssertNotNil(try fixture.document(web).request(requestID))
    }

    /// A read-only source, saved by a newer Reqling, is refused before anything is written, so nothing is copied.
    func testAMoveOutOfAReadOnlyProjectChangesNothing() async throws {
        let id = try await create("Ping", ["url": "https://api/ping"])
        let web = try await fixture.makeProject("Web")
        let projectFile = fixture.storage.projectURL(project).appendingPathComponent("project.json")
        let json = try String(contentsOf: projectFile, encoding: .utf8)
            .replacingOccurrences(of: #""formatVersion" : 1"#, with: #""formatVersion" : 99"#)
        try json.write(to: projectFile, atomically: true, encoding: .utf8)
        fixture.library.reload(project)

        let message = await fixture.failure("move_request", [
            "project": projectArgument,
            "request": .string(id),
            "destinationProject": .string(web.description)
        ])

        XCTAssertTrue(message.contains("read-only"), message)
        XCTAssertTrue(try fixture.document(web).items.isEmpty)
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
