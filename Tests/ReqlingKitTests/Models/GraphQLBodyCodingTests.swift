import Foundation
import ReqlingKit
import XCTest

/// How a GraphQL body's schema source is stored in its request file.
final class GraphQLBodyCodingTests: XCTestCase {
    /// Files written before the schema source existed must not change when saved again.
    func testTheDefaultSourceIsLeftOutOfTheFile() throws {
        let body = GraphQLBody(query: "{ ping }", variables: "{}", operationName: "Ping")

        let json = try XCTUnwrap(String(data: ProjectJSON.encode(body), encoding: .utf8))

        XCTAssertEqual(json, """
            {
              "operationName" : "Ping",
              "query" : "{ ping }",
              "variables" : "{}"
            }

            """)
    }

    func testASchemaFileRoundTrips() throws {
        let body = GraphQLBody(query: "{ ping }", schema: .file(.relative("schema/api.graphql")))

        let data = try ProjectJSON.encode(body)

        XCTAssertTrue(String(bytes: data, encoding: .utf8)?.contains(#""schema" : {"#) == true)
        XCTAssertEqual(try ProjectJSON.decode(GraphQLBody.self, from: data), body)
    }

    func testANullUnknownOrExplicitDefaultSourceReadsAsIntrospection() throws {
        for schema in ["null", #"{"type": "introspection"}"#, #"{"type": "federation"}"#, #"{"type": "file"}"#] {
            let json = #"{"query": "{ ping }", "schema": "# + schema + "}"

            let body = try ProjectJSON.decode(GraphQLBody.self, from: Data(json.utf8))

            XCTAssertEqual(body.schema, .introspection, schema)
            XCTAssertEqual(body.query, "{ ping }", schema)
        }
    }

    func testMovingARequestCarriesItsSchemaFile() {
        let id = LocalPathID()
        var spec = HTTPRequestSpec()
        spec.body.graphQL.schema = .file(.local(id))

        let moved = RequestKind.http(spec).mappingPathReferences { _ in .relative("api.graphql") }

        XCTAssertEqual(moved.httpSpec?.body.graphQL.schema, .file(.relative("api.graphql")))
    }
}
