import Foundation
import ReqlingKit
import XCTest

@testable import Reqling

/// The import sheet's flow: loading a source, naming the project, importing it, and what the summary says.
@MainActor
final class ImportModelTests: XCTestCase {
    private var fixture: AppFixture!
    private var directory: URL!

    override func setUp() async throws {
        fixture = AppFixture()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ImportModelTests-\(UUID().uuidString)")
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
        let importer = ImportModel(app: fixture.model)
        fixture.system.filesToChoose = [
            try collection(named: "Petstore"), try collection(named: "Shop"), try collection(named: "Zoo"), try collection(named: "Farm")
        ]

        await importer.chooseFile()
        XCTAssertEqual(importer.name, "Petstore")
        await importer.chooseFile()
        XCTAssertEqual(importer.name, "Shop", "a name the collection gave follows the next one")
        importer.name = "Mine"
        await importer.chooseFile()
        XCTAssertEqual(importer.name, "Mine")
        importer.name = " "
        await importer.chooseFile()

        XCTAssertTrue(importer.sourceText.hasSuffix("Farm.postman_collection.json"), importer.sourceText)
        XCTAssertEqual(importer.found, "Postman collection · “Farm” · 0 requests")
        XCTAssertEqual(importer.name, "Farm", "an emptied name takes the collection's again")
        XCTAssertTrue(importer.canImport)
    }

    func testAFileOfTheWrongKindSaysWhereItGoes() async throws {
        let importer = ImportModel(app: fixture.model)
        let environment = try write(#"{"name": "Staging", "values": []}"#, as: "staging.json")
        fixture.system.fileToChoose = environment

        await importer.chooseFile()
        XCTAssertNil(importer.source)
        XCTAssertEqual(importer.problem, "“staging.json” is a Postman environment or globals export, not a collection.")
        XCTAssertFalse(importer.canImport)

        fixture.system.fileToChoose = try collection(named: "Shop")
        await importer.chooseFile()
        fixture.system.fileBatchesToChoose = [[environment, try collection(named: "Zoo")]]
        await importer.addVariableFiles()
        XCTAssertEqual(importer.variableFiles.map(\.name), ["staging.json"])
        XCTAssertEqual(importer.problem, "“Zoo.postman_collection.json” is a Postman collection, not an environment or globals export. "
            + "Import it as its own project.")
    }

    func testImportingWritesTheProjectSelectsItAndSumsItUp() async throws {
        let importer = ImportModel(app: fixture.model)
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
        await importer.chooseFile()
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

    func testAnOpenAPIDocumentAtAURLLoadsWhatItRefersToBeforeImport() async throws {
        let url = try XCTUnwrap(URL(string: "https://api.test/specs/openapi.yaml"))
        fixture.importFetcher.serve("""
        openapi: 3.1.0
        info: {title: Zoo, version: '1'}
        servers: [{url: /v1}]
        security: [{token: []}]
        paths:
          /animals/{id}:
            get:
              summary: Get an animal
              parameters: [{name: id, in: path, required: true, schema: {$ref: 'common.yaml#/Id'}}]
              responses: {}
          /keepers: {$ref: 'missing.yaml#/keepers'}
        components:
          securitySchemes:
            token: {type: http, scheme: bearer}
        """, at: url)
        fixture.importFetcher.serve("Id: {type: integer, example: 7}\n", at: try XCTUnwrap(URL(string: "https://api.test/specs/common.yaml")))
        let importer = ImportModel(app: fixture.model)

        importer.sourceText = url.absoluteString
        await importer.load()

        XCTAssertEqual(importer.found, "OpenAPI 3.1.0 · “Zoo” · 1 operation")
        XCTAssertEqual(importer.loadProblems, ["“https://api.test/specs/missing.yaml”: The server answered 404."])
        XCTAssertFalse(importer.isPostman, "No environments to add")
        XCTAssertEqual(importer.name, "Zoo")

        await importer.startImport()

        let project = try XCTUnwrap(fixture.model.selection?.projectID)
        let document = try XCTUnwrap(fixture.library.document(project))
        XCTAssertEqual(fixture.component.workspaceState.projectState(project).scriptTrust, .trusted)
        guard case .request(let request)? = document.items.first, let spec = request.kind.httpSpec else {
            return XCTFail("a request")
        }
        XCTAssertEqual(spec.url, "{{baseUrl}}/animals/:id")
        XCTAssertEqual(spec.pathVariables.first?.value, "7")
        XCTAssertEqual(document.defaultEnvironment.variables.first?.value, "https://api.test/v1")
        guard case .finished(let summary) = importer.phase else {
            return XCTFail("the import finished")
        }
        XCTAssertEqual(summary.summary, "1 request.")
        XCTAssertEqual(summary.credentialsToFill, "Fill in these secret variables in Default, kept in your Keychain: bearerToken.")
        XCTAssertEqual(summary.groups.map(\.title), ["Project"])
        XCTAssertNil(summary.trust)
    }

    func testEditingTheSourceDropsWhatWasLoadedAndSwaggerSaysHowToConvert() async throws {
        let importer = ImportModel(app: fixture.model)
        fixture.system.fileToChoose = try write(#"{"swagger": "2.0", "info": {"title": "Old"}}"#, as: "old.json")

        await importer.chooseFile()
        XCTAssertEqual(importer.problem, "“old.json” is a Swagger 2.0 document. Convert it to OpenAPI 3, as Swagger Editor's Convert to "
            + "OpenAPI 3 does, then import that.")

        importer.sourceText = try collection(named: "Shop").path
        await importer.load()
        XCTAssertTrue(importer.canImport)
        importer.sourceText += " "
        XCTAssertNil(importer.source)
        XCTAssertFalse(importer.canImport)
    }

    func testAFailedImportStaysOnTheFormWithAnAlert() async throws {
        let importer = ImportModel(app: fixture.model)
        fixture.system.fileToChoose = try collection(named: "Petstore")
        await importer.chooseFile()
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
