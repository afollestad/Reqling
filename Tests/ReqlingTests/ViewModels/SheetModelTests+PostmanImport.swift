import Foundation
import ReqlingKit
import XCTest

@testable import Reqling

/// Postman environments and globals imported into an existing project from its Environments sheet.
extension SheetModelTests {
    private func postmanFile(_ json: String, named name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("SheetModelTests-\(UUID().uuidString)-\(name)")
        try Data(json.utf8).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testPostmanEnvironmentsMergeIntoTheDraftAndSaveOnDone() async throws {
        let host = Variable(key: "host", value: "old")
        try fixture.library.mutate(project) { document in
            document.environments = [RequestEnvironment(name: "Staging", variables: [host])]
        }
        let editor = EnvironmentEditorModel(projectID: project, app: fixture.model)
        fixture.system.fileBatchesToChoose = [[
            try postmanFile(#"{"name": "staging", "values": [{"key": "host", "value": "new"}, "#
                + #"{"key": "token", "value": "s3cr3t", "type": "secret"}]}"#, named: "staging.json"),
            try postmanFile(#"{"name": "Globals", "_postman_variable_scope": "globals", "values": [{"key": "region", "value": "eu"}]}"#,
                            named: "globals.json")
        ]]

        await editor.importPostmanEnvironments()

        XCTAssertEqual(editor.postmanImportNote, "Staging: 1 updated, 1 added. Global: 1 added. Done saves them.")
        XCTAssertEqual(editor.selected.name, "Staging")
        XCTAssertEqual(fixture.library.document(project)?.environments.first?.variables.map(\.value), ["old"], "nothing is saved before Done")
        XCTAssertTrue(editor.save())
        let staging = try XCTUnwrap(fixture.library.document(project)?.environments.first)
        XCTAssertEqual(staging.variables.first?.id, host.id)
        XCTAssertEqual(staging.variables.map(\.value), ["new", "s3cr3t"])
        let file = try XCTUnwrap(fixture.library.project(project)?.url.appendingPathComponent("environments/staging.json"))
        XCTAssertFalse(try String(contentsOf: file, encoding: .utf8).contains("s3cr3t"))
        XCTAssertEqual(fixture.library.globalEnvironment.variables.map(\.value), ["eu"])
    }

    func testACollectionIsRefusedWithWhereToImportIt() async throws {
        let editor = EnvironmentEditorModel(projectID: project, app: fixture.model)
        let collection = try postmanFile(#"{"info": {"name": "API"}, "item": []}"#, named: "api.json")
        fixture.system.fileBatchesToChoose = [[collection]]

        await editor.importPostmanEnvironments()

        XCTAssertNil(editor.postmanImportNote)
        XCTAssertEqual(fixture.model.alert?.message, "“\(collection.lastPathComponent)” is a Postman collection, not an environment or "
            + "globals export. Import it with File ▸ Import Postman Collection….")
    }
}
