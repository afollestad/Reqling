import Foundation
import ReqlingKit
import XCTest

@testable import Reqling

/// The import sheet's flow: choosing files, naming the project, importing it, and what the summary says.
@MainActor
final class PostmanImportModelTests: XCTestCase {
    private var fixture: AppFixture!
    private var directory: URL!

    override func setUp() async throws {
        fixture = AppFixture()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("PostmanImportModelTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
        fixture.tearDown()
        fixture = nil
    }

    private func write(_ json: String, as name: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data(json.utf8).write(to: url)
        return url
    }

    private func collection(named name: String, items: String = "[]", extra: String = "") throws -> URL {
        try write(#"{"info": {"name": "\#(name)"}, \#(extra.isEmpty ? "" : extra + ",") "item": \#(items)}"#, as: "\(name).postman_collection.json")
    }

    func testTheCollectionNamesTheProjectUntilThePersonNamesIt() async throws {
        let importer = PostmanImportModel(app: fixture.model)
        fixture.system.filesToChoose = [
            try collection(named: "Petstore"), try collection(named: "Shop"), try collection(named: "Zoo"), try collection(named: "Farm")
        ]

        await importer.chooseCollection()
        XCTAssertEqual(importer.name, "Petstore")
        await importer.chooseCollection()
        XCTAssertEqual(importer.name, "Shop", "a name the collection gave follows the next one")
        importer.name = "Mine"
        await importer.chooseCollection()
        XCTAssertEqual(importer.name, "Mine")
        importer.name = " "
        await importer.chooseCollection()

        XCTAssertEqual(importer.collection?.name, "Farm.postman_collection.json")
        XCTAssertEqual(importer.name, "Farm", "an emptied name takes the collection's again")
        XCTAssertTrue(importer.canImport)
    }

    func testAFileOfTheWrongKindSaysWhereItGoes() async throws {
        let importer = PostmanImportModel(app: fixture.model)
        let environment = try write(#"{"name": "Staging", "values": []}"#, as: "staging.json")
        fixture.system.fileToChoose = environment

        await importer.chooseCollection()
        XCTAssertNil(importer.collection)
        XCTAssertEqual(importer.problem, "“staging.json” is a Postman environment or globals export, not a collection. Add it under Environments.")

        fixture.system.fileBatchesToChoose = [[environment, try collection(named: "Shop")]]
        await importer.addVariableFiles()
        XCTAssertEqual(importer.variableFiles.map(\.name), ["staging.json"])
        XCTAssertEqual(importer.problem, "“Shop.postman_collection.json” is a Postman collection, not an environment or globals export. "
            + "Choose it as the collection.")
        XCTAssertFalse(importer.canImport)
    }

    func testImportingWritesTheProjectSelectsItAndSumsItUp() async throws {
        let importer = PostmanImportModel(app: fixture.model)
        fixture.system.fileToChoose = try collection(named: "Petstore", items: """
        [{"name": "Pets", "item": [{"name": "Get pet", "request": {"url": "https://x/pets/:id",
          "auth": {"type": "bearer", "bearer": [{"key": "token", "value": "abc"}]}},
          "event": [{"listen": "test", "script": {"exec": ["tests['ok'] = true"]}}]}]}]
        """)
        fixture.system.fileBatchesToChoose = [[
            try write(#"{"name": "Staging", "values": [{"key": "host", "value": "s"}]}"#, as: "staging.json"),
            try write(#"{"name": "Globals", "_postman_variable_scope": "globals", "values": [{"key": "region", "value": "eu"}]}"#,
                      as: "globals.json")
        ]]
        await importer.chooseCollection()
        await importer.addVariableFiles()

        await importer.startImport()

        let project = try XCTUnwrap(fixture.model.selection?.projectID)
        XCTAssertEqual(fixture.library.document(project)?.name, "Petstore")
        XCTAssertEqual(fixture.component.workspaceState.projectState(project).scriptTrust, .unknown)
        guard case .finished(let summary) = importer.phase else {
            return XCTFail("the import finished")
        }
        XCTAssertEqual(summary.title, "Imported “Petstore”")
        XCTAssertEqual(summary.summary, "1 request in 1 folder and 1 environment.")
        XCTAssertEqual(summary.environments, ["Staging: new, with 1 variable.", "Global: 1 added."])
        XCTAssertEqual(summary.credentials, "Literal passwords, tokens, and API keys are secret variables in Default now, kept in your Keychain: "
            + "bearerToken.")
        XCTAssertEqual(summary.groups.map(\.title), ["Pets ▸ Get pet"])
        XCTAssertEqual(summary.groups.first?.lines, [
            "Post-response script, line 1: tests is from Postman's old script API, which Reqling doesn't have; use pm.test."
        ])
        XCTAssertEqual(summary.trust, "Its scripts run once you trust them: the first request you send with scripts asks.")
        XCTAssertNil(summary.notImported)
    }

    func testAFailedImportStaysOnTheFormWithAnAlert() async throws {
        let importer = PostmanImportModel(app: fixture.model)
        fixture.system.fileToChoose = try collection(named: "Petstore")
        await importer.chooseCollection()
        // A file where the location's folder should be, so the project's folder can't be made.
        importer.location = try write("", as: "not-a-folder")

        await importer.startImport()

        guard case .choosing = importer.phase else {
            return XCTFail("the form stays")
        }
        XCTAssertEqual(fixture.model.alert?.title, "Couldn't Import the Collection")
        XCTAssertTrue(fixture.library.projects.isEmpty)
    }
}
