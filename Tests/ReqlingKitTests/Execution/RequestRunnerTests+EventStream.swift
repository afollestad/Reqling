import Foundation
@testable import ReqlingKit
import Synchronization
import XCTest

/// Event-stream responses through the runner: shown live, reconnected when GET, stopped by Cancel or a limit.
@MainActor
extension RequestRunnerTests {
    private static let eventStream = [("Content-Type", "text/event-stream")]

    func testAStreamShowsAsItGoesAndStoppingKeepsIt() async throws {
        let feed = StreamFeed()
        let server = try await streamServer([.stream(headers: Self.eventStream, feed: feed)])
        let key = try makeStreamProject(url: server.baseURL)
        let runner = makeRunner()
        let run = Task { await runner.run(key.requestID, in: key.projectID) }

        await feed.opened()
        try await feed.send("id: 1\ndata: {\"n\":1}\n\n")
        await waitUntil("the event shows") { runner.latest[key]?.response?.eventStream?.events.count == 1 }
        let partial = try XCTUnwrap(runner.latest[key])
        XCTAssertTrue(runner.eventStreams.contains(key))
        XCTAssertNil(partial.response?.eventStream?.end)
        XCTAssertNotNil(partial.request, "The Request tab shows what was sent while the stream is open")
        runner.cancel(key.requestID, in: key.projectID)
        let final = await run.value

        XCTAssertEqual(final.id, partial.id, "A partial exchange is the run's")
        XCTAssertEqual(final.response?.eventStream?.end, .stopped)
        XCTAssertEqual(final.response?.eventStream?.events, [ServerSentEvent(id: "1", data: "{\"n\":1}")])
        XCTAssertEqual(final.outcomeKind, .succeeded)
        XCTAssertFalse(runner.eventStreams.contains(key))
        XCTAssertEqual(runner.history.latest(for: key.requestID, in: key.projectID)?.id, final.id)
    }

    func testAGetStreamReconnectsWithItsLastEventIDUntilTheServerSaysNoMore() async throws {
        let first = StreamFeed()
        let second = StreamFeed()
        let server = try await streamServer([
            .stream(headers: Self.eventStream, feed: first),
            .stream(headers: Self.eventStream, feed: second),
            .reply(status: .noContent)
        ])
        let key = try makeStreamProject(url: server.baseURL)
        let sleeper = TestSleeper(returnsAtOnce: true)
        let runner = makeRunner(sleep: sleeper)
        let run = Task { await runner.run(key.requestID, in: key.projectID) }

        await first.opened()
        try await first.send("retry: 1500\nid: 41\ndata: a\n\n")
        try await first.end()
        await second.opened()
        try await second.send("data: b\n\n")
        try await second.end()
        let exchange = await run.value

        let stream = try XCTUnwrap(exchange.response?.eventStream)
        XCTAssertEqual(stream.end, .closed)
        XCTAssertEqual(stream.reconnectCount, 1)
        XCTAssertEqual(stream.lastEventID, "41")
        XCTAssertEqual(server.requests.map { $0.header("Last-Event-ID") }, [nil, "41", "41"])
        XCTAssertEqual(sleeper.durations, [.milliseconds(1_500), .milliseconds(1_500)], "The server's retry sets the delay")
        let reconnecting = "note The server closed the stream. Reconnecting in 1.5 s with Last-Event-ID 41."
        XCTAssertEqual(Self.describe(stream.entries), [
            "event a 41", reconnecting, "note Reconnected", "event b", reconnecting, "note The server answered 204 No Content, which ends the stream."
        ])
        XCTAssertEqual(stream.entries.map(\.sequence), Array(0..<6), "Sequences run on across connections")
        XCTAssertNotNil(exchange.response?.timing, "The first connection's metrics complete the head")
    }

    /// A POST would run again on reconnecting, so it ends when the server closes it.
    func testOtherMethodsNeverReconnect() async throws {
        let feed = StreamFeed()
        let server = try await streamServer([.stream(headers: Self.eventStream, feed: feed), .text("again")])
        let key = try makeStreamProject(url: server.baseURL, method: .post)
        let runner = makeRunner()
        let run = Task { await runner.run(key.requestID, in: key.projectID) }

        await feed.opened()
        try await feed.send("data: done\n\n")
        try await feed.end()
        let exchange = await run.value

        XCTAssertEqual(exchange.response?.eventStream?.end, .closed)
        XCTAssertEqual(server.requests.count, 1)
    }

    func testAReconnectAnsweredWithoutAStreamFailsIt() async throws {
        let feed = StreamFeed()
        let server = try await streamServer([.stream(headers: Self.eventStream, feed: feed), .text("down", status: .serviceUnavailable)])
        let key = try makeStreamProject(url: server.baseURL)
        let runner = makeRunner()
        let run = Task { await runner.run(key.requestID, in: key.projectID) }

        await feed.opened()
        try await feed.send("data: a\n\n")
        try await feed.end()
        let exchange = await run.value

        guard case .failed(let message) = exchange.response?.eventStream?.end else {
            return XCTFail("Expected a failed stream")
        }
        XCTAssertTrue(message.contains("503"), message)
        XCTAssertEqual(exchange.response?.statusCode, 200, "The head stays the first connection's")
        XCTAssertEqual(exchange.outcomeKind, .failed)
    }

    /// A reconnect that gets no response at all tries again, as the spec has it.
    func testAReconnectThatFailsToConnectTriesAgain() async throws {
        let feed = StreamFeed()
        let server = try await streamServer([.stream(headers: Self.eventStream, feed: feed), .hang, .reply(status: .noContent)])
        let key = try makeStreamProject(url: server.baseURL, timeout: 1)
        let runner = makeRunner()
        let run = Task { await runner.run(key.requestID, in: key.projectID) }

        await feed.opened()
        try await feed.send("data: a\n\n")
        try await feed.end()
        let exchange = await run.value

        let notes = Self.describe(exchange.response?.eventStream?.entries ?? []).filter { $0.hasPrefix("note") }
        XCTAssertEqual(notes.count, 3, "\(notes)")
        XCTAssertTrue(notes[1].hasPrefix("note Couldn't reconnect: The request timed out."), notes[1])
        XCTAssertEqual(exchange.response?.eventStream?.end, .closed)
        XCTAssertEqual(server.requests.count, 3)
    }

    func testStoppingWhileWaitingToReconnectKeepsTheTimeline() async throws {
        let feed = StreamFeed()
        let server = try await streamServer([.stream(headers: Self.eventStream, feed: feed)])
        let key = try makeStreamProject(url: server.baseURL)
        let sleeper = TestSleeper(returnsAtOnce: false)
        let runner = makeRunner(sleep: sleeper)
        let run = Task { await runner.run(key.requestID, in: key.projectID) }
        var requests = sleeper.requests.makeAsyncIterator()

        await feed.opened()
        try await feed.send("data: a\n\n")
        try await feed.end()
        _ = await requests.next()
        runner.cancel(key.requestID, in: key.projectID)
        let exchange = await run.value

        XCTAssertEqual(exchange.response?.eventStream?.end, .stopped)
        XCTAssertEqual(exchange.response?.eventStream?.events.map(\.data), ["a"])
        XCTAssertEqual(server.requests.count, 1)
    }

    func testAStreamStopsAtItsEventLimit() async throws {
        let feed = StreamFeed()
        let server = try await streamServer([.stream(headers: Self.eventStream, feed: feed)])
        let key = try makeStreamProject(url: server.baseURL)
        let runner = makeRunner()
        let options = RunOptions(streamLimit: StreamLimit(maxEvents: 2))
        let run = Task { await runner.run(key.requestID, in: key.projectID, options: options) }

        await feed.opened()
        try await feed.send("data: 1\n\ndata: 2\n\ndata: 3\n\n")
        let exchange = await run.value

        let stream = try XCTUnwrap(exchange.response?.eventStream)
        XCTAssertEqual(stream.end, .limit)
        XCTAssertEqual(stream.events.map(\.data), ["1", "2"])
        XCTAssertEqual(stream.eventCount, 2)
    }

    /// The time limit starts when the stream opens, on the injected clock.
    func testAStreamStopsAtItsTimeLimit() async throws {
        let feed = StreamFeed()
        let server = try await streamServer([.stream(headers: Self.eventStream, feed: feed)])
        let key = try makeStreamProject(url: server.baseURL)
        let sleeper = TestSleeper(returnsAtOnce: false)
        let runner = makeRunner(sleep: sleeper)
        let options = RunOptions(streamLimit: StreamLimit(maxDuration: .seconds(5)))
        let run = Task { await runner.run(key.requestID, in: key.projectID, options: options) }
        var requests = sleeper.requests.makeAsyncIterator()

        await feed.opened()
        try await feed.send("data: 1\n\n")
        let limit = await requests.next()
        sleeper.wake()
        let exchange = await run.value

        XCTAssertEqual(limit, .seconds(5))
        XCTAssertEqual(exchange.response?.eventStream?.end, .limit)
        XCTAssertEqual(exchange.response?.eventStream?.events.map(\.data), ["1"])
    }

    /// An open stream's partial exchange is newer than anything the history holds, so clearing leaves it showing.
    func testClearingHistoryLeavesAnOpenStreamShowing() async throws {
        let feed = StreamFeed()
        let server = try await streamServer([.stream(headers: Self.eventStream, feed: feed)])
        let key = try makeStreamProject(url: server.baseURL)
        let runner = makeRunner()
        let run = Task { await runner.run(key.requestID, in: key.projectID) }

        await feed.opened()
        try await feed.send("data: a\n\n")
        await waitUntil("the event shows") { runner.latest[key]?.response?.eventStream?.events.count == 1 }
        runner.clearHistory(for: key.requestID, in: key.projectID)
        runner.clearHistory(in: key.projectID)
        runner.clearAllHistory()

        XCTAssertNotNil(runner.latest[key])
        runner.cancel(key.requestID, in: key.projectID)
        _ = await run.value
    }

    func testAnUnsavedStreamIsNeverShown() async throws {
        let feed = StreamFeed()
        let server = try await streamServer([.stream(headers: Self.eventStream, feed: feed)])
        let key = try makeStreamProject(url: server.baseURL)
        let runner = makeRunner()
        let item = RequestItem.http("Ad hoc", url: server.baseURL)
        let options = RunOptions(streamLimit: StreamLimit(maxEvents: 1))
        let run = Task { await runner.runUnsaved(item, in: key.projectID, options: options) }

        await feed.opened()
        try await feed.send("data: a\n\n")
        let exchange = await run.value

        XCTAssertEqual(exchange.response?.eventStream?.events.map(\.data), ["a"])
        XCTAssertTrue(runner.latest.isEmpty)
    }

    /// Answers each request with the next of `responses`, repeating the last.
    private func streamServer(_ responses: [TestHTTPServer.Response]) async throws -> TestHTTPServer {
        let counter = RequestCounter()
        let server = try await TestHTTPServer.start { _ in responses[min(counter.next(), responses.count - 1)] }
        servers.append(server)
        return server
    }

    private func makeStreamProject(url: String, method: HTTPMethod = .get, timeout: Double? = nil) throws -> RunKey {
        let project = try fixture.library.createProject(named: "Streams")
        var request = RequestItem.http("Feed", method: method, url: url)
        if case .http(var spec) = request.kind {
            spec.options.timeoutSeconds = timeout
            request.kind = .http(spec)
        }
        try fixture.library.mutate(project) { try $0.insert(.request(request), into: nil) }
        return RunKey(request.id, in: project)
    }

    private static func describe(_ entries: [EventStreamEntry]) -> [String] {
        entries.map { entry in
            switch entry.kind {
            case .event(let event): (["event", event.data] + (event.id.map { [$0] } ?? [])).joined(separator: " ")
            case .note(let note): "note \(note)"
            }
        }
    }
}

private final class RequestCounter: Sendable {
    private let count = Mutex(0)

    func next() -> Int {
        count.withLock { count in
            defer { count += 1 }
            return count
        }
    }
}
