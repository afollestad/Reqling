import Foundation
import GraphQLFixtureServer
import XCTest

/// The fixture server other GraphQL suites rely on: it must answer like a real GraphQL server, including the parts of
/// introspection older defaults leave out, and its auth, refusal, and override switches must do what they say.
final class GraphQLFixtureServerTests: XCTestCase {
    private var servers: [GraphQLFixtureServer] = []

    override func tearDown() async throws {
        for server in servers {
            try await server.shutdown()
        }
        servers = []
        try await super.tearDown()
    }

    func testAnswersQueriesFromTheLibrarySchema() async throws {
        let server = try await start()

        let query = "{ ping me { name books { title genre author { name } shelves } } search(text: \"x\") { __typename } }"
        let reply = try await post(query, to: server)

        XCTAssertEqual(reply.status, 200)
        let data = try XCTUnwrap(reply.json["data"] as? [String: Any])
        XCTAssertEqual(data["ping"] as? String, "pong")
        let viewer = try XCTUnwrap(data["me"] as? [String: Any])
        XCTAssertEqual(viewer["name"] as? String, "Ursula K. Le Guin")
        let book = try XCTUnwrap((viewer["books"] as? [[String: Any]])?.first)
        XCTAssertEqual(book["genre"] as? String, "FICTION")
        XCTAssertEqual((book["author"] as? [String: Any])?["name"] as? String, "Ursula K. Le Guin")
        XCTAssertEqual(book["shelves"] as? [[String]], [["Fiction", "Classics"]])
        XCTAssertEqual((data["search"] as? [Any])?.count, 0)
    }

    /// Asks for an input value's `deprecationReason` only: GraphQLSwift cannot resolve `__InputValue.isDeprecated`
    /// (`GraphQLIntrospection` works around the same gap in servers built on it).
    func testIntrospectionIncludesDeprecatedArgumentsOneOfAndRepeatableDirectives() async throws {
        let server = try await start()

        let reply = try await post("""
            {
              root: __type(name: "Root") { fields { name args(includeDeprecated: true) { name deprecationReason } } }
              lookup: __type(name: "BookLookup") { isOneOf }
              dateTime: __type(name: "DateTime") { specifiedByURL }
              __schema { queryType { name } directives { name isRepeatable } }
            }
            """, to: server)

        XCTAssertNil(reply.json["errors"])
        let data = try XCTUnwrap(reply.json["data"] as? [String: Any])
        let fields = try XCTUnwrap((data["root"] as? [String: Any])?["fields"] as? [[String: Any]])
        let books = try XCTUnwrap(fields.first { $0["name"] as? String == "books" })
        let legacyPage = try XCTUnwrap((books["args"] as? [[String: Any]])?.first { $0["name"] as? String == "legacyPage" })
        XCTAssertEqual(legacyPage["deprecationReason"] as? String, "Use `first`.")
        XCTAssertEqual((data["lookup"] as? [String: Any])?["isOneOf"] as? Bool, true)
        XCTAssertEqual((data["dateTime"] as? [String: Any])?["specifiedByURL"] as? String, "https://scalars.graphql.org/andimarek/date-time")
        let schema = try XCTUnwrap(data["__schema"] as? [String: Any])
        XCTAssertEqual((schema["queryType"] as? [String: Any])?["name"] as? String, "Root")
        let tag = (schema["directives"] as? [[String: Any]])?.first { $0["name"] as? String == "tag" }
        XCTAssertEqual(tag?["isRepeatable"] as? Bool, true)
    }

    func testRequiresTheBearerTokenWhenOneIsSet() async throws {
        let server = try await start(.init(requiredBearerToken: "s3cret"))

        let refused = try await post("{ ping }", to: server)
        let wrong = try await post("{ ping }", to: server, headers: ["Authorization": "Bearer nope"])
        let accepted = try await post("{ ping }", to: server, headers: ["Authorization": "Bearer s3cret"])

        XCTAssertEqual(refused.status, 401)
        XCTAssertEqual(wrong.status, 401)
        XCTAssertEqual(accepted.status, 200)
        XCTAssertEqual((accepted.json["data"] as? [String: Any])?["ping"] as? String, "pong")
    }

    func testRefusesOnlyIntrospectionWhenItIsDisabled() async throws {
        let server = try await start(.init(introspection: .disabled(status: 400)))

        let introspection = try await post("{ __schema { queryType { name } } }", to: server)
        let ordinary = try await post("{ ping }", to: server)

        XCTAssertEqual(introspection.status, 400)
        XCTAssertNil(introspection.json["data"])
        XCTAssertFalse((introspection.json["errors"] as? [Any] ?? []).isEmpty)
        XCTAssertEqual(ordinary.status, 200)
        XCTAssertEqual((ordinary.json["data"] as? [String: Any])?["ping"] as? String, "pong")
    }

    func testAnswersGetRequestsWithFormEncodedParameters() async throws {
        let server = try await start()
        var components = try XCTUnwrap(URLComponents(url: server.url, resolvingAgainstBaseURL: false))
        components.percentEncodedQuery = "query=query+Books($n:+Int)+%7B+books(first:+$n)+%7B+title+%7D+%7D"
            + "&operationName=Books&variables=%7B%22n%22%3A1%7D"

        let (data, response) = try await URLSession(configuration: .ephemeral).data(from: try XCTUnwrap(components.url))

        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let books = (json["data"] as? [String: Any])?["books"] as? [[String: Any]]
        XCTAssertEqual(books?.first?["title"] as? String, "The Dispossessed")
    }

    func testReportsInvalidQueriesAsGraphQLErrors() async throws {
        let server = try await start()

        let misspelled = try await post("{ pnig }", to: server)
        let unparsable = try await post("{ ping", to: server)

        XCTAssertEqual(misspelled.status, 200)
        let message = try XCTUnwrap((misspelled.json["errors"] as? [[String: Any]])?.first?["message"] as? String)
        XCTAssertTrue(message.contains("pnig"), message)
        XCTAssertFalse((unparsable.json["errors"] as? [Any] ?? []).isEmpty)
    }

    func testOverrideRepliesAndEveryRequestIsRecorded() async throws {
        let server = try await start(.init(override: { request in
            request.header("X-Fail") == "yes" ? .text("<html>down</html>", status: 503, contentType: "text/html") : nil
        }))
        var received = server.received.makeAsyncIterator()

        let failed = try await post("{ ping }", to: server, headers: ["X-Fail": "yes"])
        let passed = try await post("{ ping }", to: server)

        XCTAssertEqual(failed.status, 503)
        XCTAssertEqual(passed.status, 200)
        XCTAssertEqual(server.requests.map(\.method), ["POST", "POST"])
        XCTAssertEqual(server.requests.first?.header("x-fail"), "yes")
        let first = await received.next()
        XCTAssertEqual(first?.uri, "/graphql")
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: try XCTUnwrap(first?.body)) as? [String: Any])
        XCTAssertEqual(body["query"] as? String, "{ ping }")
    }

    func testRefusesSchemasThatDoNotBuildOrValidate() async {
        for sdl in ["type Query {", "type Query { a: Missing }"] {
            do {
                _ = try await start(.init(sdl: sdl))
                XCTFail("\(sdl) started")
            } catch {}
        }
    }

    func testCommandParsesItsOptions() throws {
        XCTAssertEqual(try GraphQLFixtureCommand.parse([]), .init())
        XCTAssertEqual(
            try GraphQLFixtureCommand.parse(["--port", "0", "--token", "t", "--no-introspection", "--schema", "s.graphql"]),
            .init(port: 0, token: "t", introspection: false, schemaPath: "s.graphql")
        )
        for invalid in [["--port"], ["--port", "70000"], ["--token", "--port"], ["--verbose"]] {
            XCTAssertThrowsError(try GraphQLFixtureCommand.parse(invalid), "\(invalid)")
        }
    }

    // MARK: - Support

    private func start(_ options: GraphQLFixtureServer.Options = .init()) async throws -> GraphQLFixtureServer {
        let server = try await GraphQLFixtureServer.start(options)
        servers.append(server)
        return server
    }

    private func post(
        _ query: String,
        to server: GraphQLFixtureServer,
        headers: [String: String] = [:]
    ) async throws -> (status: Int, json: [String: Any]) {
        var request = URLRequest(url: server.url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: ["query": query])
        let (data, response) = try await URLSession(configuration: .ephemeral).data(for: request)
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, json)
    }
}
