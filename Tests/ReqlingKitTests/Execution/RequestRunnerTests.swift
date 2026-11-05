import Foundation
import ReqlingKit
import XCTest

@MainActor
final class RequestRunnerTests: XCTestCase {
    private var fixture: LibraryFixture!
    private var workspace: WorkspaceStateStore!
    private var settings: SettingsStore!
    private var suiteName: String!
    private var servers: [TestHTTPServer] = []

    override func setUp() async throws {
        fixture = try LibraryFixture()
        workspace = WorkspaceStateStore(fileURL: fixture.directory.file("Support/workspace.json"))
        suiteName = "com.afollestad.reqling.tests.runner.\(UUID().uuidString)"
        settings = SettingsStore(defaults: UserDefaults(suiteName: suiteName)!)
    }

    override func tearDown() async throws {
        for server in servers {
            try await server.shutdown()
        }
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        fixture.directory.remove()
    }

    private func makeRunner() -> RequestRunner {
        RequestRunner(
            library: fixture.library,
            workspace: workspace,
            settings: settings,
            keychain: EmptyKeychain(),
            pkcs12Probe: TLSFixtures.probe,
            cache: ResponseCache(directory: fixture.directory.file("Support/Responses")),
            userAgent: "Reqling/1.0"
        )
    }

    private func echoServer(tls: Bool = false) async throws -> TestHTTPServer {
        let context = tls ? try TLSFixtures.serverContext(requireClientCertificate: true) : nil
        let server = try await TestHTTPServer.start(tls: context) { request in
            .text("\(request.method) \(request.uri) \(request.header("X-Extra") ?? "-")")
        }
        servers.append(server)
        return server
    }

    /// A project whose request targets `{{base}}/{{path}}`, with `path` set differently per environment.
    private struct ProjectFixture {
        let id: ProjectID
        let request: RequestNodeID
        let staging: EnvironmentID
    }

    private func makeProject(base: String) throws -> ProjectFixture {
        let id = try fixture.library.createProject(named: "Runner")
        let request = RequestItem.http("Echo", url: "{{base}}/{{path}}")
        let staging = RequestEnvironment(name: "Staging", variables: [Variable(key: "path", value: "staging")])
        try fixture.library.mutate(id) { document in
            document.defaultEnvironment.variables = [Variable(key: "base", value: base), Variable(key: "path", value: "default")]
            document.environments.append(staging)
            try document.insert(.request(request), into: nil)
        }
        return ProjectFixture(id: id, request: request.id, staging: staging.id)
    }

    private func body(_ exchange: RequestExchange) -> String? {
        exchange.response?.body.utf8Text
    }

    func testRunsWithTheActiveEnvironmentThenOverrides() async throws {
        let server = try await echoServer()
        let fixtureProject = try makeProject(base: server.baseURL)
        let project = fixtureProject.id
        let request = fixtureProject.request
        let runner = makeRunner()

        let onDefault = await runner.run(request, in: project)
        XCTAssertEqual(body(onDefault), "GET /default -")

        workspace.updateProject(project) { $0.activeEnvironmentID = fixtureProject.staging }
        let onStaging = await runner.run(request, in: project)
        XCTAssertEqual(body(onStaging), "GET /staging -")
        XCTAssertEqual(onStaging.environmentName, "Staging")

        var patched = try XCTUnwrap(fixture.library.document(project)?.request(request)?.kind.httpSpec)
        patched.headers.append(KeyValuePair(key: "X-Extra", value: "patched"))
        let overridden = await runner.run(request, in: project, options: RunOptions(
            variableOverrides: ["path": "override"],
            spec: .http(patched)
        ))
        XCTAssertEqual(body(overridden), "GET /override patched")
        // One-run overrides never touch the saved template.
        XCTAssertTrue(fixture.library.document(project)?.request(request)?.kind.httpSpec?.headers.isEmpty ?? false)
    }

    func testUndefinedVariablesFailBeforeAnythingIsSent() async throws {
        let server = try await echoServer()
        let fixtureProject = try makeProject(base: server.baseURL)
        let project = fixtureProject.id
        let request = fixtureProject.request
        try fixture.library.mutate(project) { document in
            try document.updateRequest(request) { $0.kind = .http(HTTPRequestSpec(url: "{{base}}/{{missing}}")) }
        }

        let exchange = await makeRunner().run(request, in: project)

        XCTAssertEqual(exchange.failure?.kind, .invalidRequest)
        XCTAssertEqual(exchange.failure?.message, "Undefined variables: {{missing}}. Define them in an environment, or remove them.")
        XCTAssertTrue(server.requests.isEmpty)

        let allowed = await makeRunner().run(request, in: project, options: RunOptions(allowUnresolved: true))
        XCTAssertEqual(allowed.unresolvedVariables, ["missing"])
        XCTAssertEqual(server.requests.count, 1)
    }

    func testTheLatestExchangeSurvivesARelaunchThroughTheCache() async throws {
        let server = try await echoServer()
        let fixtureProject = try makeProject(base: server.baseURL)
        let project = fixtureProject.id
        let request = fixtureProject.request
        let runner = makeRunner()
        _ = await runner.run(request, in: project)
        runner.flushResponseCache()

        let restored = makeRunner().exchange(for: request, in: project)

        XCTAssertEqual(restored.flatMap(body), "GET /default -")
        XCTAssertEqual(restored?.request?.url, "\(server.baseURL)/default")
    }

    func testOutcomesAreRecordedAndSurviveARelaunch() async throws {
        let server = try await echoServer()
        let fixtureProject = try makeProject(base: server.baseURL)
        let project = fixtureProject.id
        let request = fixtureProject.request
        let runner = makeRunner()
        XCTAssertEqual(runner.outcome(for: request, in: project), .notSent)

        _ = await runner.run(request, in: project)

        XCTAssertEqual(runner.outcome(for: request, in: project), .succeeded)
        runner.flushResponseCache()
        XCTAssertEqual(makeRunner().outcome(for: request, in: project), .succeeded)
    }

    func testADeletedStoredEnvironmentFallsBackToDefaultButANamedOneMustExist() async throws {
        let server = try await echoServer()
        let fixtureProject = try makeProject(base: server.baseURL)
        let project = fixtureProject.id
        let request = fixtureProject.request
        workspace.updateProject(project) { $0.activeEnvironmentID = EnvironmentID() }
        let runner = makeRunner()

        let fallback = await runner.run(request, in: project)
        let named = await runner.run(request, in: project, options: RunOptions(environmentID: EnvironmentID()))

        XCTAssertEqual(body(fallback), "GET /default -")
        XCTAssertEqual(fallback.environmentName, RequestEnvironment.defaultName)
        XCTAssertEqual(named.failure, RunFailure(kind: .invalidRequest, message: "The environment no longer exists."))
    }

    func testForgettingAProjectCancelsItsRunsAndLeavesNoCache() async throws {
        let (received, signal) = AsyncStream<Void>.makeStream()
        let server = try await TestHTTPServer.start { _ in
            signal.yield()
            return .hang
        }
        servers.append(server)
        let fixtureProject = try makeProject(base: server.baseURL)
        let project = fixtureProject.id
        let request = fixtureProject.request
        let runner = makeRunner()

        let run = Task { await runner.run(request, in: project) }
        for await _ in received {
            break
        }
        try fixture.library.deleteProject(project)
        runner.forget(project)
        let exchange = await run.value

        XCTAssertEqual(exchange.failure?.kind, .cancelled)
        XCTAssertFalse(runner.isInFlight(request, in: project))
        XCTAssertNil(runner.exchange(for: request, in: project))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.directory.file("Support/Responses/\(project)").path))

        // A run of a project that is already gone records nothing either.
        _ = await runner.run(request, in: project)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.directory.file("Support/Responses/\(project)").path))
    }

    func testRunsOfTheSameRequestIDInTwoProjectsStayIndependent() async throws {
        let (received, signal) = AsyncStream<Void>.makeStream()
        let hanging = try await TestHTTPServer.start { _ in
            signal.yield()
            return .hang
        }
        servers.append(hanging)
        let echo = try await echoServer()
        let first = try makeProject(base: hanging.baseURL)
        let shared = first.request
        let second = try fixture.library.createProject(named: "Copy")
        try fixture.library.mutate(second) { document in
            document.defaultEnvironment.variables = [Variable(key: "base", value: echo.baseURL), Variable(key: "path", value: "copy")]
            try document.insert(.request(RequestItem(id: shared, name: "Echo", kind: .http(HTTPRequestSpec(url: "{{base}}/{{path}}")))), into: nil)
        }
        let runner = makeRunner()

        let stalled = Task { await runner.run(shared, in: first.id) }
        for await _ in received {
            break
        }
        let copy = await runner.run(shared, in: second)

        XCTAssertEqual(body(copy), "GET /copy -")
        XCTAssertTrue(runner.isInFlight(shared, in: first.id), "the other project's run must not be cancelled")
        XCTAssertFalse(runner.isInFlight(shared, in: second))
        XCTAssertEqual(runner.latest[RunKey(shared, in: second)].flatMap(body), "GET /copy -")
        XCTAssertNil(runner.latest[RunKey(shared, in: first.id)])

        runner.cancel(shared, in: first.id)
        let cancelled = await stalled.value
        XCTAssertEqual(cancelled.failure?.kind, .cancelled)
        XCTAssertEqual(runner.latest[RunKey(shared, in: second)].flatMap(body), "GET /copy -")
    }

    func testErrorMessagesNeverQuoteSecretValues() async throws {
        let server = try await TestHTTPServer.start(tls: TLSFixtures.serverContext(requireClientCertificate: false)) { _ in .text("ok") }
        servers.append(server)
        let fixtureProject = try makeProject(base: "unused")
        let project = fixtureProject.id
        // The fixture CA is not trusted here, so the TLS failure names the host, which came from a secret. The host
        // comes back lower-cased, so matching must ignore case; `pw@server` is no URL, so "server" stays readable.
        try fixture.library.mutate(project) { document in
            document.defaultEnvironment.variables = [
                Variable(key: "base", value: "https://LOCALHOST:\(server.port)", isSecret: true),
                Variable(key: "path", value: "x"),
                Variable(key: "password", value: "pw@server", isSecret: true)
            ]
        }

        let exchange = await makeRunner().run(fixtureProject.request, in: project)

        let message = try XCTUnwrap(exchange.failure?.message)
        XCTAssertNil(message.range(of: "localhost", options: .caseInsensitive), message)
        XCTAssertTrue(message.contains(TemplateResolver.mask), message)
        XCTAssertTrue(message.contains("server"), message)
    }

    func testTheCachedExchangeHoldsNoSecret() async throws {
        let server = try await TestHTTPServer.start { request in
            // Pass the query along, as servers that canonicalize URLs do.
            guard request.uri.hasPrefix("/start") else {
                return .text("ok")
            }
            return .reply(status: .found, headers: [("Location", request.uri.replacingOccurrences(of: "/start", with: "/end"))])
        }
        servers.append(server)
        let fixtureProject = try makeProject(base: server.baseURL)
        let project = fixtureProject.id
        let request = fixtureProject.request
        try fixture.library.mutate(project) { document in
            document.defaultEnvironment.variables.append(Variable(key: "token", value: "s3cr3t", isSecret: true))
            try document.updateRequest(request) { item in
                item.kind = .http(HTTPRequestSpec(url: "{{base}}/start/{{token}}", queryParameters: [KeyValuePair(key: "key", value: "{{token}}")]))
            }
        }

        let runner = makeRunner()
        let exchange = await runner.run(request, in: project)

        XCTAssertEqual(server.requests.last?.uri, "/end/s3cr3t?key=s3cr3t")
        XCTAssertEqual(exchange.response?.url, "\(server.baseURL)/end/\(TemplateResolver.mask)?key=\(TemplateResolver.mask)")
        runner.flushResponseCache()
        let cached = try Data(contentsOf: fixture.directory.file("Support/Responses/\(project)/\(request).json"))
        XCTAssertNil(cached.utf8Text?.range(of: "s3cr3t"))
    }

    func testARemovedRequestFailsCleanly() async throws {
        let project = try makeProject(base: "http://127.0.0.1:1").id

        let exchange = await makeRunner().run(RequestNodeID(), in: project)

        XCTAssertEqual(exchange.failure, RunFailure(kind: .invalidRequest, message: "The request no longer exists."))
    }

    func testProjectCertificatesDriveMutualTLS() async throws {
        let server = try await echoServer(tls: true)
        let fixtureProject = try makeProject(base: server.baseURL)
        let project = fixtureProject.id
        let request = fixtureProject.request
        let projectURL = fixture.projectURL(project)
        try FileManager.default.copyItem(at: TLSFixtures.url("client.p12"), to: projectURL.appendingPathComponent("client.p12"))
        try FileManager.default.copyItem(at: TLSFixtures.url("ca.pem"), to: projectURL.appendingPathComponent("ca.pem"))
        let entry = ClientCertificateEntry(hostPattern: "127.0.0.1", source: .pkcs12(.relative("client.p12")))
        try fixture.library.mutate(project) { document in
            document.tls = ProjectTLSConfiguration(clientCertificates: [entry], caCertificates: [.relative("ca.pem")])
        }

        try fixture.library.setCertificatePassphrase("wrong", for: entry.id, in: project)
        let rejected = await makeRunner().run(request, in: project)
        XCTAssertEqual(rejected.failure, RunFailure(kind: .tls, message: TLSError.wrongPassphrase.localizedDescription))

        try fixture.library.setCertificatePassphrase(TLSFixtures.clientPassphrase, for: entry.id, in: project)
        let accepted = await makeRunner().run(request, in: project)
        XCTAssertEqual(body(accepted), "GET /default -")
        XCTAssertEqual(accepted.response?.presentedClientCertificate, true)
    }
}

/// A Keychain with nothing in it, so no test reaches the developer's real one.
struct EmptyKeychain: KeychainIdentityStore {
    func availableIdentities() -> [KeychainIdentityInfo] {
        []
    }

    func identity(for persistentReference: Data) throws(TLSError) -> TLSClientIdentity {
        throw .missingFile("The test keychain identity")
    }
}
