import Foundation
import GraphQL
import ReqlingKit
import XCTest

/// The queries Reqling sends must be ones a real server accepts, and the probe must read what that server supports.
final class GraphQLIntrospectionTests: XCTestCase {
    func testEveryQueryValidatesAndRunsAgainstARealServer() async throws {
        for (name, query) in [
            ("probe", GraphQLIntrospection.probeQuery),
            ("full", GraphQLIntrospection.query(.all)),
            ("conservative", GraphQLIntrospection.query(.conservative))
        ] {
            let result = try await GraphQLOracle.run(query)

            XCTAssertEqual(result.errors.map(\.message), [], name)
            XCTAssertNotNil(result.data, name)
        }
    }

    func testTheProbeFindsEverythingGraphQLSwiftSupports() async throws {
        let result = try await GraphQLOracle.run(GraphQLIntrospection.probeQuery)
        let data = try XCTUnwrap(try GraphQLOracle.object(GraphQLJSONEncoder().encode(result))["data"] as? [String: Any])

        XCTAssertEqual(GraphQLIntrospection.capabilities(fromProbe: data), .all)
    }

    func testTheProbeReadsOlderServersAsSupportingLess() async throws {
        let result = try await GraphQLOracle.run(GraphQLIntrospection.probeQuery)
        var data = try XCTUnwrap(try GraphQLOracle.object(GraphQLJSONEncoder().encode(result))["data"] as? [String: Any])
        // graphql-js 15: `specifiedByUrl`, no `isOneOf`, and no deprecated input values or directive arguments.
        data["typeMeta"] = Self.renaming(in: data["typeMeta"], field: "specifiedByURL", to: "specifiedByUrl", dropping: ["isOneOf"])
        data["inputValueMeta"] = Self.renaming(in: data["inputValueMeta"], dropping: ["deprecationReason", "isDeprecated"])

        let capabilities = GraphQLIntrospection.capabilities(fromProbe: data)

        XCTAssertEqual(capabilities.specifiedBy, .legacy)
        XCTAssertFalse(capabilities.oneOf)
        XCTAssertFalse(capabilities.inputValueDeprecation)
        XCTAssertFalse(capabilities.directiveArgumentDeprecation)
        XCTAssertTrue(capabilities.directiveIsRepeatable)
        XCTAssertEqual(GraphQLIntrospection.capabilities(fromProbe: [:]), .conservative)
    }

    /// The conservative query cannot learn that an argument or input field is deprecated (graphql-js leaves them out of
    /// it altogether; GraphQLSwift lists them as current), so the probe is what lets completion mark them.
    func testOnlyTheFullQueryReadsDeprecatedArgumentsAndInputFields() async throws {
        let full = try await GraphQLOracle.decoded(capabilities: .all).typeSystem
        let conservative = try await GraphQLOracle.decoded(capabilities: .conservative).typeSystem

        XCTAssertEqual(full.field("books", on: "Root")?.arg("legacyPage")?.deprecationReason, "Use `first`.")
        XCTAssertEqual(full.type(named: "BookFilter")?.inputField("legacyCode")?.isDeprecated, true)
        XCTAssertNotEqual(conservative.field("books", on: "Root")?.arg("legacyPage")?.isDeprecated, true)
        XCTAssertNotEqual(conservative.type(named: "BookFilter")?.inputField("legacyCode")?.isDeprecated, true)
        XCTAssertEqual(full.directive(named: "tag")?.isRepeatable, true)
        let tag = try XCTUnwrap(conservative.directive(named: "tag"))
        XCTAssertNil(tag.isRepeatable, "the conservative query cannot tell")
    }

    // MARK: - Responses

    func testClassifiesDataEvenWhenTheServerAlsoReportedErrors() throws {
        let body = #"{"data":{"__schema":{"types":[]}},"errors":[{"message":"Partial"}]}"#

        guard case .data(let data, let errors) = GraphQLIntrospection.classify(response(body)) else {
            return XCTFail("Expected data")
        }

        XCTAssertNotNil(try GraphQLOracle.object(data)["__schema"])
        XCTAssertEqual(errors, ["Partial"])
    }

    func testClassifiesErrorsWithoutDataAsRefusedWhateverTheStatus() {
        for status in [200, 400] {
            let body = #"{"errors":[{"message":"GraphQL introspection is not allowed"}]}"#

            guard case .refused(let messages) = GraphQLIntrospection.classify(response(body, status: status)) else {
                return XCTFail("Expected refused for \(status)")
            }

            XCTAssertEqual(messages, ["GraphQL introspection is not allowed"])
        }
    }

    func testClassifiesOtherFailuresWithWhatWillExplainThem() throws {
        guard case .failed(let unauthorized) = GraphQLIntrospection.classify(response("Bad token\nTry again", status: 401)) else {
            return XCTFail("Expected an HTTP failure")
        }
        XCTAssertEqual(unauthorized, .http(status: 401, snippet: "Bad token Try again"))
        XCTAssertEqual(unauthorized.errorDescription, "The server answered 401 Unauthorized: Bad token Try again")

        let login = response("<html>Sign in</html>", headers: [KeyValuePair(key: "content-type", value: "text/html")], redirects: 1)
        guard case .failed(let notGraphQL) = GraphQLIntrospection.classify(login) else {
            return XCTFail("Expected a failure")
        }
        XCTAssertEqual(notGraphQL, .notGraphQL(contentType: "text/html", redirected: true))
        XCTAssertTrue(notGraphQL.errorDescription?.contains("POST into a GET") == true)

        guard case .failed(let tooLarge) = GraphQLIntrospection.classify(response(Data(count: GraphQLIntrospection.responseLimit + 1))) else {
            return XCTFail("Expected too large")
        }
        XCTAssertEqual(tooLarge, .tooLarge(GraphQLIntrospection.responseLimit + 1))
    }

    // MARK: - Support

    private func response(_ body: String, status: Int = 200, headers: [KeyValuePair] = [], redirects: Int = 0) -> HTTPResponseRecord {
        response(Data(body.utf8), status: status, headers: headers, redirects: redirects)
    }

    private func response(_ body: Data, status: Int = 200, headers: [KeyValuePair] = [], redirects: Int = 0) -> HTTPResponseRecord {
        HTTPResponseRecord(
            statusCode: status,
            headers: headers,
            body: body,
            url: "https://api.test/graphql",
            startedAt: Date(timeIntervalSince1970: 0),
            duration: 0,
            redirectCount: redirects
        )
    }

    /// A probe meta-type's field list with one field renamed and others removed.
    private static func renaming(in meta: Any?, field: String? = nil, to newName: String? = nil, dropping: Set<String> = []) -> Any {
        var meta = meta as? [String: Any] ?? [:]
        let fields = (meta["fields"] as? [[String: Any]] ?? []).compactMap { entry -> [String: Any]? in
            guard let name = entry["name"] as? String, !dropping.contains(name) else {
                return nil
            }
            var entry = entry
            if name == field, let newName {
                entry["name"] = newName
            }
            return entry
        }
        meta["fields"] = fields
        return meta
    }
}
