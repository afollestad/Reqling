import ReqlingKit
import SwiftUI
import XCTest

@testable import Reqling

/// An event-stream response's Events tab, in place of a body.
extension SnapshotTests {
    private static let eventStreamSize = CGSize(width: 820, height: 340)

    /// Tree mode: a row per event, JSON data opened to its fields, plain data inline, and the reconnect between.
    func testResponseEventStreamTree() throws {
        let response = try eventStreamResponse(end: .closed)
        assertBothAppearances(ResponseView(response: response, model: fixture.model), size: Self.eventStreamSize)
    }

    /// Text mode: each event's data whole, JSON highlighted, with the notes in place.
    func testResponseEventStreamText() throws {
        let response = try eventStreamResponse(end: .closed)
        response.eventsMode = .text
        assertBothAppearances(ResponseView(response: response, model: fixture.model), size: Self.eventStreamSize)
    }

    /// An open stream: Streaming… in the status bar, and the timeline waiting for more.
    func testResponseEventStreamOpen() throws {
        let response = try eventStreamResponse(end: nil)
        assertBothAppearances(ResponseView(response: response, model: fixture.model), size: Self.eventStreamSize)
    }

    /// The pill a live timeline raises while scrolled away from its newest entry.
    func testJumpToBottomButton() {
        assertBothAppearances(JumpToBottomButton {}.padding(.horizontal, 16).padding(.top, 12), size: CGSize(width: 220, height: 64))
    }

    private func eventStreamResponse(end: EventStreamRecord.End?) throws -> ResponseViewModel {
        let project = try SnapshotProject.make(in: fixture)
        let kinds: [(TimeInterval, EventStreamEntry.Kind)] = [
            (0.21, .event(ServerSentEvent(type: "update", id: "41", data: #"{"user":"Ada","status":"online"}"#))),
            (15.02, .event(ServerSentEvent(type: "ping", data: "keep-alive"))),
            (30.4, .note("The server closed the stream. Reconnecting in 3 s with Last-Event-ID 41.")),
            (33.5, .note("Reconnected")),
            (33.6, .event(ServerSentEvent(type: "update", id: "42", data: #"{"user":"Grace","status":"away"}"#)))
        ]
        let entries = kinds.enumerated().map { EventStreamEntry(sequence: $0, offset: $1.0, kind: $1.1) }
        let record = HTTPResponseRecord(
            statusCode: 200,
            headers: [KeyValuePair(key: "Content-Type", value: "text/event-stream")],
            body: Data(),
            url: "https://api.example.com/users/events",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            duration: 41.2,
            protocolName: "h2",
            tlsVersion: "TLS 1.3",
            eventStream: EventStreamRecord(entries: entries, receivedByteCount: 412, reconnectCount: 1, lastEventID: "42", end: end)
        )
        project.cacheExchange(.response(record), for: project.listUsers, in: fixture)
        return try project.editor(project.listUsers, in: fixture).response
    }
}
