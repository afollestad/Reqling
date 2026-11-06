import Foundation
import MCP
@testable import ReqlingKit
import XCTest

@MainActor
final class MCPProjectToolsTests: XCTestCase {
    private var fixture: MCPFixture!

    override func setUp() async throws {
        fixture = try MCPFixture()
    }

    override func tearDown() async throws {
        fixture.cleanUp()
    }

    func testCreatingAProjectListsItWithItsDefaultEnvironment() async throws {
        let project = try await fixture.makeProject("Payments")

        let listed = try await fixture.success("list_projects")
        let summary = try XCTUnwrap(listed["projects"]?.arrayValue?.first?.objectValue)

        XCTAssertEqual(summary["id"]?.stringValue, project.description)
        XCTAssertEqual(summary["name"], "Payments")
        XCTAssertEqual(summary["status"], "loaded")
        XCTAssertEqual(summary["environmentCount"], 1)
        XCTAssertEqual(summary["activeEnvironment"]?["name"], "Default")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.storage.projectURL(project).appendingPathComponent("project.json").path))
        XCTAssertEqual(fixture.workspace.projectState(project).scriptTrust, .trusted, "Whoever creates a project writes its scripts")
    }

    func testProjectsResolveByIDOrUniqueName() async throws {
        let project = try await fixture.makeProject("Payments")
        _ = try await fixture.makeProject("Twin")
        _ = try await fixture.makeProject("Twin")

        let byName = try await fixture.success("get_project", ["project": "payments"])
        let ambiguous = await fixture.failure("get_project", ["project": "Twin"])
        let missing = await fixture.failure("get_project", ["project": "Nope"])

        XCTAssertEqual(byName["id"]?.stringValue, project.description)
        XCTAssertTrue(ambiguous.contains("More than one project"), ambiguous)
        XCTAssertTrue(missing.contains("No project “Nope”"), missing)
    }

    func testGetProjectShowsTheTreeAndUpdateChangesNameAndAuth() async throws {
        let project = try await fixture.makeProject()
        let folder = RequestFolder(name: "Users", children: [.request(RequestItem(name: "List", kind: .http(HTTPRequestSpec(url: "https://api"))))])
        try fixture.library.mutate(project) { try $0.insert(.folder(folder), into: nil) }

        _ = try await fixture.success("update_project", [
            "project": .string(project.description),
            "name": "Renamed",
            "auth": ["type": "bearer", "token": "{{token}}"]
        ])
        let described = try await fixture.success("get_project", ["project": .string(project.description)])

        XCTAssertEqual(try fixture.document(project).name, "Renamed")
        XCTAssertEqual(try fixture.document(project).auth, .bearer(token: "{{token}}"))
        XCTAssertEqual(described["auth"]?["type"], "bearer")
        let item = try XCTUnwrap(described["items"]?.arrayValue?.first)
        XCTAssertEqual(item["kind"], "folder")
        XCTAssertEqual(item["children"]?.arrayValue?.first?["name"], "List")
    }

    func testRemovingKeepsTheFolderAndAddingItBackRestoresIt() async throws {
        let project = try await fixture.makeProject()
        let url = fixture.storage.projectURL(project)

        _ = try await fixture.success("remove_project", ["project": .string(project.description)])

        XCTAssertNil(fixture.library.project(project))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        let added = try await fixture.success("add_project_folder", ["path": .string(url.path)])

        XCTAssertEqual(added["project"]?["id"]?.stringValue, project.description)
        let relative = await fixture.failure("add_project_folder", ["path": "relative/folder"])
        XCTAssertTrue(relative.contains("absolute path"), relative)
    }

    func testDeletingMovesTheFolderToTheTrashAndForgetsItsState() async throws {
        let project = try await fixture.makeProject("Doomed")
        _ = fixture.workspace.addLocalPath("/protos", in: project)

        let deleted = try await fixture.success("delete_project", ["project": .string(project.description)])

        XCTAssertEqual(deleted["deleted"]?.stringValue, project.description)
        XCTAssertNil(fixture.library.project(project))
        XCTAssertEqual(fixture.storage.trashedNames(), ["Doomed.reqling"])
        XCTAssertNil(fixture.workspace.state.projects[project.description])
    }
}
