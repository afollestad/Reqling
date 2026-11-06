import Foundation
import MCP
@testable import ReqlingKit
import XCTest

/// WebSocket requests through the MCP tools: their specs in on-disk JSON, and runs bounded so a tool call always
/// returns with what crossed the connection, masked.
@MainActor
final class MCPWebSocketToolsTests: XCTestCase {
    private var fixture: MCPFixture!
    private var sleeper: TestSleeper!
    private var server: TestWebSocketServer!
    private var project: ProjectID!
    private var request: String!

    override func setUp() async throws {
        sleeper = TestSleeper(returnsAtOnce: false)
        fixture = try MCPFixture(runnerSleep: sleeper.sleep)
        server = try await TestWebSocketServer.start()
        project = try await fixture.makeProject()
        _ = try await fixture.success("create_variables", ["project": .string(project.description), "variables": [
            ["key": "socketUrl", "value": .string(server.url)],
            ["key": "token", "value": "t0ken-secret", "secret": true]
        ]])
        let created = try await fixture.success("create_request", [
            "project": .string(project.description),
            "name": "Chat",
            "websocket": [
                "url": "{{socketUrl}}/chat?key={{token}}",
                "messages": [["text": #"{"auth":"{{token}}"}"#], ["format": "binary", "text": "aGk=", "sendOnConnect": false]]
            ]
        ])
        request = try XCTUnwrap(created["request"]?["id"]?.stringValue)
    }

    override func tearDown() async throws {
        try await server.shutdown()
        fixture.cleanUp()
    }

    private var arguments: [String: Value] {
        ["project": .string(project.description), "request": .string(request)]
    }

    func testASpecRoundTripsInItsOnDiskJSON() async throws {
        let fetched = try await fixture.success("get_request", arguments)
        let spec = try XCTUnwrap(fetched["request"]?["websocket"])
        let messageID = try XCTUnwrap(spec["messages"]?.arrayValue?.first?["id"]?.stringValue)

        _ = try await fixture.success("update_request", arguments.merging([
            "spec": ["messages": [["id": .string(messageID), "text": "changed"]], "subprotocols": ["chat"]]
        ]) { $1 })
        let listed = try await fixture.success("list_requests", ["project": .string(project.description), "kind": "websocket"])

        XCTAssertEqual(fetched["request"]?["kind"], "websocket")
        XCTAssertEqual(spec["url"], "{{socketUrl}}/chat", "The query moved into its table")
        XCTAssertEqual(spec["queryParameters"]?.arrayValue?.first?["value"], "{{token}}")
        let id = try XCTUnwrap(RequestNodeID(string: request))
        let stored = try XCTUnwrap(try fixture.document(project).request(id)?.kind.webSocketSpec)
        XCTAssertEqual(stored.messages.map(\.text), ["changed"], "A row with its ID merges in place; the one left out is removed")
        XCTAssertEqual(stored.subprotocols, ["chat"])
        XCTAssertEqual(listed["requests"]?.arrayValue?.map { $0["kind"] }, ["websocket"])
        XCTAssertEqual(listed["requests"]?.arrayValue?.first?["url"], "{{socketUrl}}/chat?key={{token}}")
    }

    /// The handshake, the messages both ways, and the close come back masked, even a secret the server echoes.
    func testARunReturnsItsConnectionOnceItReachesItsMessageBound() async throws {
        let result = try await fixture.success("execute_request", arguments.merging(["streamEvents": 1]) { $1 })

        let connection = try XCTUnwrap(result["connection"])
        XCTAssertEqual(connection["end"], "limit")
        XCTAssertEqual(connection["handshake"]?["status"], 101)
        XCTAssertEqual(connection["close"]?["code"], 1000)
        XCTAssertEqual(connection["close"]?["byServer"], false)
        let messages = try XCTUnwrap(connection["entries"]?.arrayValue?.filter { $0["text"] != nil })
        XCTAssertEqual(messages.map { $0["direction"] }, ["sent", "received"])
        XCTAssertEqual(messages.map { $0["text"] }, [#"{"auth":"••••••"}"#, #"{"auth":"••••••"}"#])
        XCTAssertEqual(server.handshakes.first?.uri, "/chat?key=t0ken-secret")
        XCTAssertFalse(String(describing: result).contains("t0ken-secret"))
        XCTAssertNotNil(result["run"])

        let runs = try await fixture.success("list_runs", arguments)
        XCTAssertEqual(runs["runs"]?.arrayValue?.first?["closeCode"], 1000)
        XCTAssertEqual(runs["runs"]?.arrayValue?.first?["outcome"], "succeeded")
    }

    /// With no bound given, a connection is held for 30 seconds on the runner's clock.
    func testARunClosesAtItsTimeBound() async throws {
        // A handshake timeout of its own, so its deadline's sleep can't pass for the bound's.
        _ = try await fixture.success("update_request", arguments.merging(["spec": ["options": ["timeoutSeconds": 10]]]) { $1 })
        let run = Task { try await fixture.success("execute_request", arguments) }
        var requests = sleeper.requests.makeAsyncIterator()
        while await requests.next() != .seconds(30) {}
        sleeper.wake()
        let result = try await run.value

        XCTAssertEqual(result["connection"]?["end"], "limit")
    }

    func testMessagesReplaceTheOnConnectOnesAsTextOrBinary() async throws {
        let messages: Value = ["plain", ["type": "subscribe"], ["format": "binary", "text": "aGk="]]
        var frames = server.frames.makeAsyncIterator()

        _ = try await fixture.success("execute_request", arguments.merging(["messages": messages, "streamEvents": 3]) { $1 })
        var received: [TestWebSocketServer.Frame] = []
        while received.count < 3, let frame = await frames.next() {
            received.append(frame)
        }

        XCTAssertEqual(received.map(\.opcode), [.text, .text, .binary])
        XCTAssertEqual(received.map(\.text), ["plain", #"{"type":"subscribe"}"#, "hi"])
        let error = await fixture.failure("execute_request", arguments.merging(["messages": [["format": "binary"]]]) { $1 })
        XCTAssertTrue(error.contains("with a `format` must be"), error)
    }

    func testAnAdHocConnectionRunsWithoutBeingSavedOrShown() async throws {
        let result = try await fixture.success("execute_ad_hoc_request", [
            "project": .string(project.description),
            "websocket": ["url": "{{socketUrl}}", "messages": [["text": "hello"]]],
            "streamEvents": 1
        ])

        XCTAssertEqual(result["connection"]?["end"], "limit")
        XCTAssertNil(result["run"])
        XCTAssertEqual(fixture.runner.latest.count, 0)
    }

    func testResolveShowsTheHandshakeAndOnConnectMessagesMasked() async throws {
        let resolved = try await fixture.success("resolve_request", arguments)

        XCTAssertEqual(resolved["request"]?["method"], "GET")
        let url = try XCTUnwrap(resolved["request"]?["url"]?.stringValue)
        XCTAssertTrue(url.hasPrefix("\(server.url)/chat?key="), url)
        XCTAssertFalse(url.contains("t0ken-secret"))
        XCTAssertEqual(resolved["messages"]?.arrayValue?.map { $0["text"] }, [#"{"auth":"••••••"}"#], "Only the on-connect ones")
        XCTAssertTrue(server.handshakes.isEmpty, "Nothing connects")
    }

    func testWhatOnlyHTTPHasIsRefusedClearly() async throws {
        let curl = await fixture.failure("export_curl", arguments)
        let twoSpecs = await fixture.failure("create_request", [
            "project": .string(project.description), "name": "Both", "http": [:], "websocket": [:]
        ])

        XCTAssertEqual(curl, "“Chat” is a WebSocket request; this works only with HTTP requests.")
        XCTAssertEqual(twoSpecs, "Pass one of `http`, `grpc`, or `websocket`, not more.")
    }
}
