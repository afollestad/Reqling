import Foundation
@testable import ReqlingKit
import ReqlingScriptProtocol
import XCTest

/// Postman collections, environments, and globals mapped to a project, before anything is written.
final class PostmanImporterTests: XCTestCase {
    static func fixture(_ name: String) throws -> URL {
        try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "PostmanFixtures"))
    }

    static func file(_ name: String) throws -> PostmanFile {
        try PostmanFile.read(fixture(name))
    }

    static func collection(_ file: PostmanFile) throws -> PostmanCollection {
        if case .collection(let collection) = file {
            return collection
        }
        return try XCTUnwrap(nil, "not a collection")
    }

    func petstore(files: [PostmanFile] = []) throws -> ProjectImport {
        PostmanImporter.plan(try Self.collection(Self.file("petstore.postman_collection")), files: files, collectionDirectory: nil)
    }

    /// A v2.1 collection holding `items`, with any other top-level fields `extra` writes.
    func plan(items: String, extra: String = "", files: [PostmanFile] = [], directory: URL? = nil) throws -> ProjectImport {
        let json = """
        {"info": {"name": "Test", "schema": "https://schema.getpostman.com/json/collection/v2.1.0/collection.json"}, \
        \(extra.isEmpty ? "" : extra + ",") "item": \(items)}
        """
        return PostmanImporter.plan(try Self.collection(PostmanFile.read(Data(json.utf8), named: "test.json")), files: files,
                                    collectionDirectory: directory)
    }

    /// The node at the names of its folders and its own.
    func node(_ plan: ProjectImport, _ path: String...) -> RequestNode? {
        var nodes = plan.items
        var found: RequestNode?
        for name in path {
            found = nodes.first { $0.name == name }
            guard case .folder(let folder)? = found else {
                nodes = []
                continue
            }
            nodes = folder.children
        }
        return found
    }

    func spec(_ plan: ProjectImport, _ path: String...) throws -> HTTPRequestSpec {
        var nodes = plan.items
        var found: RequestNode?
        for name in path {
            found = nodes.first { $0.name == name }
            if case .folder(let folder)? = found {
                nodes = folder.children
            }
        }
        guard case .request(let request)? = found else {
            return try XCTUnwrap(nil, "no request at \(path)")
        }
        return try XCTUnwrap(request.kind.httpSpec)
    }

    func messages(_ plan: ProjectImport, _ path: String...) -> [String] {
        plan.notes.filter { $0.owner == (path.isEmpty ? .project : .node(path)) }.map(\.message)
    }

    // MARK: - Files

    func testFilesAreRecognizedByWhatTheyHold() throws {
        guard case .collection(let collection) = try Self.file("petstore.postman_collection") else {
            return XCTFail("a collection")
        }
        guard case .environment(let staging) = try Self.file("staging.postman_environment"),
              case .globals(let globals) = try Self.file("workspace.postman_globals") else {
            return XCTFail("an environment and globals")
        }

        XCTAssertEqual(collection.name, "Petstore")
        XCTAssertEqual(staging.name, "Staging")
        XCTAssertEqual(staging.variables.map(\.key), ["baseUrl", "apiSecret", "retries"])
        XCTAssertEqual(globals.variables.map(\.key), ["region"])
        XCTAssertThrowsError(try PostmanFile.read(Data(#"{"requests": [], "order": []}"#.utf8), named: "old.json")) { error in
            XCTAssertEqual(error as? PostmanImportError, .collectionV1("old.json"))
        }
        XCTAssertThrowsError(try PostmanFile.read(Data(#"{"openapi": "3.0.0"}"#.utf8), named: "api.json")) { error in
            XCTAssertEqual(error as? PostmanImportError, .notPostman("api.json"))
        }
        XCTAssertThrowsError(try PostmanFile.read(Data("not json".utf8), named: "x.txt")) { error in
            XCTAssertEqual(error as? PostmanImportError, .notJSON("x.txt"))
        }
    }

    // MARK: - Tree

    func testFoldersAndRequestsKeepTheirStructureAndOrder() throws {
        let plan = try petstore()

        XCTAssertEqual(plan.name, "Petstore")
        XCTAssertEqual(plan.items.map(\.name), ["Auth", "Pets"])
        guard case .folder(let pets)? = node(plan, "Pets") else {
            return XCTFail("Pets is a folder")
        }
        XCTAssertEqual(pets.children.map(\.name), ["Get pet", "Upload photo", "Update pet", "Search", "Health"])
        XCTAssertEqual(plan.counts.requests, 6)
        XCTAssertEqual(plan.counts.folders, 2)
        // The descriptions are the collection's, the Auth folder's, and Login's request's.
        XCTAssertEqual(plan.counts.omitted, [.descriptions: 3, .savedResponses: 1])
        XCTAssertEqual(try spec(plan, "Pets", "Update pet").method, .patch)
        XCTAssertEqual(try spec(plan, "Pets", "Health").method, .get, "a request given as its URL alone is a GET")
    }

    func testANamelessItemAndACustomMethodKeepWhatTheyCan() throws {
        let plan = try self.plan(items: #"[{"name": "  ", "request": {"method": "PURGE", "url": "https://x/cache"}}]"#)

        XCTAssertEqual(plan.items.map(\.name), ["Untitled"])
        XCTAssertEqual(try spec(plan, "Untitled").method.rawValue, "PURGE")
    }

    // MARK: - URLs and headers

    func testTheQueryKeepsTurnedOffRowsAndPathVariablesKeepTheirValues() throws {
        let plan = try petstore()
        let getPet = try spec(plan, "Pets", "Get pet")

        XCTAssertEqual(getPet.url, "{{baseUrl}}/pets/:petId")
        XCTAssertEqual(getPet.pathVariables.map { "\($0.key)=\($0.value)" }, ["petId=42"])
        XCTAssertEqual(getPet.queryParameters.map(\.key), ["expand", "trace"])
        XCTAssertEqual(getPet.queryParameters.map(\.isEnabled), [true, false], "Postman's query list keeps the rows raw leaves out")
        XCTAssertEqual(try spec(plan, "Pets", "Health").url, "https://api.example.com/health")
    }

    func testAURLWithoutAQueryListOrRawIsSplitOrRebuilt() throws {
        let plan = try self.plan(items: """
        [{"name": "Raw", "request": {"url": {"raw": "http://localhost:8080/a/:id?x=1#top"}}},
         {"name": "Parts", "request": {"url": {"protocol": "https", "host": ["api", "example", "com"], "port": "8443", "path": ["v1", "users"]}}}]
        """)

        let raw = try spec(plan, "Raw")
        XCTAssertEqual(raw.url, "http://localhost:8080/a/:id", "the fragment is dropped")
        XCTAssertEqual(raw.pathVariables.map { "\($0.key)=\($0.value)" }, ["id="], "the port isn't a path variable")
        XCTAssertEqual(raw.queryParameters.map(\.key), ["x"])
        XCTAssertEqual(messages(plan, "Raw"), [])
        XCTAssertEqual(try spec(plan, "Parts").url, "https://api.example.com:8443/v1/users")
    }

    func testHeadersKeepTurnedOffRowsAndReadFromText() throws {
        let plan = try self.plan(items: #"[{"name": "Text", "request": {"url": "https://x", "header": "Accept: text/html\nX-Id: 1"}}]"#)

        XCTAssertEqual(try spec(try petstore(), "Pets", "Get pet").headers.map(\.isEnabled), [true, false])
        XCTAssertEqual(try spec(plan, "Text").headers.map { "\($0.key)=\($0.value)" }, ["Accept=text/html", "X-Id=1"])
    }

    func testSettingsCarryDownToTheRequestsThatDontSetThem() throws {
        let plan = try petstore()

        XCTAssertEqual(try spec(plan, "Pets", "Health").options.followRedirects, false, "the collection's")
        XCTAssertEqual(try spec(plan, "Pets", "Get pet").disabledAutoHeaders, ["user-agent"], "Connection isn't one Reqling can turn off")
        XCTAssertEqual(try spec(plan, "Pets", "Health").disabledAutoHeaders, [])
    }
}
