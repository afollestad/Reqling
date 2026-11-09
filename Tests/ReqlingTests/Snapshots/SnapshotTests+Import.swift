import Foundation
import SwiftUI
import XCTest

@testable import Reqling

/// The import sheet's form, with a Postman collection, an environment, and globals chosen, and with an OpenAPI document
/// loaded. Its summary is prose that reflows across macOS versions, so `ImportModelTests` checks its wording as text
/// instead.
extension SnapshotTests {
    func testImportFormPostman() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SnapshotTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        func write(_ json: String, _ name: String) throws -> URL {
            let url = directory.appendingPathComponent(name)
            try Data(json.utf8).write(to: url)
            return url
        }
        // Served from a URL, which reads the same on every Mac, unlike a temporary file's path.
        let url = try XCTUnwrap(URL(string: "https://example.com/Petstore.postman_collection.json"))
        fixture.importFetcher.serve(#"{"info": {"name": "Petstore"}, "item": [{"name": "List pets", "request": "https://x/pets"}]}"#, at: url)
        fixture.system.fileBatchesToChoose = [[
            try write(#"{"name": "Staging", "values": []}"#, "Staging.postman_environment.json"),
            try write(#"{"name": "Globals", "_postman_variable_scope": "globals", "values": []}"#, "workspace.postman_globals.json")
        ]]
        let importer = ImportModel(app: fixture.model)
        importer.sourceText = url.absoluteString
        await importer.load()
        await importer.addVariableFiles()

        assertBothAppearances(ImportSheet(importer: importer), size: CGSize(width: 560, height: 400))
    }

    func testImportFormOpenAPI() async throws {
        let url = try XCTUnwrap(URL(string: "https://api.example.com/openapi.yaml"))
        fixture.importFetcher.serve("""
        openapi: 3.1.0
        info: {title: Petstore, version: '1'}
        paths:
          /pets: {get: {responses: {}}, post: {responses: {}}}
          /owners: {$ref: 'owners.yaml#/owners'}
        """, at: url)
        let importer = ImportModel(app: fixture.model)
        importer.sourceText = url.absoluteString
        await importer.load()

        assertBothAppearances(ImportSheet(importer: importer), size: CGSize(width: 560, height: 330))
    }
}
