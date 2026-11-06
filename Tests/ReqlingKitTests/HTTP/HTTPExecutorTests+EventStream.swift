import Foundation
import NIOHTTP1
import ReqlingKit
import XCTest

/// Event-stream responses through `executeStreaming`: read as they arrive, and ended without throwing.
extension HTTPExecutorTests {
    private static let eventStream = [("Content-Type", "text/event-stream; charset=utf-8")]

    func testAnEventStreamDeliversEachEventAsItArrives() async throws {
        let feed = StreamFeed()
        let server = try await start { _ in .stream(headers: Self.eventStream, feed: feed) }
        let (events, delivered) = AsyncStream<HTTPStreamEvent>.makeStream()
        let prepared = try prepare(HTTPRequestSpec(url: "\(server.baseURL)/feed"))
        let task = Task { try await HTTPExecutor().executeStreaming(prepared, tls: .default) { delivered.yield($0) } }
        var received = events.makeAsyncIterator()

        await feed.opened()
        // URLSession reports the head only with the first body bytes; the first event then arrives while the response
        // is still open. It is tiny, so a response held back to sniff its type would never deliver it here.
        try await feed.send("data: one\n\n")
        guard case .opened(let head, _) = await received.next(), case .event(let first, 0, _, _) = await received.next() else {
            return XCTFail("The head comes first, then the event")
        }
        let rest = ": keep-alive\nid: 7\nevent: tick\ndata: two\ndata: lines\n\nretry: 1500\n\n"
        try await feed.send(rest)
        try await feed.end()
        let result = try await task.value
        delivered.finish()
        var later: [HTTPStreamEvent] = []
        while let event = await received.next() {
            later.append(event)
        }

        XCTAssertEqual(head.statusCode, 200)
        XCTAssertEqual(head.header("Content-Type"), "text/event-stream; charset=utf-8")
        XCTAssertTrue(head.body.isEmpty)
        XCTAssertEqual(first, ServerSentEvent(data: "one"))
        guard later.count == 3, case .lastEventID("7") = later[0], case .event(let second, 1, _, _) = later[1],
              case .retry(milliseconds: 1500) = later[2] else {
            return XCTFail("Unexpected events: \(later)")
        }
        XCTAssertEqual(second, ServerSentEvent(type: "tick", id: "7", data: "two\nlines"))
        guard case .stream(let finalHead, .closed, let byteCount) = result else {
            return XCTFail("A server that ends the response closes the stream: \(result)")
        }
        XCTAssertEqual(finalHead.protocolName, "http/1.1", "The final head carries the connection's metrics")
        XCTAssertEqual(byteCount, ("data: one\n\n" + rest).utf8.count, "Every byte counts, comments included")
    }

    /// Only a 200 of type `text/event-stream` streams; an error page of that type, or a 200 of another, is read whole.
    func testOtherResponsesAreCollectedWhole() async throws {
        let server = try await start { request in
            request.uri == "/error"
                ? .text("data: nope\n\n", status: .internalServerError, headers: Self.eventStream)
                : .text("<p>hi</p>", headers: [("Content-Type", "text/html")])
        }
        for path in ["/error", "/page"] {
            let prepared = try prepare(HTTPRequestSpec(url: "\(server.baseURL)\(path)"))

            let result = try await HTTPExecutor().executeStreaming(prepared, tls: .default) { event in
                XCTFail("\(path) delivered \(event)")
            }

            guard case .response(let response) = result else {
                return XCTFail("\(path) streamed")
            }
            XCTAssertFalse(response.body.isEmpty, path)
            XCTAssertNil(response.eventStream, path)
        }
    }

    /// `execute`, which GraphQL introspection and the like use, never streams: a finite event stream is just a body.
    func testExecuteCollectsAnEventStreamWhole() async throws {
        let feed = StreamFeed()
        let server = try await start { _ in .stream(headers: Self.eventStream, feed: feed) }
        let prepared = try prepare(HTTPRequestSpec(url: server.baseURL))
        let task = Task { try await HTTPExecutor().execute(prepared, tls: .default) }

        await feed.opened()
        try await feed.send("data: one\n\n")
        try await feed.end()
        let response = try await task.value

        XCTAssertEqual(response.body.utf8Text, "data: one\n\n")
        XCTAssertNil(response.eventStream)
    }

    func testStoppingAStreamEndsItRatherThanThrowing() async throws {
        let feed = StreamFeed()
        let server = try await start { _ in .stream(headers: Self.eventStream, feed: feed) }
        let result = try await streamUntilFirstEvent(from: server, feed: feed) { task in task.cancel() }

        guard case .stream(_, .stopped, _) = result else {
            return XCTFail("Expected a stopped stream: \(result)")
        }
    }

    /// The request's timeout is URLSession's idle timeout, so a stream silent for longer than it ends.
    func testASilentStreamTimesOut() async throws {
        let feed = StreamFeed()
        let server = try await start { _ in .stream(headers: Self.eventStream, feed: feed) }
        let result = try await streamUntilFirstEvent(from: server, feed: feed, timeout: 0.5) { _ in }

        guard case .stream(_, .timedOut, _) = result else {
            return XCTFail("Expected a timed-out stream: \(result)")
        }
    }

    /// Opens a stream, waits for its first event, does `then`, and returns how it ended.
    private func streamUntilFirstEvent(
        from server: TestHTTPServer,
        feed: StreamFeed,
        timeout: Double = 10,
        then: (Task<HTTPExecution, any Error>) async -> Void
    ) async throws -> HTTPExecution {
        let (events, delivered) = AsyncStream<HTTPStreamEvent>.makeStream()
        let prepared = try prepare(HTTPRequestSpec(url: server.baseURL), timeout: timeout)
        let task = Task<HTTPExecution, any Error> {
            try await HTTPExecutor().executeStreaming(prepared, tls: .default) { delivered.yield($0) }
        }
        await feed.opened()
        try await feed.send("data: one\n\n")
        for await event in events {
            if case .event = event {
                break
            }
        }
        await then(task)
        return try await task.value
    }
}
