import Foundation
import MCP
@testable import ReqlingKit
import XCTest

@MainActor
final class MCPEnvironmentToolsTests: XCTestCase {
    var fixture: MCPFixture!
    var project: ProjectID!

    override func setUp() async throws {
        fixture = try MCPFixture()
        project = try await fixture.makeProject()
    }

    override func tearDown() async throws {
        fixture.cleanUp()
    }

    var projectArgument: Value {
        .string(project.description)
    }

    func testVariablesDefaultToDefaultAndSecretValuesAreWriteOnly() async throws {
        _ = try await fixture.success("create_variables", ["project": projectArgument, "variables": [
            ["key": "baseUrl", "value": "https://api.example.com"],
            ["key": "token", "value": "s3cr3t-value", "secret": true]
        ]])

        let listed = try await fixture.success("list_variables", ["project": projectArgument])
        let variables = try XCTUnwrap(listed["variables"]?.arrayValue)

        XCTAssertEqual(listed["environment"]?["name"], "Default")
        XCTAssertEqual(variables.first?["value"], "https://api.example.com")
        XCTAssertEqual(variables.last?["secret"], true)
        XCTAssertNil(variables.last?["value"], "A secret's value is never returned")
        XCTAssertEqual(try fixture.document(project).defaultEnvironment.variables.last?.value, "s3cr3t-value")
        let onDisk = try fixture.storage.contents("environments/default.json", in: project)
        XCTAssertFalse(onDisk.contains("s3cr3t-value"))
        XCTAssertEqual(try fixture.storage.secrets.secrets(for: project).values.first, "s3cr3t-value")
    }

    func testCreatingAnExistingKeyFailsAndAddsNothing() async throws {
        _ = try await fixture.success("create_variables", ["project": projectArgument, "variables": [["key": "a", "value": "1"]]])

        let message = await fixture.failure("create_variables", ["project": projectArgument, "variables": [
            ["key": "b", "value": "2"],
            ["key": "a", "value": "again"]
        ]])

        XCTAssertTrue(message.contains("`a` already exists"), message)
        XCTAssertEqual(try fixture.document(project).defaultEnvironment.variables.map(\.key), ["a"])
    }

    func testUpdateRenamesAndChangesInPlaceThenDeleteRemoves() async throws {
        _ = try await fixture.success("create_variables", ["project": projectArgument, "variables": [
            ["key": "host", "value": "a"],
            ["key": "keep", "value": "k"]
        ]])

        _ = try await fixture.success("update_variables", ["project": projectArgument, "variables": [
            ["key": "host", "newKey": "baseUrl", "value": "https://b", "enabled": false]
        ]])
        let missing = await fixture.failure("update_variables", ["project": projectArgument, "variables": [["key": "nope", "value": "x"]]])
        _ = try await fixture.success("delete_variables", ["project": projectArgument, "keys": ["keep"]])

        let variables = try fixture.document(project).defaultEnvironment.variables
        XCTAssertEqual(variables.map(\.key), ["baseUrl"])
        XCTAssertEqual(variables.first?.value, "https://b")
        XCTAssertEqual(variables.first?.isEnabled, false)
        XCTAssertTrue(missing.contains("no variable `nope`"), missing)
    }

    func testEnvironmentsAreCreatedRenamedActivatedAndDeleted() async throws {
        let created = try await fixture.success("create_environment", [
            "project": projectArgument,
            "name": "Staging",
            "variables": [["key": "baseUrl", "value": "https://staging"]]
        ])
        let staging = try XCTUnwrap(created["environment"]?["id"]?.stringValue)

        let duplicate = await fixture.failure("create_environment", ["project": projectArgument, "name": "staging"])
        _ = try await fixture.success("list_variables", ["project": projectArgument, "environment": "Staging"])
        _ = try await fixture.success("set_active_environment", ["project": projectArgument, "environment": "Staging"])
        let listed = try await fixture.success("list_environments", ["project": projectArgument])
        _ = try await fixture.success("update_environment", ["project": projectArgument, "environment": .string(staging), "name": "QA"])
        let renameDefault = await fixture.failure("update_environment", ["project": projectArgument, "environment": "Default", "name": "X"])
        let deleteDefault = await fixture.failure("delete_environment", ["project": projectArgument, "environment": "Default"])
        _ = try await fixture.success("delete_environment", ["project": projectArgument, "environment": "QA"])

        XCTAssertTrue(duplicate.contains("already has an environment"), duplicate)
        XCTAssertEqual(listed["environments"]?.arrayValue?.last?["isActive"], true)
        XCTAssertTrue(renameDefault.contains("can't be renamed"), renameDefault)
        XCTAssertTrue(deleteDefault.contains("can't be deleted"), deleteDefault)
        let document = try fixture.document(project)
        XCTAssertTrue(document.environments.isEmpty)
        XCTAssertEqual(fixture.workspace.activeEnvironment(in: document).id, document.defaultEnvironment.id)
        XCTAssertEqual(fixture.storage.trashedNames().count, 1, "The environment's file went to the Trash")
    }

    func testListingEveryEnvironmentShowsThemSideBySide() async throws {
        _ = try await fixture.success("create_environment", ["project": projectArgument, "name": "Prod", "variables": [["key": "k", "value": "p"]]])

        let listed = try await fixture.success("list_variables", ["project": projectArgument, "includeAllEnvironments": true])

        XCTAssertEqual(listed["environments"]?.arrayValue?.map { $0["name"] }, ["Global", "Default", "Prod"])
        XCTAssertEqual(listed["environments"]?.arrayValue?.last?["variables"]?.arrayValue?.first?["value"], "p")
    }

    func testGlobalVariablesNeedNoProjectAndKeepSecretsOutOfItsFile() async throws {
        _ = try await fixture.success("create_variables", ["environment": "Global", "variables": [
            ["key": "region", "value": "eu"],
            ["key": "apiKey", "value": "g10bal-s3cr3t", "secret": true]
        ]])
        _ = try await fixture.success("update_variables", ["project": projectArgument, "environment": "global", "variables": [
            ["key": "region", "value": "us"]
        ]])
        let listed = try await fixture.success("list_variables", ["environment": "Global"])
        _ = try await fixture.success("delete_variables", ["environment": .string(RequestEnvironment.globalID.description), "keys": ["region"]])
        let withoutProject = await fixture.failure("list_variables")

        XCTAssertEqual(listed["environment"]?["name"], "Global")
        XCTAssertEqual(listed["variables"]?.arrayValue?.first?["value"], "us")
        XCTAssertNil(listed["variables"]?.arrayValue?.last?["value"], "A secret's value is never returned")
        XCTAssertEqual(fixture.library.globalEnvironment.variables.map(\.key), ["apiKey"])
        XCTAssertEqual(fixture.library.globalEnvironment.variables.first?.value, "g10bal-s3cr3t")
        XCTAssertFalse(try String(contentsOf: fixture.storage.globalEnvironmentURL, encoding: .utf8).contains("g10bal-s3cr3t"))
        XCTAssertEqual(try fixture.storage.secrets.secrets(for: .global).values.sorted(), ["g10bal-s3cr3t"])
        XCTAssertTrue(try fixture.document(project).defaultEnvironment.variables.isEmpty)
        XCTAssertTrue(withoutProject.contains("`project` is required"), withoutProject)
    }

    func testGlobalIsListedButNeverChosenRenamedDeletedOrNamedAgain() async throws {
        let listed = try await fixture.success("list_environments", ["project": projectArgument])
        let activate = await fixture.failure("set_active_environment", ["project": projectArgument, "environment": "Global"])
        let rename = await fixture.failure("update_environment", ["project": projectArgument, "environment": "Global", "name": "X"])
        let delete = await fixture.failure("delete_environment", ["project": projectArgument, "environment": "Global"])
        let create = await fixture.failure("create_environment", ["project": projectArgument, "name": "global"])
        let legacy = RequestEnvironment(name: "Global")
        try fixture.library.mutate(project) { $0.environments.append(legacy) }
        let recase = await fixture.failure("update_environment", [
            "project": projectArgument, "environment": .string(legacy.id.description), "name": "global"
        ])

        let first = listed["environments"]?.arrayValue?.first
        XCTAssertEqual(first?["name"], "Global")
        XCTAssertEqual(first?["isGlobal"], true)
        XCTAssertEqual(first?["isActive"], false)
        for message in [activate, rename, delete] {
            XCTAssertTrue(message.contains("Global applies to every request"), message)
        }
        XCTAssertTrue(create.contains("reserved"), create)
        XCTAssertTrue(recase.contains("reserved"), recase)
        XCTAssertEqual(try fixture.document(project).environments.map(\.name), ["Global"])
    }
}
