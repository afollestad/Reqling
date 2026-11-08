import Foundation
@testable import ReqlingKit
import XCTest

/// Postman's body modes as Reqling's, with the files form parts and binary bodies name.
extension PostmanImporterTests {
    func testARawBodyIsSentAsTheTypeItsHeaderOrLanguageGives() throws {
        let plan = try self.plan(items: """
        [{"name": "XML", "request": {"method": "POST", "url": "https://x",
          "body": {"mode": "raw", "raw": "<a/>", "options": {"raw": {"language": "xml"}}}}},
         {"name": "Plain", "request": {"method": "POST", "url": "https://x", "body": {"mode": "raw", "raw": "hi"}}},
         {"name": "Templated", "request": {"method": "POST", "url": "https://x", "header": [{"key": "Content-Type", "value": "{{type}}"}],
          "body": {"mode": "raw", "raw": "{}", "options": {"raw": {"language": "json"}}}}}]
        """)
        let login = try spec(try petstore(), "Auth", "Login")

        XCTAssertEqual(login.body.mode, .raw)
        XCTAssertEqual(login.body.raw, RawBody(text: "{\n  \"user\": \"{{user}}\"\n}", contentType: "application/json"))
        XCTAssertEqual(login.headers, [], "its Content-Type header became the body's type")
        XCTAssertEqual(try spec(plan, "XML").body.raw.contentType, "application/xml")
        XCTAssertEqual(try spec(plan, "Plain").body.raw.contentType, "text/plain", "Postman sends raw text without a language as text")
        let templated = try spec(plan, "Templated")
        XCTAssertEqual(templated.headers.map(\.value), ["{{type}}"], "a header built from variables stays one")
        XCTAssertEqual(templated.body.raw.contentType, "application/json")
    }

    func testFormBodiesKeepTheirRowsAndAGraphQLBodyItsQuery() throws {
        let plan = try petstore()

        let update = try spec(plan, "Pets", "Update pet").body
        XCTAssertEqual(update.mode, .urlEncoded)
        XCTAssertEqual(update.urlEncoded.map(\.key), ["name", "age"])
        XCTAssertEqual(update.urlEncoded.map(\.isEnabled), [true, false])
        let upload = try spec(plan, "Pets", "Upload photo").body
        XCTAssertEqual(upload.mode, .formData)
        XCTAssertEqual(upload.formData.map(\.kind), [.text, .file])
        XCTAssertEqual(upload.formData.first?.value, "Rex")
        XCTAssertNil(upload.formData.last?.file)
        XCTAssertEqual(messages(plan, "Pets", "Upload photo"), [
            "Choose the file for “photo”, which Postman had at “/nonexistent/rex.png”; it isn't on this Mac."
        ])
        let search = try spec(plan, "Pets", "Search").body
        XCTAssertEqual(search.mode, .graphQL)
        XCTAssertEqual(search.graphQL.query, "query { pets { id } }")
        XCTAssertEqual(search.graphQL.variables, "{\"first\": 2}")
    }

    /// A file is found beside the collection, and each file a part's `src` lists gets a part of its own.
    func testFilesFoundOnThisMacAreKeptForTheProjectToPointAt() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        try Data("a".utf8).write(to: directory.file("a.png"))
        try Data("b".utf8).write(to: directory.file("b.png"))
        let plan = try self.plan(items: """
        [{"name": "Upload", "request": {"method": "POST", "url": "https://x", "body": {"mode": "formdata",
          "formdata": [{"key": "photos", "type": "file", "src": ["a.png", "b.png"]}, {"key": "none", "type": "file", "src": null}]}}},
         {"name": "Binary", "request": {"method": "PUT", "url": "https://x", "header": [{"key": "Content-Type", "value": "image/png"}],
          "body": {"mode": "file", "file": {"src": "a.png"}}}}]
        """, directory: directory.url)

        let upload = try spec(plan, "Upload").body.formData
        XCTAssertEqual(upload.map(\.key), ["photos", "photos", "none"])
        let binary = try spec(plan, "Binary").body
        XCTAssertEqual(binary.mode, .binary)
        XCTAssertEqual(binary.binary.contentType, "image/png")
        XCTAssertEqual(plan.files.map(\.url.lastPathComponent), ["a.png", "b.png", "a.png"])
        XCTAssertEqual(plan.files.map(\.target), [.formField(upload[0].id), .formField(upload[1].id), .binary])
        XCTAssertEqual(messages(plan, "Upload"), ["Choose the file for “none”, which Postman didn't name."])
    }

    func testATurnedOffBodyKeepsItsContentAndAGETBodyIsNoted() throws {
        let plan = try self.plan(items: """
        [{"name": "Off", "request": {"method": "POST", "url": "https://x", "body": {"mode": "raw", "raw": "kept", "disabled": true}}},
         {"name": "Get", "protocolProfileBehavior": {"disableBodyPruning": true},
          "request": {"method": "GET", "url": "https://x", "body": {"mode": "raw", "raw": "{}"}}}]
        """)

        let off = try spec(plan, "Off").body
        XCTAssertEqual(off.mode, .none)
        XCTAssertEqual(off.raw.text, "kept")
        XCTAssertEqual(messages(plan, "Get"), ["Postman sent its body with GET, which Reqling never does; it's kept for another method."])
    }
}
