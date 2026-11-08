import Foundation
import SwiftUI
import XCTest

@testable import Reqling

/// The Postman import sheet's form, with a collection, an environment, and globals chosen. Its summary is prose that
/// reflows across macOS versions, so `PostmanImportModelTests` checks its wording as text instead.
extension SnapshotTests {
    func testPostmanImportForm() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SnapshotTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        func write(_ json: String, _ name: String) throws -> URL {
            let url = directory.appendingPathComponent(name)
            try Data(json.utf8).write(to: url)
            return url
        }
        fixture.system.fileToChoose = try write(#"{"info": {"name": "Petstore"}, "item": []}"#, "Petstore.postman_collection.json")
        fixture.system.fileBatchesToChoose = [[
            try write(#"{"name": "Staging", "values": []}"#, "Staging.postman_environment.json"),
            try write(#"{"name": "Globals", "_postman_variable_scope": "globals", "values": []}"#, "workspace.postman_globals.json")
        ]]
        let importer = PostmanImportModel(app: fixture.model)
        await importer.chooseCollection()
        await importer.addVariableFiles()

        assertBothAppearances(PostmanImportSheet(importer: importer), size: CGSize(width: 520, height: 360))
    }
}
