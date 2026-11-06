import Foundation
@testable import ReqlingKit
import XCTest

/// Quitting with live runs open records them instead of losing them (`RequestRunner.recordLiveRuns`).
@MainActor
extension RequestRunnerTests {
    func testQuittingRecordsAnOpenWebSocketClosingItWithGoingAway() async throws {
        let server = try await TestWebSocketServer.start()
        socketServers.append(server)
        let project = try fixture.library.createProject(named: "Quit")
        let request = RequestItem(name: "Chat", kind: .webSocket(WebSocketRequestSpec(url: server.url, messages: [WebSocketMessage(text: "hi")])))
        try fixture.library.mutate(project) { try $0.insert(.request(request), into: nil) }
        let key = RunKey(request.id, in: project)
        var frames = server.frames.makeAsyncIterator()
        let runner = makeRunner(sleep: TestSleeper(returnsAtOnce: false))

        let run = Task { await runner.run(request.id, in: project) }
        await waitUntil("the echo arrives") { runner.latest[key]?.webSocket?.receivedCount == 1 }
        runner.recordLiveRuns()
        runner.flushHistory()
        _ = await frames.next()
        let close = await frames.next()
        _ = await run.value
        runner.flushHistory()

        let runs = runner.history.runs(for: request.id, in: project)
        XCTAssertEqual(runs.count, 1, "Recorded once, though the run ended afterwards")
        XCTAssertEqual(runs.first?.status, .webSocket(.closed(code: 1001)))
        XCTAssertEqual(runs.first?.specKind, .webSocket)
        XCTAssertEqual(runs.first?.environmentName, "Default")
        let stored = await runner.history.exchange(try XCTUnwrap(runs.first?.id), for: request.id, in: project)
        XCTAssertEqual(stored?.webSocket?.end, .stopped)
        XCTAssertEqual(stored?.webSocket?.receivedCount, 1)
        XCTAssertEqual(close?.closeCode, 1001, "The close goes out as 1001 Going Away, not Disconnect's 1000")
        XCTAssertFalse(runner.isInFlight(request.id, in: project))
    }

    func testQuittingRecordsAnOpenEventStreamAndSkipsWhatNeverReachedAServerOrIsUnsaved() async throws {
        let feed = StreamFeed()
        let server = try await TestHTTPServer.start { request in
            request.uri == "/hang" ? .hang : .stream(headers: [("Content-Type", "text/event-stream")], feed: feed)
        }
        servers.append(server)
        let project = try fixture.library.createProject(named: "Quit")
        let stream = RequestItem.http("Feed", url: "\(server.baseURL)/feed")
        let unanswered = RequestItem.http("Nowhere", url: "\(server.baseURL)/hang")
        let unsaved = RequestItem.http("Unsaved", url: "\(server.baseURL)/other")
        try fixture.library.mutate(project) { document in
            try document.insert(.request(stream), into: nil)
            try document.insert(.request(unanswered), into: nil)
        }
        let key = RunKey(stream.id, in: project)
        let runner = makeRunner(sleep: TestSleeper(returnsAtOnce: false))

        let run = Task { await runner.run(stream.id, in: project) }
        await feed.opened()
        try await feed.send("data: one\n\n")
        await waitUntil("the event shows") { runner.latest[key]?.response?.eventStream?.events.count == 1 }
        let hanging = Task { await runner.run(unanswered.id, in: project) }
        let unsavedRun = Task { await runner.runUnsaved(unsaved, in: project) }
        await waitUntil("both are in flight") { runner.isInFlight(unanswered.id, in: project) && runner.isInFlight(unsaved.id, in: project) }
        runner.recordLiveRuns()
        runner.flushHistory()

        XCTAssertTrue(runner.history.runs(for: unanswered.id, in: project).isEmpty, "Nothing to keep from a request the server never answered")
        XCTAssertTrue(runner.history.runs(for: unsaved.id, in: project).isEmpty, "An unsaved run never records")
        XCTAssertTrue(runner.isInFlight(unanswered.id, in: project), "Left as it is")
        let runs = runner.history.runs(for: stream.id, in: project)
        XCTAssertEqual(runs.count, 1)
        let stored = await runner.history.exchange(try XCTUnwrap(runs.first?.id), for: stream.id, in: project)
        XCTAssertEqual(stored?.response?.eventStream?.end, .stopped)
        XCTAssertEqual(stored?.response?.eventStream?.events.map(\.data), ["one"])
        _ = await run.value
        hanging.cancel()
        unsavedRun.cancel()
        _ = await hanging.value
        _ = await unsavedRun.value
    }
}
