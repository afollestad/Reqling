import Foundation
import GraphQLFixtureServer
import MCP
@testable import ReqlingKit
import XCTest

/// The GraphQL tools, through the dispatcher, against the fixture server: a request created through the tools, its
/// schema introspected with the request's own secret token.
@MainActor
final class MCPGraphQLToolsTests: XCTestCase {
    private var fixture: MCPFixture!
    private var server: GraphQLFixtureServer!
    private var project: ProjectID!
    private var request: String!

    override func setUp() async throws {
        fixture = try MCPFixture()
        server = try await GraphQLFixtureServer.start(.init(requiredBearerToken: "t0ken-secret"))
        project = try await fixture.makeProject()
        _ = try await fixture.success("create_variables", ["project": .string(project.description), "variables": [
            ["key": "endpoint", "value": .string(server.url.absoluteString)],
            ["key": "token", "value": "t0ken-secret", "secret": true]
        ]])
        let created = try await fixture.success("create_request", [
            "project": .string(project.description),
            "name": "Books",
            "http": [
                "method": "POST",
                "url": "{{endpoint}}",
                "auth": ["type": "bearer", "token": "{{token}}"],
                "body": ["mode": "graphql", "graphql": ["query": "{ me { nmae } }"]]
            ]
        ])
        request = try XCTUnwrap(created["request"]?["id"]?.stringValue)
    }

    override func tearDown() async throws {
        try await server.shutdown()
        fixture.cleanUp()
    }

    private var target: [String: Value] {
        ["project": .string(project.description), "request": .string(request)]
    }

    func testListTypesReadsTheSchemaThroughTheRequest() async throws {
        let all = try await fixture.success("graphql_list_types", target)
        let enums = try await fixture.success("graphql_list_types", target.merging(["kind": "enum", "query": "gen"]) { $1 })

        XCTAssertEqual(all["roots"]?["query"], "Root")
        XCTAssertEqual(all["source"]?["introspection"]?.stringValue, server.url.absoluteString)
        let names = all["types"]?.arrayValue?.compactMap { $0["name"]?.stringValue } ?? []
        XCTAssertTrue(names.contains("Book"))
        XCTAssertFalse(names.contains { $0.hasPrefix("__") })
        XCTAssertNil(all["types"]?.arrayValue?.first?["description"], "an unfiltered list leaves descriptions out")
        XCTAssertEqual(enums["types"]?.arrayValue?.compactMap { $0["name"]?.stringValue }, ["Genre"])
        XCTAssertEqual(server.requests.count, 2, "the second call came from the cache")
    }

    func testDescribeTypeShowsSDLAndWhatUsesIt() async throws {
        let node = try await fixture.success("graphql_describe_type", target.merging(["name": "Node"]) { $1 })
        let tag = try await fixture.success("graphql_describe_type", target.merging(["name": "@tag"]) { $1 })
        let missing = await fixture.failure("graphql_describe_type", target.merging(["name": "Nope"]) { $1 })

        XCTAssertEqual(node["sdl"]?.stringValue?.hasPrefix("\"\"\"\nAnything with a global ID.\n\"\"\"\ninterface Node"), true)
        XCTAssertEqual(Set(node["implementedBy"]?.arrayValue?.compactMap(\.stringValue) ?? []), ["Author", "Book", "Entity"])
        XCTAssertEqual(node["usedBy"]?.arrayValue?.compactMap(\.stringValue), ["Root.node"])
        XCTAssertEqual(tag["sdl"]?.stringValue?.contains("repeatable on FIELD"), true)
        XCTAssertTrue(missing.contains("graphql_list_types"))
    }

    func testValidateChecksTheRequestsQueryOrAnotherWithLinesAndColumns() async throws {
        let own = try await fixture.success("graphql_validate", target)
        let other = try await fixture.success("graphql_validate", target.merging(["query": "{\n  me { name }\n  pnig\n}"]) { $1 })
        let clean = try await fixture.success("graphql_validate", target.merging(["query": "{ ping }"]) { $1 })

        XCTAssertEqual(own["valid"], false)
        let diagnostic = try XCTUnwrap(other["diagnostics"]?.arrayValue?.first)
        XCTAssertEqual(diagnostic["line"], 3)
        XCTAssertEqual(diagnostic["column"], 3)
        XCTAssertEqual(diagnostic["text"], "pnig")
        XCTAssertEqual(diagnostic["severity"], "error")
        XCTAssertEqual(clean["valid"], true)
        XCTAssertEqual(clean["diagnostics"]?.arrayValue?.count, 0)
    }

    func testANonGraphQLRequestIsRefusedAndASecretNeverComesBack() async throws {
        let plain = try await fixture.success("create_request", [
            "project": .string(project.description),
            "name": "Plain",
            "http": ["url": "{{endpoint}}"]
        ])
        let refused = await fixture.failure("graphql_list_types", [
            "project": .string(project.description),
            "request": .string(try XCTUnwrap(plain["request"]?["id"]?.stringValue))
        ])
        try await server.shutdown()
        server = try await GraphQLFixtureServer.start(.init(override: { request in
            .text("rejected \(request.header("Authorization") ?? "")", status: 500)
        }))
        _ = try await fixture.success("update_variables", ["project": .string(project.description), "variables": [
            ["key": "endpoint", "value": .string(server.url.absoluteString)]
        ]])
        let echoed = await fixture.failure("graphql_list_types", target.merging(["refresh": true]) { $1 })

        XCTAssertTrue(refused.contains("does not send a GraphQL body"), refused)
        XCTAssertTrue(echoed.contains("500"), echoed)
        XCTAssertFalse(echoed.contains("t0ken-secret"), echoed)
    }
}
