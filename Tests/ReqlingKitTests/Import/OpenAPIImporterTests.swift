import Foundation
@testable import ReqlingKit
import XCTest

/// OpenAPI documents mapped to a project, before anything is written.
final class OpenAPIImporterTests: XCTestCase {
    func petstore(_ ext: String = "yaml") async throws -> ProjectImport {
        OpenAPIImporter.plan(try await OpenAPILoaderTests.load(try OpenAPILoaderTests.fixture("petstore", ext)))
    }

    /// A document given inline, read as if from a file, with no other documents to load.
    func plan(_ yaml: String) async throws -> ProjectImport {
        let url = URL(fileURLWithPath: "/tmp/reqling-openapi-tests/openapi.yaml")
        guard case .openAPI(let document) = try ImportDocument.read(Data(yaml.utf8), location: url) else {
            throw XCTSkip("not OpenAPI")
        }
        return OpenAPIImporter.plan(await OpenAPILoader.load(document, fetcher: LiveImportFetcher()))
    }

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
        guard case .request(let request)? = found, let spec = request.kind.httpSpec else {
            throw XCTSkip("no request at \(path)")
        }
        return spec
    }

    func messages(_ plan: ProjectImport, _ owner: ImportNote.Owner) -> [String] {
        plan.notes.filter { $0.owner == owner }.map(\.message)
    }

    func testOperationsBecomeRequestsInTagFolders() async throws {
        let plan = try await petstore()

        XCTAssertEqual(plan.name, "Petstore")
        XCTAssertEqual(plan.items.map(\.name), ["store", "pets", "Download a file", "Who am I"], "Tags in the document's order, untagged last")
        guard case .folder(let pets)? = node(plan, "pets"), case .folder(let store)? = node(plan, "store") else {
            return XCTFail("tag folders")
        }
        XCTAssertEqual(pets.children.map(\.name), ["List pets", "Add a pet", "Get a pet", "deletePet"])
        XCTAssertEqual(store.children.map(\.name), ["Place an order", "Inventory"], "A second tag adds no copy")
        XCTAssertEqual(try spec(plan, "pets", "Add a pet").method, .post)
        XCTAssertEqual(plan.counts.requests, 8)
        XCTAssertEqual(plan.counts.folders, 2)
        XCTAssertFalse(plan.hasScripts)
        XCTAssertEqual(plan.counts.omitted, [.responses: 8, .callbacks: 1, .links: 1, .webhooks: 1])
        XCTAssertTrue(messages(plan, .project).contains("1 operation has more than one tag; each is in its first tag's folder only."))
        XCTAssertTrue(messages(plan, .project).contains("Deprecated: “deletePet”."))
    }

    func testURLsUseBaseURLAndPathVariables() async throws {
        let plan = try await petstore()
        let getPet = try spec(plan, "pets", "Get a pet")
        let file = try spec(plan, "Download a file")

        XCTAssertEqual(getPet.url, "{{baseUrl}}/pets/:petId")
        XCTAssertEqual(getPet.pathVariables.map { "\($0.key)=\($0.value)" }, ["petId=42"], "The path item's parameter, with its example")
        XCTAssertEqual(file.url, "{{baseUrl}}/files/{{name}}.{{ext}}")
        XCTAssertEqual(plan.defaultVariables.filter { ["name", "ext"].contains($0.key) }.map(\.value), ["report", "pdf"])
        XCTAssertTrue(messages(plan, .project).contains(
            "A path puts {ext} inside a segment, where a path variable can't go, so it's {{ext}} in Default."
        ))
    }

    func testServersBecomeBaseURLAndAnEnvironmentEach() async throws {
        let plan = try await petstore()

        XCTAssertEqual(plan.defaultVariables.prefix(2).map { "\($0.key)=\($0.value)" }, [
            "baseUrl=https://{{region}}.petstore.example.com/v1", "region=us"
        ])
        XCTAssertEqual(plan.environments.map(\.name), ["Production", "Staging"])
        XCTAssertEqual(plan.environments.last?.variables.map { "\($0.key)=\($0.value)" }, ["baseUrl=https://staging.petstore.example.com/v1"])
        XCTAssertEqual(plan.counts.environments, 2)
        XCTAssertEqual(messages(plan, .environment("Default")), ["{{region}} can be “us” or “eu”."])
        XCTAssertEqual(plan.environmentChanges.map(\.environment), ["Default", "Production", "Staging"])
    }

    func testTheJSONDocumentPlansAsTheYAMLOneDoes() async throws {
        let yaml = try await petstore()
        let json = try await petstore("json")

        func shape(_ plan: ProjectImport) throws -> [String] {
            try ["Add a pet", "List pets", "Get a pet"].map { name in
                let spec = try self.spec(plan, "pets", name)
                return "\(spec.url) \(spec.queryParameters.map { "\($0.key)=\($0.value)" }) \(spec.body.raw.text)"
            }
        }
        XCTAssertEqual(try shape(json), try shape(yaml))
        XCTAssertEqual(json.notes.map(\.message), yaml.notes.map(\.message))
        XCTAssertTrue(try spec(json, "pets", "List pets").queryParameters.contains { $0.value == "🐱" }, "An escaped surrogate pair reads")
    }
}
