import Foundation
import MCP
import Network
@testable import ReqlingKit
import XCTest

/// The server as clients reach it: `MCPServerController` on loopback port 0, checked with raw HTTP for what the
/// listener refuses, and with the SDK's own client for what it serves.
@MainActor
final class MCPServerTests: XCTestCase {
    private var fixture: MCPFixture!
    private var controller: MCPServerController!
    private var tokens: InMemoryMCPTokenStore!
    private var port = 0

    override func setUp() async throws {
        fixture = try MCPFixture()
        tokens = InMemoryMCPTokenStore(token: "test-token")
        controller = MCPServerController(context: fixture.context, settings: fixture.settings, tokenStore: tokens, bindPort: { _ in 0 })
        fixture.settings.update { $0.mcpEnabled = true }
        controller.sync()
        await controller.settled()
        guard case .running(let port) = controller.status else {
            return XCTFail("Expected the server to run, got \(String(describing: controller.status))")
        }
        self.port = port
    }

    override func tearDown() async throws {
        await controller.shutDown()
        fixture.cleanUp()
    }

    // MARK: - Refusals

    func testRequestsWithoutTheTokenAreRefused() async throws {
        let missing = try await post(authorization: nil)
        let wrong = try await post(authorization: "Bearer test-tokem")

        XCTAssertEqual(missing.status, 401)
        XCTAssertEqual(missing.headers["Www-Authenticate"], "Bearer")
        XCTAssertEqual(wrong.status, 401)
        let accepted = try await post()
        XCTAssertEqual(accepted.status, 200)
    }

    func testAForeignOriginOrHostIsRefused() async throws {
        let origin = try await post(extraHeaders: ["Origin": "https://evil.example"])
        let rebinding = try await raw(head(host: "attacker.example:\(port)", contentLength: 2) + "{}")

        XCTAssertEqual(origin.status, 403)
        XCTAssertEqual(rebinding, 421, "A DNS-rebinding page names its own host")
    }

    func testOversizedBodiesAndOtherPathsAreRefused() async throws {
        let oversized = try await raw(head(host: "127.0.0.1:\(port)", contentLength: 2_000_000))
        let elsewhere = try await raw(head(host: "127.0.0.1:\(port)", contentLength: 2, path: "/admin") + "{}")

        XCTAssertEqual(oversized, 413)
        XCTAssertEqual(elsewhere, 404)
    }

    func testRegeneratingTheTokenLocksOutTheOldOne() async throws {
        try controller.regenerateToken()

        let old = try await post()
        let fresh = try await post(authorization: "Bearer \(try XCTUnwrap(controller.token))")

        XCTAssertEqual(old.status, 401)
        XCTAssertEqual(fresh.status, 200)
        XCTAssertEqual(try tokens.load(), controller.token)
    }

    func testAPortInUseIsReportedAndTurningOffStops() async throws {
        let busy = MCPServerController(context: fixture.context, settings: fixture.settings, tokenStore: tokens, bindPort: { [port] _ in port })
        busy.sync()
        await busy.settled()

        XCTAssertEqual(busy.status, .failed(MCPServerError.portInUse(port).localizedDescription))

        fixture.settings.update { $0.mcpEnabled = false }
        controller.sync()
        await controller.settled()

        XCTAssertEqual(controller.status, .stopped)
        let refused = await (try? post()) == nil
        XCTAssertTrue(refused, "Nothing listens once it is off")
    }

    // MARK: - End to end

    /// The plan's agent journey through the SDK client: projects, variables with a secret, a template, a run, and
    /// cleanup to the Trash.
    func testAnAgentManagesAProjectAndRunsATemplate() async throws {
        let echo = try await TestHTTPServer.start { request in
            .text("\(request.uri) \(request.header("Authorization") ?? "-")")
        }
        addTeardownBlock { try? await echo.shutdown() }
        let client = Client(name: "test-agent", version: "1.0")
        let transport = try Self.transport(port: port)
        let initialized = try await client.connect(transport: transport)
        XCTAssertEqual(initialized.serverInfo.name, "reqling")
        let listed = try await client.listTools()
        XCTAssertEqual(listed.tools.count, fixture.dispatcher.tools.count)

        func call(_ name: String, _ arguments: [String: Value]) async throws -> [String: Value] {
            try await Self.call(client, name, arguments)
        }

        let created = try await call("create_project", ["name": "Agent API"])
        let project = try XCTUnwrap(created["project"]?["id"])
        let projects = try await call("list_projects", [:])
        XCTAssertEqual(projects["projects"]?.arrayValue?.count, 1)

        _ = try await call("create_variables", ["project": project, "variables": [
            ["key": "baseUrl", "value": .string(echo.baseURL)],
            ["key": "token", "value": "agent-secret-1", "secret": true],
            ["key": "scratch", "value": "x"]
        ]])
        let variables = try await call("list_variables", ["project": project])
        _ = try await call("update_variables", ["project": project, "variables": [["key": "scratch", "value": "y"]]])
        _ = try await call("delete_variables", ["project": project, "keys": ["scratch"]])

        let request = try await call("create_request", [
            "project": project,
            "name": "Whoami",
            "http": ["url": "{{baseUrl}}/me", "headers": [["key": "Authorization", "value": "Bearer {{token}}"]]]
        ])
        let requestID = try XCTUnwrap(request["request"]?["id"])
        let requests = try await call("list_requests", ["project": project])
        XCTAssertEqual(requests["requests"]?.arrayValue?.count, 1)
        _ = try await call("update_request", ["project": project, "request": requestID, "spec": ["url": "{{baseUrl}}/whoami"]])
        let run = try await call("execute_request", ["project": project, "request": requestID])

        XCTAssertEqual(echo.requests.last?.uri, "/whoami")
        XCTAssertEqual(echo.requests.last?.header("Authorization"), "Bearer agent-secret-1", "The server got the real value")
        XCTAssertFalse(MCPJSON.text(.object(run)).contains("agent-secret-1"), "The agent never sees it")
        XCTAssertNil(variables["variables"]?.arrayValue?.first { $0["key"] == "token" }?["value"])
        let projectID = try XCTUnwrap(project.stringValue.flatMap(ProjectID.init(string:)))
        XCTAssertFalse(try projectFiles(projectID).contains("agent-secret-1"), "No secret on disk")
        let resource = try await client.readResource(uri: "reqling://projects/\(projectID)")
        XCTAssertEqual(resource.first?.mimeType, "application/json")

        _ = try await call("delete_request", ["project": project, "request": requestID])
        _ = try await call("delete_project", ["project": project])

        let remaining = try await call("list_projects", [:])
        XCTAssertEqual(remaining["projects"]?.arrayValue?.count, 0)
        XCTAssertEqual(fixture.storage.trashedNames(), ["Agent API.reqling", "whoami.json"])
        await client.disconnect()
    }

    /// A second client (or the same one reconnecting) initializes again, which the SDK's own handler would refuse.
    func testEveryClientCanInitialize() async throws {
        for name in ["claude", "codex"] {
            let client = Client(name: name, version: "1.0")
            let transport = try Self.transport(port: port)
            let result = try await client.connect(transport: transport)
            XCTAssertEqual(result.serverInfo.name, "reqling")
            await client.disconnect()
        }
    }

    // MARK: - Helpers

    /// A tool's JSON text, as an object, failing the test when the call reports an error.
    private static func call(_ client: Client, _ name: String, _ arguments: [String: Value]) async throws -> [String: Value] {
        let (content, isError) = try await client.callTool(name: name, arguments: arguments)
        guard case .text(let text, _, _)? = content.first else {
            XCTFail("\(name) returned no text")
            return [:]
        }
        XCTAssertNotEqual(isError, true, "\(name): \(text)")
        return try XCTUnwrap(try JSONDecoder().decode(Value.self, from: Data(text.utf8)).objectValue)
    }

    /// Every JSON file in the project's folder, joined.
    private func projectFiles(_ project: ProjectID) throws -> String {
        let folder = fixture.storage.projectURL(project)
        return try FileManager.default.subpathsOfDirectory(atPath: folder.path)
            .filter { $0.hasSuffix(".json") }
            .map { try String(contentsOf: folder.appendingPathComponent($0), encoding: .utf8) }
            .joined()
    }

    /// The SDK's client transport, sending the test token, without SSE (the server answers each POST with JSON).
    private nonisolated static func transport(port: Int) throws -> HTTPClientTransport {
        HTTPClientTransport(
            endpoint: try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/mcp")),
            configuration: .ephemeral,
            streaming: false,
            requestModifier: { request in
                var request = request
                request.setValue("Bearer test-token", forHTTPHeaderField: "Authorization")
                return request
            }
        )
    }

    private struct Reply {
        let status: Int
        let headers: [String: String]
    }

    private func post(authorization: String? = "Bearer test-token", extraHeaders: [String: String] = [:]) async throws -> Reply {
        var request = URLRequest(url: try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/mcp")))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        for (name, value) in extraHeaders {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.httpBody = Data(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#.utf8)
        let (_, response) = try await URLSession(configuration: .ephemeral).data(for: request)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        let headers = http.allHeaderFields.reduce(into: [String: String]()) { result, entry in
            result["\(entry.key)"] = "\(entry.value)"
        }
        return Reply(status: http.statusCode, headers: headers)
    }

    private func head(host: String, contentLength: Int, path: String = "/mcp") -> String {
        "POST \(path) HTTP/1.1\r\nHost: \(host)\r\nAuthorization: Bearer test-token\r\nContent-Type: application/json\r\n"
            + "Accept: application/json\r\nContent-Length: \(contentLength)\r\n\r\n"
    }

    /// Sends `request` as written, for headers URLSession won't send as given, and returns the status code.
    private func raw(_ request: String) async throws -> Int {
        let connection = NWConnection(host: "127.0.0.1", port: try XCTUnwrap(NWEndpoint.Port(rawValue: UInt16(port))), using: .tcp)
        defer { connection.cancel() }
        connection.start(queue: .global())
        return try await withCheckedThrowingContinuation { continuation in
            connection.send(content: Data(request.utf8), completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                connection.receive(minimumIncompleteLength: 12, maximumLength: 4_096) { data, _, _, error in
                    guard let data, let line = String(data: data, encoding: .utf8)?.split(separator: " "), line.count > 1,
                          let status = Int(line[1]) else {
                        continuation.resume(throwing: error ?? URLError(.badServerResponse))
                        return
                    }
                    continuation.resume(returning: status)
                }
            })
        }
    }
}
