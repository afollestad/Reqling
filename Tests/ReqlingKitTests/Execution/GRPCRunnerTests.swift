import Foundation
import GRPCCore
import GRPCReflectionService
import Observation
@testable import ReqlingKit
import XCTest

/// `RequestRunner` running gRPC requests against a loopback `GRPCTestServer`, end to end: templates, auth, schema
/// sources, the codec, and the cached record.
@MainActor
final class GRPCRunnerTests: XCTestCase {
    var fixture: LibraryFixture!
    var workspace: WorkspaceStateStore!
    var settings: SettingsStore!
    var suiteName: String!
    var servers: [GRPCTestServer] = []
    let log = MetadataLog()

    override func setUp() async throws {
        fixture = try LibraryFixture()
        workspace = WorkspaceStateStore(fileURL: fixture.directory.file("Support/workspace.json"))
        suiteName = "com.afollestad.reqling.tests.grpc-runner.\(UUID().uuidString)"
        settings = SettingsStore(defaults: try XCTUnwrap(UserDefaults(suiteName: suiteName)))
    }

    override func tearDown() async throws {
        for server in servers {
            await server.stop()
        }
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        fixture.directory.remove()
    }

    func testATemplatedUnaryCallIsRecordedAndCachedWithoutSecrets() async throws {
        let server = try await start()
        var spec = echoSpec("Unary", messages: [#"{"text": "hi {{name}}", "index": {{count}}}"#])
        spec.auth = .bearer(token: "{{token}}")
        spec.metadata = [KeyValuePair(key: "x-secret", value: "{{token}}"), KeyValuePair(key: "x-off", value: "no", isEnabled: false)]
        let (project, request) = try makeProject(spec, server: server, variables: [
            Variable(key: "name", value: "Ada"),
            Variable(key: "count", value: "7"),
            Variable(key: "token", value: "s3cr3t-token", isSecret: true)
        ])

        let exchange = await makeRunner().run(request, in: project)

        let call = try XCTUnwrap(exchange.grpc, "\(exchange.outcome)")
        XCTAssertEqual(call.status?.name, "OK")
        XCTAssertEqual(call.method, "\(EchoService.name)/Unary")
        XCTAssertEqual(call.kind, .unary)
        XCTAssertEqual(call.target, server.target.description)
        XCTAssertEqual(try texts(call, .sent), ["hi Ada"])
        XCTAssertEqual(try texts(call, .received), ["hi Ada"])
        XCTAssertEqual(try json(call.events.last).value(forKey: "index") as? Int, 7)
        XCTAssertTrue(call.sentMetadata.contains(KeyValuePair(key: "authorization", value: "Bearer \(TemplateResolver.mask)")))
        XCTAssertTrue(call.sentMetadata.contains(KeyValuePair(key: "x-secret", value: TemplateResolver.mask)))
        XCTAssertFalse(call.sentMetadata.contains { $0.key == "x-off" })
        XCTAssertTrue(call.initialMetadata.contains(KeyValuePair(key: "x-initial", value: "hello")))
        XCTAssertTrue(call.trailers.contains(KeyValuePair(key: "x-trailer", value: "bye")))
        XCTAssertEqual(log.received.last?["authorization"], "Bearer s3cr3t-token")
        XCTAssertEqual(log.received.last?["x-secret"], "s3cr3t-token")
        let cached = try Data(contentsOf: fixture.directory.file("Support/Responses/\(project)/\(request).json"))
        XCTAssertNil(cached.utf8Text?.range(of: "s3cr3t"))
        XCTAssertEqual(makeRunner().exchange(for: request, in: project)?.grpc, call, "The record survives a relaunch")
        XCTAssertEqual(makeRunner().outcome(for: request, in: project), .succeeded)
    }

    func testEveryKindRunsFromTheSpecsMessages() async throws {
        let server = try await start()
        let runner = makeRunner()
        let messages = [#"{"text": "a"}"#, #"{"text": "b"}"#, #"{"text": "c"}"#]
        // Each method and what it echoes for the three messages; the kind comes from the schema.
        let expectations: [String: [String]] = [
            "Unary": ["a"],
            "ServerStream": ["a", "a", "a"],
            "ClientStream": ["a,b,c"],
            "Bidi": ["a", "b", "c"]
        ]
        let kinds: [String: GRPCMethodKind] = [
            "Unary": .unary, "ServerStream": .serverStreaming, "ClientStream": .clientStreaming, "Bidi": .bidirectionalStreaming
        ]
        for (method, received) in expectations {
            let (project, request) = try makeProject(echoSpec(method, messages: messages), server: server)

            let exchange = await runner.run(request, in: project)
            let call = try XCTUnwrap(exchange.grpc, "\(method): \(exchange.outcome)")

            XCTAssertEqual(call.kind, kinds[method])
            XCTAssertEqual(call.status?.isOK, true, method)
            XCTAssertEqual(try texts(call, .received), received, method)
            XCTAssertEqual(try texts(call, .sent), call.kind.clientStreams ? ["a", "b", "c"] : ["a"], method)
        }
    }

    func testAServerStatusIsARecordAndAConnectionFailureIsAFailure() async throws {
        let server = try await start()
        let (project, request) = try makeProject(echoSpec("Unary", messages: [#"{"text": "fail"}"#]), server: server)
        let runner = makeRunner()

        let rejected = await runner.run(request, in: project)
        XCTAssertEqual(rejected.grpc?.status, GRPCStatusRecord(code: 5, name: "NOT_FOUND", message: "nothing here"))
        XCTAssertEqual(runner.outcome(for: request, in: project), .failed)

        try fixture.library.mutate(project) { document in
            document.defaultEnvironment.variables = [Variable(key: "target", value: "127.0.0.1:\(try FreePort.next())")]
        }
        let refused = await runner.run(request, in: project)
        XCTAssertEqual(refused.failure?.kind, .transport, "\(refused.outcome)")
    }

    func testAMissingMethodNamesTheServiceAndMethod() async throws {
        let server = try await start()
        let (project, request) = try makeProject(echoSpec("Nope"), server: server)

        let exchange = await makeRunner().run(request, in: project)

        let message = "“\(EchoService.name)/Nope” is not in the descriptor set."
        XCTAssertEqual(exchange.failure, RunFailure(kind: .invalidRequest, message: message))
        XCTAssertTrue(log.received.isEmpty, "Nothing reaches the server")
    }

    func testACodecErrorNamesTheMessageAndItsPath() async throws {
        let server = try await start()
        let (project, request) = try makeProject(echoSpec("ClientStream", messages: [#"{"text": "ok"}"#, #"{"text": 5}"#]), server: server)

        let exchange = await makeRunner().run(request, in: project)

        let failure = try XCTUnwrap(exchange.failure)
        XCTAssertEqual(failure.kind, .invalidRequest)
        XCTAssertTrue(failure.message.hasPrefix("Message 2 is not a valid reqling.test.v1.EchoMessage: text: "), failure.message)
    }

    func testAReceivedMessageCountsTheFieldsTheSchemaLacks() async throws {
        let server = try await start()
        let (project, request) = try makeProject(echoSpec("Unary", messages: [#"{"text": "newer"}"#]), server: server)

        let exchange = await makeRunner().run(request, in: project)

        let call = try XCTUnwrap(exchange.grpc, "\(exchange.outcome)")
        XCTAssertEqual(call.events.map(\.unknownFieldCount), [0, 2])
        XCTAssertEqual(try texts(call, .received), ["newer"])
        XCTAssertEqual(makeRunner().exchange(for: request, in: project)?.grpc?.events.last?.unknownFieldCount, 2, "The count survives a relaunch")
    }

    func testAuthInheritsAndTravelsAsMetadata() async throws {
        let server = try await start()
        let password = Variable(key: "password", value: "pw", isSecret: true)
        let (project, request) = try makeProject(echoSpec("Unary"), server: server, variables: [password])
        try fixture.library.mutate(project) { $0.auth = .basic(username: "ada", password: "{{password}}") }
        let runner = makeRunner()

        let exchange = await runner.run(request, in: project)
        let basic = try XCTUnwrap(exchange.grpc, "\(exchange.outcome)")
        XCTAssertEqual(log.received.last?["authorization"], "Basic \(Data("ada:pw".utf8).base64EncodedString())")
        let maskedBasic = "Basic \(Data("ada:\(TemplateResolver.mask)".utf8).base64EncodedString())"
        XCTAssertTrue(basic.sentMetadata.contains(KeyValuePair(key: "authorization", value: maskedBasic)))

        try fixture.library.mutate(project) { document in
            try document.updateRequest(request) { item in
                item.kind.updateGRPC { $0.auth = .apiKey(name: "X-Api-Key", value: "k3y", location: .header) }
            }
        }
        _ = await runner.run(request, in: project)
        XCTAssertEqual(log.received.last?["x-api-key"], "k3y")

        try fixture.library.mutate(project) { document in
            try document.updateRequest(request) { item in
                item.kind.updateGRPC { $0.auth = .apiKey(name: "key", value: "k3y", location: .query) }
            }
        }
        let query = await runner.run(request, in: project)
        XCTAssertEqual(query.failure?.kind, .invalidRequest)
        XCTAssertTrue(query.failure?.message.contains("query string") == true)
    }

    func testTheDeadlineDefaultsToSettings() async throws {
        let server = try await start()
        let (project, request) = try makeProject(echoSpec("Unary", messages: [#"{"text": "hang"}"#]), server: server)
        settings.update { $0.grpcDeadlineSeconds = 1 }

        let exchange = await makeRunner().run(request, in: project)

        XCTAssertEqual(exchange.grpc?.status?.name, "DEADLINE_EXCEEDED", "\(exchange.outcome)")
    }

    func testPrepareAndCopyAsCurlStayHTTPOnly() async throws {
        let server = try await start()
        let (project, request) = try makeProject(echoSpec("Unary"), server: server)

        XCTAssertThrowsError(try makeRunner().prepare(request, in: project)) { error in
            let message = "“Echo” is a gRPC request; this works only with HTTP requests."
            XCTAssertEqual(error as? RunFailure, RunFailure(kind: .invalidRequest, message: message))
        }
    }
}

// MARK: - Helpers

extension GRPCRunnerTests {
    func start(_ extra: [any RegistrableRPCService] = []) async throws -> GRPCTestServer {
        let server = try await GRPCTestServer.start([EchoService(log: log)] + extra)
        servers.append(server)
        return server
    }

    func makeRunner(schemas: GRPCSchemaService? = nil) -> RequestRunner {
        RequestRunner(
            library: fixture.library,
            workspace: workspace,
            settings: settings,
            keychain: EmptyKeychain(),
            cache: ResponseCache(directory: fixture.directory.file("Support/Responses")),
            userAgent: "Reqling/1.0",
            grpcSchemas: schemas ?? makeSchemas()
        )
    }

    /// Workspaces compile with whatever protoc `locateProtoc` finds; only the project-protos test needs a real one.
    func makeSchemas(protoc: ProtocInstallation? = nil) -> GRPCSchemaService {
        makeSchemas(locateProtoc: { protoc })
    }

    func makeSchemas(locateProtoc: @escaping @Sendable () async throws -> ProtocInstallation?) -> GRPCSchemaService {
        let environment = ProtoWorkspaceEnvironment(
            importer: ProtocImporter(cacheDirectory: fixture.directory.file("Support/ProtocCache")),
            locateProtoc: locateProtoc,
            changes: { _ in AsyncStream { $0.finish() } }
        )
        return GRPCSchemaService(workspaces: ProtoWorkspaceStore(environment: environment))
    }

    func echoSpec(
        _ method: String,
        messages: [String] = [#"{"text": "hi"}"#],
        schema: GRPCSchemaSource = .descriptorSet(.relative("codec_test.binpb"))
    ) -> GRPCRequestSpec {
        GRPCRequestSpec(target: "{{target}}", service: EchoService.name, method: method, messages: messages, schema: schema)
    }

    /// A project whose `target` variable points at `server`, holding one request named "Echo" and the codec fixture's
    /// descriptor set.
    func makeProject(_ spec: GRPCRequestSpec, server: GRPCTestServer, variables: [Variable] = []) throws -> (ProjectID, RequestNodeID) {
        let project = try fixture.library.createProject(named: "gRPC \(UUID().uuidString.prefix(4))")
        let item = RequestItem(name: "Echo", kind: .grpc(spec))
        try fixture.library.mutate(project) { document in
            document.defaultEnvironment.variables = [Variable(key: "target", value: server.target.description)] + variables
            try document.insert(.request(item), into: nil)
        }
        try FileManager.default.copyItem(
            at: try ProtocFixtures.codecDescriptorSet,
            to: fixture.projectURL(project).appendingPathComponent("codec_test.binpb")
        )
        return (project, item.id)
    }

    func json(_ event: GRPCMessageEvent?) throws -> NSDictionary {
        let data = Data(try XCTUnwrap(event).json.utf8)
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? NSDictionary)
    }

    /// The `text` of each message one way, in order.
    func texts(_ call: GRPCCallRecord, _ direction: GRPCMessageEvent.Direction) throws -> [String] {
        try call.events.filter { $0.direction == direction }.map { try json($0).value(forKey: "text") as? String ?? "" }
    }

    /// Returns once `condition` holds, re-checking whenever what it reads changes.
    func waitUntil(_ description: String, _ condition: @escaping @MainActor () -> Bool) async {
        let done = expectation(description: description)
        let waiting = Task { @MainActor in
            while !condition() {
                await withCheckedContinuation { continuation in
                    withObservationTracking {
                        _ = condition()
                    } onChange: {
                        continuation.resume()
                    }
                }
            }
            done.fulfill()
        }
        await fulfillment(of: [done], timeout: 30)
        waiting.cancel()
    }
}

extension RequestKind {
    mutating func updateGRPC(_ change: (inout GRPCRequestSpec) -> Void) {
        if case .grpc(var spec) = self {
            change(&spec)
            self = .grpc(spec)
        }
    }
}
