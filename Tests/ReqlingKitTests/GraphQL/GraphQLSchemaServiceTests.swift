import Foundation
import GraphQLFixtureServer
import NIOSSL
import XCTest

@testable import ReqlingKit

/// Loading a request's schema end to end: the runner resolves the request, the service introspects the fixture
/// server over loopback (or reads a schema file), and caches what it got in memory and on disk.
@MainActor
final class GraphQLSchemaServiceTests: XCTestCase {
    var fixture: LibraryFixture!
    var workspace: WorkspaceStateStore!
    var settings: SettingsStore!
    var servers: [GraphQLFixtureServer] = []
    private var suiteName: String!

    override func setUp() async throws {
        fixture = try LibraryFixture()
        workspace = WorkspaceStateStore(fileURL: fixture.directory.file("Support/workspace.json"))
        suiteName = "com.afollestad.reqling.tests.graphql.\(UUID().uuidString)"
        settings = SettingsStore(defaults: UserDefaults(suiteName: suiteName)!)
    }

    override func tearDown() async throws {
        for server in servers {
            try await server.shutdown()
        }
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        fixture.directory.remove()
    }

    // MARK: - Introspection

    func testIntrospectsWithTheRequestsHeadersAndItsFoldersAuth() async throws {
        let server = try await start(.init(requiredBearerToken: "s3cret"))
        let setup = try makeProject(base: server.url.absoluteString, folderAuth: .bearer(token: "{{token}}"))

        let schema = try await makeRunner().graphQLSchema(for: setup.request, in: setup.project)

        XCTAssertNotNil(schema.typeSystem.type(named: "Book"))
        XCTAssertEqual(schema.capabilities, .all)
        guard case .introspection(let url, _) = schema.source else {
            return XCTFail("Expected introspection, got \(schema.source)")
        }
        XCTAssertEqual(url, server.url.absoluteString + "?env=default")
        XCTAssertEqual(server.requests.count, 2, "the probe, then the full query")
        for request in server.requests {
            XCTAssertEqual(request.method, "POST")
            XCTAssertEqual(request.header("Authorization"), "Bearer s3cret")
            XCTAssertEqual(request.header("X-Client"), "reqling")
            XCTAssertEqual(request.header("Content-Type"), "application/json")
            let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: request.body) as? [String: Any])
            XCTAssertEqual(body["operationName"] as? String, "IntrospectionQuery")
        }
    }

    func testIntrospectionIsNeverARun() async throws {
        let server = try await start()
        let setup = try makeProject(base: server.url.absoluteString)
        let runner = makeRunner()

        _ = try await runner.graphQLSchema(for: setup.request, in: setup.project)

        XCTAssertTrue(runner.latest.isEmpty)
        XCTAssertTrue(runner.inFlight.isEmpty)
        runner.flushHistory()
        XCTAssertEqual(runner.history.runs(for: setup.request, in: setup.project), [])
    }

    func testOnlyAGraphQLBodyThatIsSentHasASchema() async throws {
        let setup = try makeProject(base: "http://127.0.0.1:1/graphql")
        let runner = makeRunner()
        try fixture.library.mutate(setup.project) { document in
            try document.updateRequest(setup.request) {
                $0.kind = .http(HTTPRequestSpec(method: .get, url: "http://127.0.0.1:1/graphql", body: Self.graphQLBody()))
            }
        }

        await XCTAssertThrowsRunFailure(try await runner.graphQLSchema(for: setup.request, in: setup.project), containing: "GET requests do not send")
        try fixture.library.mutate(setup.project) { document in
            try document.updateRequest(setup.request) { $0.kind = .http(HTTPRequestSpec(method: .post, url: "http://127.0.0.1:1/graphql")) }
        }
        await XCTAssertThrowsRunFailure(
            try await runner.graphQLSchema(for: setup.request, in: setup.project),
            containing: "does not send a GraphQL body"
        )
    }

    // MARK: - Caching

    func testASchemaIsAskedForOncePerEndpointAndSurvivesARelaunch() async throws {
        let server = try await start()
        let setup = try makeProject(base: server.url.absoluteString)
        let runner = makeRunner()

        _ = try await runner.graphQLSchema(for: setup.request, in: setup.project)
        _ = try await runner.graphQLSchema(for: setup.request, in: setup.project)
        XCTAssertEqual(server.requests.count, 2, "the second load came from memory")

        runner.graphQLSchemas?.store.flush()
        let relaunched = makeRunner()
        let fromDisk = await relaunched.cachedGraphQLSchema(for: setup.request, in: setup.project)
        let loaded = try await relaunched.graphQLSchema(for: setup.request, in: setup.project)

        XCTAssertNotNil(fromDisk?.typeSystem.type(named: "Book"))
        XCTAssertNotNil(loaded.typeSystem.type(named: "Book"))
        XCTAssertEqual(server.requests.count, 2, "a relaunch reads the disk")
    }

    func testAnotherURLIsAnotherSchemaButAnotherTokenIsNot() async throws {
        let server = try await start()
        let setup = try makeProject(base: server.url.absoluteString)
        let runner = makeRunner()

        _ = try await runner.graphQLSchema(for: setup.request, in: setup.project)
        try fixture.library.mutate(setup.project) { document in
            document.defaultEnvironment.variables = document.defaultEnvironment.variables.map { variable in
                var variable = variable
                if variable.key == "token" {
                    variable.value = "rotated"
                }
                return variable
            }
        }
        _ = try await runner.graphQLSchema(for: setup.request, in: setup.project)
        XCTAssertEqual(server.requests.count, 2)

        _ = try await runner.graphQLSchema(for: setup.request, in: setup.project, options: RunOptions(environmentID: setup.staging))
        XCTAssertEqual(server.requests.count, 4, "the staging environment's URL has its own schema")
        XCTAssertEqual(server.requests.last?.uri, "/graphql?env=staging")
        XCTAssertEqual(server.requests.first?.uri, "/graphql?env=default")
    }

    func testRefreshAsksAgainAndKeepsTheOldSchemaWhenThatFails() async throws {
        let failing = FailureSwitch()
        let server = try await start(.init(override: { _ in failing.isOn ? .text("down", status: 503) : nil }))
        let setup = try makeProject(base: server.url.absoluteString)
        let runner = makeRunner()
        let first = try await runner.graphQLSchema(for: setup.request, in: setup.project)

        let refreshed = try await runner.graphQLSchema(for: setup.request, in: setup.project, refresh: true)
        XCTAssertEqual(server.requests.count, 4)
        XCTAssertNotEqual(refreshed.id, first.id)

        failing.isOn = true
        let kept = try await runner.graphQLSchema(for: setup.request, in: setup.project, refresh: true)

        XCTAssertEqual(kept.id, refreshed.id)
        XCTAssertTrue(kept.issues.first?.contains("Refreshing failed") == true, "\(kept.issues)")
        XCTAssertTrue(kept.issues.first?.contains("503") == true, "\(kept.issues)")
    }

    func testForgettingAProjectDropsItsSchemasEvenFromAFetchInFlight() async throws {
        let gate = TestGate()
        let fetcher = GatedFetcher(gate: gate)
        let setup = try makeProject(base: "http://127.0.0.1:1/graphql")
        let runner = makeRunner(fetcher: fetcher)
        let store = try XCTUnwrap(runner.graphQLSchemas?.store)

        var arrivals = fetcher.arrivals.makeAsyncIterator()
        let load = Task { try await runner.graphQLSchema(for: setup.request, in: setup.project) }
        _ = await arrivals.next()
        runner.forget(setup.project)
        gate.open()
        _ = try await load.value
        store.flush()

        let projectFolder = store.directory.appendingPathComponent(setup.project.description)
        XCTAssertFalse(FileManager.default.fileExists(atPath: projectFolder.path), "a fetch that outlived its project wrote nothing")
    }

    // MARK: - Failures

    func testFailuresSayWhatWentWrongWithoutSecrets() async throws {
        let cases: [(GraphQLFixtureServer.Options, String)] = [
            (.init(requiredBearerToken: "other"), "401"),
            (.init(introspection: .disabled(status: 200)), "would not describe its schema"),
            (.init(introspection: .disabled(status: 400)), "would not describe its schema"),
            (.init(override: { _ in .text("<html>Sign in</html>", contentType: "text/html") }), "not a GraphQL response"),
            (.init(override: { request in .text("bad token \(request.header("Authorization") ?? "")", status: 500) }), "500")
        ]
        for (options, expected) in cases {
            let server = try await start(options)
            let setup = try makeProject(base: server.url.absoluteString, folderAuth: .bearer(token: "{{token}}"))

            do {
                _ = try await makeRunner().graphQLSchema(for: setup.request, in: setup.project)
                XCTFail("\(expected): loaded a schema")
            } catch {
                XCTAssertTrue(error.message.contains(expected), "\(expected): \(error.message)")
                XCTAssertFalse(error.message.contains("s3cret"), "\(expected): \(error.message)")
            }
        }
    }

    func testCancellingStopsAnIntrospectionTheServerNeverAnswers() async throws {
        let server = try await start(.init(override: { _ in .hang }))
        let setup = try makeProject(base: server.url.absoluteString)
        let runner = makeRunner()
        var received = server.received.makeAsyncIterator()

        let load = Task { try await runner.graphQLSchema(for: setup.request, in: setup.project) }
        _ = await received.next()
        load.cancel()

        do {
            _ = try await load.value
            XCTFail("A hung introspection finished")
        } catch {
            XCTAssertEqual((error as? RunFailure)?.kind, .cancelled, "\(error)")
        }
    }

    func testIntrospectsOverMutualTLSWithTheProjectsCertificates() async throws {
        let server = try await start(.init(tls: try TLSFixtures.serverContext(requireClientCertificate: true)))
        let setup = try makeProject(base: server.url.absoluteString)
        let projectURL = fixture.projectURL(setup.project)
        try FileManager.default.copyItem(at: TLSFixtures.url("client.p12"), to: projectURL.appendingPathComponent("client.p12"))
        try FileManager.default.copyItem(at: TLSFixtures.url("ca.pem"), to: projectURL.appendingPathComponent("ca.pem"))
        let entry = ClientCertificateEntry(hostPattern: "127.0.0.1", source: .pkcs12(.relative("client.p12")))
        try fixture.library.mutate(setup.project) { document in
            document.tls = ProjectTLSConfiguration(clientCertificates: [entry], caCertificates: [.relative("ca.pem")])
        }
        try fixture.library.setCertificatePassphrase(TLSFixtures.clientPassphrase, for: entry.id, in: setup.project)

        let schema = try await makeRunner().graphQLSchema(for: setup.request, in: setup.project)

        XCTAssertNotNil(schema.typeSystem.type(named: "Book"))
    }

    // MARK: - Schema files

    func testASchemaFileLoadsAndIsRereadWhenItChanges() async throws {
        let setup = try makeProject(base: "http://127.0.0.1:1/graphql", schema: .file(.relative("api.graphql")))
        let file = fixture.projectURL(setup.project).appendingPathComponent("api.graphql")
        try GraphQLOracle.fixtureSDL.write(to: file, atomically: true, encoding: .utf8)
        let runner = makeRunner()

        let first = try await runner.graphQLSchema(for: setup.request, in: setup.project)
        let loaded = runner.graphQLSchemas?.revision
        let again = try await runner.graphQLSchema(for: setup.request, in: setup.project)
        let unchanged = runner.graphQLSchemas?.revision
        try "type Query { replaced: Int }".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: file.path)
        let edited = try await runner.graphQLSchema(for: setup.request, in: setup.project)

        XCTAssertEqual(first.source, .file(name: "api.graphql"))
        XCTAssertEqual(again.id, first.id, "an unchanged file is not reread")
        XCTAssertEqual(unchanged, loaded, "a cache hit changes nothing editors follow")
        XCTAssertNotNil(edited.typeSystem.field("replaced", on: "Query"))
        XCTAssertNotEqual(runner.graphQLSchemas?.revision, loaded, "a reread changes the revision editors follow")
        try FileManager.default.removeItem(at: file)
        await XCTAssertThrowsRunFailure(try await runner.graphQLSchema(for: setup.request, in: setup.project), containing: "could not be found")
    }

    // MARK: - Support

    struct ProjectSetup {
        let project: ProjectID
        let request: RequestNodeID
        let staging: EnvironmentID
    }

    /// A project with a GraphQL POST to `{{base}}?env={{env}}` inside a folder, a secret `token`, an `X-Client`
    /// header, and a Staging environment whose `env` differs.
    func makeProject(base: String, folderAuth: HTTPAuth = .inherit, schema: GraphQLSchemaSource = .introspection) throws -> ProjectSetup {
        let id = try fixture.library.createProject(named: "GraphQL")
        let spec = HTTPRequestSpec(
            method: .post,
            url: "{{base}}",
            queryParameters: [KeyValuePair(key: "env", value: "{{env}}")],
            headers: [KeyValuePair(key: "X-Client", value: "reqling")],
            body: Self.graphQLBody(schema: schema)
        )
        let request = RequestItem(name: "Books", kind: .http(spec))
        let staging = RequestEnvironment(name: "Staging", variables: [Variable(key: "env", value: "staging")])
        try fixture.library.mutate(id) { document in
            document.defaultEnvironment.variables = [
                Variable(key: "base", value: base),
                Variable(key: "token", value: "s3cret", isSecret: true),
                Variable(key: "env", value: "default")
            ]
            document.environments.append(staging)
            try document.insert(.folder(RequestFolder(name: "API", auth: folderAuth, children: [.request(request)])), into: nil)
        }
        return ProjectSetup(project: id, request: request.id, staging: staging.id)
    }

    static func graphQLBody(schema: GraphQLSchemaSource = .introspection) -> HTTPBody {
        HTTPBody(mode: .graphQL, graphQL: GraphQLBody(query: "{ ping }", schema: schema))
    }

    func makeRunner(fetcher: any GraphQLIntrospectionFetching = LiveGraphQLIntrospectionFetcher()) -> RequestRunner {
        RequestRunner(
            library: fixture.library,
            workspace: workspace,
            settings: settings,
            keychain: EmptyKeychain(),
            pkcs12Probe: TLSFixtures.probe,
            history: RunHistory(directory: fixture.directory.file("Support/History"), settings: settings),
            userAgent: "Reqling/1.0",
            graphQLSchemas: GraphQLSchemaService(
                store: GraphQLSchemaStore(directory: fixture.directory.file("Support/GraphQLSchemas")),
                fetcher: fetcher
            ),
            scripts: ScriptFixtures.realRunner
        )
    }

    func start(_ options: GraphQLFixtureServer.Options = .init()) async throws -> GraphQLFixtureServer {
        let server = try await GraphQLFixtureServer.start(options)
        servers.append(server)
        return server
    }
}

/// Answers every introspection query from GraphQLSwift, but only once `gate` opens, reporting each arrival first.
private final class GatedFetcher: GraphQLIntrospectionFetching {
    let gate: TestGate
    let arrivals: AsyncStream<Void>
    private let arrived: AsyncStream<Void>.Continuation

    init(gate: TestGate) {
        self.gate = gate
        (arrivals, arrived) = AsyncStream.makeStream()
    }

    func send(_ request: PreparedHTTPRequest, tls: TLSContext, on executor: HTTPExecutor) async throws(HTTPExecutionError) -> HTTPResponseRecord {
        arrived.yield()
        await gate.wait()
        let body = request.urlRequest.httpBody ?? Data()
        let query = (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["query"] as? String ?? ""
        let response = (try? await GraphQLOracle.response(to: query)) ?? Data()
        return HTTPResponseRecord(statusCode: 200, headers: [], body: response, url: "", startedAt: Date(), duration: 0)
    }
}

/// A switch a server's override reads on its own thread.
private final class FailureSwitch: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isOn: Bool {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

@MainActor
func XCTAssertThrowsRunFailure<T>(
    _ expression: @autoclosure () async throws -> T,
    containing text: String,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected a failure containing “\(text)”", file: file, line: line)
    } catch {
        let message = (error as? RunFailure)?.message ?? error.localizedDescription
        XCTAssertTrue(message.contains(text), "“\(message)” does not contain “\(text)”", file: file, line: line)
    }
}
