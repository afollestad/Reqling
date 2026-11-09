import Foundation
@testable import ReqlingKit
import XCTest

/// Loading the documents an OpenAPI document's references name: once each, within the rules for files and URLs.
final class OpenAPILoaderTests: XCTestCase {
    static func fixture(_ name: String, _ ext: String, in subdirectory: String = "OpenAPIFixtures") throws -> URL {
        try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: ext, subdirectory: subdirectory))
    }

    static func load(_ url: URL, fetcher: any ImportFetching = LiveImportFetcher()) async throws -> OpenAPISource {
        let (data, finalURL) = try await fetcher.data(from: url)
        guard case .openAPI(let document) = try ImportDocument.read(data, location: finalURL) else {
            throw XCTSkip("not OpenAPI")
        }
        return await OpenAPILoader.load(document, fetcher: fetcher)
    }

    func testASiblingFileLoadsOnceThoughItRefersBack() async throws {
        let source = try await Self.load(try Self.fixture("petstore", "yaml"))

        XCTAssertEqual(source.documents.count, 2, "\(source.documents.keys)")
        XCTAssertEqual(source.failures, [:])
        XCTAssertEqual(source.problems, [])
        XCTAssertEqual(source.operationCount, 8)
    }

    func testAFetchedDocumentFollowsWebReferencesButNeverFiles() async throws {
        let host = StubURLProtocol.register { request in
            switch request.url?.path {
            case "/specs/api.yaml":
                .response(status: 200, body: Data("""
                openapi: 3.1.0
                info: {title: Remote, version: '1'}
                servers: [{url: /v2}]
                paths:
                  /a: {$ref: 'paths.yaml#/a'}
                  /b: {$ref: 'file:///etc/hosts#/b'}
                  /c: {$ref: 'missing.yaml#/c'}
                """.utf8))
            case "/specs/paths.yaml":
                .response(status: 200, body: Data("a: {get: {summary: A, responses: {}}}\n".utf8))
            default:
                .response(status: 404)
            }
        }
        let fetcher = LiveImportFetcher(configuration: StubURLProtocol.configuration())
        let rootURL = try XCTUnwrap(URL(string: "https://\(host)/specs/api.yaml"))

        let source = try await Self.load(rootURL, fetcher: fetcher)
        let plan = OpenAPIImporter.plan(source)

        let fetched = StubURLProtocol.requests(to: host).compactMap(\.url?.path).sorted()
        XCTAssertEqual(fetched, ["/specs/api.yaml", "/specs/missing.yaml", "/specs/paths.yaml"])
        XCTAssertEqual(source.problems.count, 2, "\(source.problems)")
        XCTAssertTrue(source.problems.contains { $0.contains("never reads files on this Mac") }, "\(source.problems)")
        XCTAssertTrue(source.problems.contains { $0.contains("answered 404") }, "\(source.problems)")
        XCTAssertEqual(plan.items.map(\.name), ["A"])
        let baseURL = plan.defaultVariables.first { $0.key == "baseUrl" }?.value
        XCTAssertEqual(baseURL, "https://\(host)/v2", "A relative server is the fetched document's")
        XCTAssertEqual(plan.notes.filter { $0.topic == .url }.count, 2, "The paths whose items couldn't load are noted")
    }

    func testADocumentReadFromAFileDoesntFetch() {
        let root = URL(fileURLWithPath: "/tmp/api/openapi.yaml")

        XCTAssertNil(OpenAPILoader.refusal(of: URL(fileURLWithPath: "/tmp/common.yaml"), root: root))
        XCTAssertNotNil(OpenAPILoader.refusal(of: URL(string: "https://example.com/common.yaml")!, root: root))
        XCTAssertNil(OpenAPILoader.refusal(of: URL(string: "https://example.com/common.yaml")!, root: URL(string: "https://example.com/api.yaml")!))
    }
}
