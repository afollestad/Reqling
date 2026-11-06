import Foundation
import Observation
import ReqlingKit
import XCTest

@testable import Reqling

@MainActor
final class ResponseViewModelTests: XCTestCase {
    private var fixture: AppFixture!
    private var project: ProjectID!

    override func setUp() async throws {
        fixture = AppFixture()
        fixture.model.createProject(named: "Responses")
        project = fixture.model.selection?.projectID
        fixture.model.newRequest()
    }

    override func tearDown() async throws {
        fixture.tearDown()
        fixture = nil
    }

    private var response: ResponseViewModel {
        fixture.model.editor!.asHTTP!.response
    }

    /// Makes a response the request's latest exchange. The runner's `latest` is Kit's to write, so this goes through the
    /// run history: `forget` drops the previous exchange, and reading it back loads this one.
    private func publish(_ body: Data, contentType: String?, at seconds: TimeInterval = 1_700_000_000, isTruncated: Bool = false) {
        let runner = fixture.component.requestRunner
        let request = response.requestID
        runner.forget(request, in: project)
        let startedAt = Date(timeIntervalSince1970: seconds)
        RunHistoryStore(directory: fixture.profile.historyDirectory).save(RequestExchange(
            projectID: project,
            requestID: request,
            startedAt: startedAt,
            environmentName: nil,
            request: nil,
            outcome: .response(HTTPResponseRecord(
                statusCode: 200,
                headers: contentType.map { [KeyValuePair(key: "Content-Type", value: $0)] } ?? [],
                body: body,
                url: "https://api.test",
                startedAt: startedAt,
                duration: 0.1
            )),
            isBodyTruncated: isTruncated
        ))
        _ = runner.exchange(for: request, in: project)
    }

    /// Makes an event stream the request's latest exchange, as `publish` does a body.
    private func publish(_ stream: EventStreamRecord, at seconds: TimeInterval = 1_700_000_000) {
        let runner = fixture.component.requestRunner
        let request = response.requestID
        runner.forget(request, in: project)
        let startedAt = Date(timeIntervalSince1970: seconds)
        RunHistoryStore(directory: fixture.profile.historyDirectory).save(RequestExchange(
            projectID: project,
            requestID: request,
            startedAt: startedAt,
            environmentName: nil,
            request: nil,
            outcome: .response(HTTPResponseRecord(
                statusCode: 200,
                headers: [KeyValuePair(key: "Content-Type", value: "text/event-stream")],
                body: Data(),
                url: "https://api.test/events",
                startedAt: startedAt,
                duration: 2,
                eventStream: stream
            ))
        ))
        _ = runner.exchange(for: request, in: project)
    }

    private static let streamEntries = [
        EventStreamEntry(sequence: 0, offset: 0.1, kind: .event(ServerSentEvent(type: "tick", id: "1", data: #"{"n":1}"#))),
        EventStreamEntry(sequence: 1, offset: 0.5, kind: .note("Reconnected")),
        EventStreamEntry(sequence: 2, offset: 0.9, kind: .event(ServerSentEvent(data: "line one\nline two")))
    ]

    private func text(_ presentation: ResponseBodyPresentation) -> String? {
        if case .text(let document) = presentation.content {
            return document.text(in: 0..<document.length)
        }
        return nil
    }

    func testASmallBodyShapesInlineAsATreeByDefault() {
        publish(Data(#"{"a":1}"#.utf8), contentType: "application/json")

        let body = response.body
        guard case .tree = body.content else {
            return XCTFail("\(body.content)")
        }
        XCTAssertEqual(body.availableModes, [.tree, .pretty, .raw])
        XCTAssertEqual(body.mode, .tree)
        XCTAssertNil(body.pendingShape)

        response.bodyMode = .pretty
        XCTAssertEqual(text(response.body), "{\n  \"a\": 1\n}")
    }

    /// The picker shows a mode the body offers, while the person's choice waits for a body that offers it again.
    func testAModeTheBodyDoesNotOfferFallsBackWithoutForgettingThePreference() {
        response.bodyMode = .pretty
        publish(Data("<a/>".utf8), contentType: "application/xml", at: 1)
        XCTAssertEqual(response.body.availableModes, [.tree, .raw])
        XCTAssertEqual(response.selectedBodyMode, .tree)
        XCTAssertEqual(response.bodyMode, .pretty)

        publish(Data("[1]".utf8), contentType: "application/json", at: 2)
        XCTAssertEqual(response.selectedBodyMode, .pretty)
        XCTAssertEqual(text(response.body), "[\n  1\n]")
    }

    func testSniffedTextThatIsNotJSONOffersOnlyRaw() {
        publish(Data("{not json".utf8), contentType: "text/plain")

        XCTAssertEqual(text(response.body), "{not json")
        XCTAssertEqual(response.body.availableModes, [.raw])
    }

    func testABodyThatIsNotUTF8IsBinary() {
        publish(Data([0xFF, 0xFE, 0x00]), contentType: "application/octet-stream")

        guard case .binary(let byteCount) = response.body.content else {
            return XCTFail("\(response.body.content)")
        }
        XCTAssertEqual(byteCount, 3)
    }

    func testALargeBodyShapesOffTheMainActorAndReRendersWhenDone() async throws {
        response.bodyMode = .pretty
        let items = (0..<40_000).map { #"{"index":\#($0)}"# }.joined(separator: ",")
        publish(Data("[\(items)]".utf8), contentType: "application/json")
        let pending = try XCTUnwrap(response.body.pendingShape)
        guard case .shaping = response.body.content else {
            return XCTFail("\(response.body.content)")
        }
        XCTAssertEqual(response.body.availableModes, [.tree, .pretty, .raw], "the picker shows while the body shapes")

        let reRendered = expectation(description: "the body re-renders once shaped")
        withObservationTracking {
            _ = response.body
        } onChange: {
            reRendered.fulfill()
        }
        response.startShaping(pending)
        await fulfillment(of: [reRendered], timeout: 60)

        XCTAssertEqual(text(response.body)?.hasPrefix("[\n  {\n    \"index\": 0\n  },"), true)
        XCTAssertNil(response.body.pendingShape)
    }

    /// Switching modes mid-shape supersedes the earlier shape; whichever finishes, only the mode shown lands.
    func testOnlyTheShapeStillWantedLands() async throws {
        response.bodyMode = .pretty
        let items = (0..<40_000).map { #"{"index":\#($0)}"# }.joined(separator: ",")
        publish(Data("[\(items)]".utf8), contentType: "application/json")
        response.startShaping(try XCTUnwrap(response.body.pendingShape))

        response.bodyMode = .raw
        response.startShaping(try XCTUnwrap(response.body.pendingShape))
        await waitUntil("the raw body shapes") { self.text(self.response.body) != nil }

        XCTAssertEqual(response.body.mode, .raw)
        XCTAssertEqual(text(response.body)?.hasPrefix(#"[{"index":0},"#), true)
    }

    /// A newer body that needs no shaping (a small one) cancels the shape still running for the old one, which would
    /// otherwise finish and hold a large body nobody reads.
    func testABodyThatNeedsNoShapingCancelsTheShapeStillRunning() throws {
        response.bodyMode = .pretty
        let items = (0..<40_000).map { #"{"index":\#($0)}"# }.joined(separator: ",")
        publish(Data("[\(items)]".utf8), contentType: "application/json", at: 1)
        response.startShaping(try XCTUnwrap(response.body.pendingShape))
        let running = try XCTUnwrap(response.shapingTask)

        publish(Data("[1]".utf8), contentType: "application/json", at: 2)
        XCTAssertNil(response.body.pendingShape)
        response.startShaping(response.body.pendingShape)

        XCTAssertTrue(running.isCancelled)
        XCTAssertNil(response.shapingKey)
        XCTAssertEqual(text(response.body), "[\n  1\n]")
    }

    /// A body that doesn't parse as its declared format explains itself in Tree mode rather than switching away.
    func testTreeModeExplainsABodyThatDoesNotParse() {
        publish(Data("{\"a\": }".utf8), contentType: "application/json")

        guard case .treeFailed(let message) = response.body.content else {
            return XCTFail("\(response.body.content)")
        }
        XCTAssertEqual(message, "Line 1, column 7: Expected a JSON value.")
        XCTAssertEqual(response.body.mode, .tree)
    }

    func testTheContentTypeIsTheResponsesHeader() {
        publish(Data("[1]".utf8), contentType: "application/json; charset=utf-8")
        XCTAssertEqual(response.contentType, "application/json; charset=utf-8")
    }

    /// A body restored from the cache, cut at its size limit, still opens as a tree of what was kept.
    func testARestoredCutBodyStillOpensAsATree() {
        let cut = Data(#"{"fuel_stations": [{"id": 1}, {"id": 2}, {"station_na"#.utf8)
        publish(cut, contentType: "application/json", isTruncated: true)

        guard case .tree(.json(let index)) = response.body.content else {
            return XCTFail("\(response.body.content)")
        }
        XCTAssertEqual(index.rootEntries().first?.isTruncated, true)

        publish(cut, contentType: "application/json", at: 2)
        guard case .treeFailed = response.body.content else {
            return XCTFail("a live body that ends early is an error: \(response.body.content)")
        }
    }

    /// A stream shows its events, never a body to shape: classifying its empty body would latch `.empty` for the run.
    func testAnEventStreamShowsItsEventsInPlaceOfABody() throws {
        publish(EventStreamRecord(entries: [], end: nil))
        XCTAssertTrue(response.eventTimeline.isEmpty)
        XCTAssertNil(response.body.pendingShape)

        publish(EventStreamRecord(entries: Self.streamEntries, end: nil))

        XCTAssertEqual(response.eventTimeline.map(\.item.text), [#"{"n":1}"#, "Reconnected", "line one\nline two"])
        XCTAssertFalse(response.eventTimeline[0].tokens.isEmpty, "JSON data is highlighted")
        XCTAssertTrue(response.eventTimeline[2].tokens.isEmpty, "Plain data is not")
        guard case .messages(let timeline) = try XCTUnwrap(response.eventTree) else {
            return XCTFail("The events make one timeline tree")
        }
        XCTAssertEqual(timeline.messages.map { $0.fields.count }, [1, 0, 0], "Only JSON data opens to fields")
        XCTAssertNil(response.body.pendingShape)
    }

    /// Copy and Save write the events back out as an event stream, with the notes as comments.
    func testCopyingAStreamWritesItsEventsBackOut() {
        publish(EventStreamRecord(entries: Self.streamEntries, end: .closed))

        response.copyBody(to: fixture.system)

        XCTAssertEqual(fixture.system.pasteboard, "id: 1\nevent: tick\ndata: {\"n\":1}\n\n: Reconnected\n\ndata: line one\ndata: line two\n\n")
    }
}
