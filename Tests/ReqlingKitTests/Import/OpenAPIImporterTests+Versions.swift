import Foundation
@testable import ReqlingKit
import XCTest

/// OpenAPI 3.2's additions: nested and non-navigation tags, the `query` method and other operations, the whole-query
/// parameter, `dataValue` examples, and `$self`.
extension OpenAPIImporterTests {
    func testVersion32Additions() async throws {
        let plan = OpenAPIImporter.plan(try await OpenAPILoaderTests.load(try OpenAPILoaderTests.fixture("v32", "yaml")))

        XCTAssertEqual(plan.items.map(\.name), ["admin", "orphans", "Filter"])
        guard case .folder(let admin)? = node(plan, "admin") else {
            return XCTFail("the admin folder")
        }
        XCTAssertEqual(admin.children.map(\.name), ["users"], "A tag's parent nests its folder")
        let search = try spec(plan, "admin", "users", "Search")
        XCTAssertEqual(search.method.rawValue, "QUERY", "Its badge tag isn't a folder")
        XCTAssertEqual(search.body.raw.text, "{\n  \"term\": \"pets\"\n}")
        XCTAssertEqual(try spec(plan, "orphans", "Purge").method.rawValue, "PURGE")
        XCTAssertEqual(try spec(plan, "Filter").queryParameters.map { "\($0.key)=\($0.value)" }, ["status=open", "page=2"])
        XCTAssertEqual(plan.defaultVariables.first { $0.key == "baseUrl" }?.value, "https://api.example.com/api", "Relative to its $self")
        XCTAssertTrue(messages(plan, .project).contains(
            "The tag “orphans” names “nobody” as its parent, which isn't a tag, so its folder is at the top."
        ))
        XCTAssertTrue(messages(plan, .project).contains("/search: Its “BAD METHOD” operation isn't imported: that isn't an HTTP method."))
    }

    func testALaterVersionImportsWithANote() async throws {
        let plan = try await plan("openapi: 3.3.0\ninfo: {title: Next, version: '1'}\npaths: {}\n")

        XCTAssertEqual(messages(plan, .project), ["It's OpenAPI 3.3.0; what it shares with OpenAPI 3.2 is imported."])
        XCTAssertEqual(plan.defaultVariables.map { "\($0.key)=\($0.value)" }, ["baseUrl="], "No servers means /, trimmed")
    }
}
