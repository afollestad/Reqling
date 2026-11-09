import Foundation
import MCP
@testable import ReqlingKit
import XCTest

/// Event-stream responses through the execution tools, bounded so a tool call always returns with what arrived.
@MainActor
final class MCPEventStreamToolsTests: XCTestCase {
    private var fixture: MCPFixture!
    private var sleeper: TestSleeper!
    private var server: TestHTTPServer!
    private var feed: StreamFeed!
    private var project: ProjectID!
    private var request: String!

    override func setUp() async throws {
        sleeper = TestSleeper(returnsAtOnce: false)
        fixture = try MCPFixture(runnerSleep: sleeper.sleep)
        let feed = StreamFeed()
        self.feed = feed
        server = try await TestHTTPServer.start { _ in .stream(headers: [("Content-Type", "text/event-stream")], feed: feed) }
        project = try await fixture.makeProject()
        _ = try await fixture.success("create_variables", ["project": .string(project.description), "variables": [
            ["key": "baseUrl", "value": .string(server.baseURL)],
            ["key": "token", "value": "t0ken-secret", "secret": true]
        ]])
        let created = try await fixture.success("create_request", [
            "project": .string(project.description),
            "name": "Feed",
            "http": ["url": "{{baseUrl}}/feed", "auth": ["type": "bearer", "token": "{{token}}"]]
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

    /// The events come back masked, even a secret the server echoes into data or an ID.
    func testAStreamReturnsItsEventsOnceItReachesItsEventBound() async throws {
        let run = Task { try await fixture.success("execute_request", arguments.merging(["streamEvents": 2]) { $1 }) }

        await feed.opened()
        try await feed.send("id: t0ken-secret\nevent: echo\ndata: {\"token\":\"t0ken-secret\"}\n\ndata: two\n\ndata: three\n\n")
        let result = try await run.value

        let response = try XCTUnwrap(result["response"])
        XCTAssertEqual(response["end"], "limit")
        XCTAssertEqual(response["eventCount"], 2)
        XCTAssertNil(response["body"])
        let events = try XCTUnwrap(response["events"]?.arrayValue)
        XCTAssertEqual(events.map { $0["data"] }, [#"{"token":"••••••"}"#, "two"])
        XCTAssertEqual(events.first?["id"], "••••••")
        XCTAssertEqual(events.first?["type"], "echo")
        XCTAssertEqual(response["lastEventId"], "••••••")
        XCTAssertFalse(String(describing: result).contains("t0ken-secret"))
        XCTAssertNotNil(result["run"], "A saved request's stream is recorded like any run")
    }

    /// With no bound given, a stream is read for 30 seconds on the runner's clock.
    func testAStreamStopsAtItsTimeBound() async throws {
        let key = RunKey(try XCTUnwrap(RequestNodeID(string: request)), in: project)
        let run = Task { try await fixture.success("execute_request", arguments) }
        var requests = sleeper.requests.makeAsyncIterator()

        await feed.opened()
        try await feed.send("data: one\n\n")
        let bound = await requests.next()
        // The bound starts as the stream opens, so the event may still be on its way.
        await waitUntil("the event arrives") { self.fixture.runner.latest[key]?.response?.eventStream?.eventCount == 1 }
        sleeper.wake()
        let result = try await run.value

        XCTAssertEqual(bound, .seconds(30))
        XCTAssertEqual(result["response"]?["end"], "limit")
        XCTAssertEqual(result["response"]?["events"]?.arrayValue?.count, 1)
    }

    /// While a stream is open, its last response is the run so far, with no end yet.
    func testTheLastResponseOfAnOpenStreamIsThePartialRun() async throws {
        let key = RunKey(try XCTUnwrap(RequestNodeID(string: request)), in: project)
        let run = Task { try await fixture.success("execute_request", arguments.merging(["streamSeconds": 120]) { $1 }) }

        await feed.opened()
        try await feed.send("data: one\n\n")
        await waitUntil("the stream opens") { self.fixture.runner.eventStreams.contains(key) }
        let last = try await fixture.success("get_last_response", arguments)
        _ = try await fixture.success("cancel_request", arguments)
        let result = try await run.value

        XCTAssertEqual(last["inFlight"], true)
        XCTAssertEqual(last["response"]?["end"], .null)
        XCTAssertEqual(result["response"]?["end"], "stopped")
        XCTAssertEqual(result["response"]?["events"]?.arrayValue?.map { $0["data"] }, ["one"])
    }

    func testGRPCRequestsRefuseStreamBounds() async throws {
        let created = try await fixture.success("create_request", [
            "project": .string(project.description),
            "name": "Call",
            "grpc": ["target": "localhost:1", "service": "chat.Chat", "method": "Say"]
        ])
        let call = try XCTUnwrap(created["request"]?["id"]?.stringValue)

        let message = await fixture.failure("execute_request", [
            "project": .string(project.description), "request": .string(call), "streamSeconds": 5
        ])

        XCTAssertTrue(message.contains("streamSeconds"), message)
    }
}
