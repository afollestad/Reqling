import Foundation
@testable import ReqlingKit
import XCTest

/// How a WebSocket run's record is kept, summarized, compared, and shown on a timeline.
final class WebSocketRecordTests: XCTestCase {
    private func message(_ sequence: Int, _ direction: MessageDirection, _ text: String) -> WebSocketEntry {
        WebSocketEntry(
            sequence: sequence,
            offset: Double(sequence),
            kind: .message(WebSocketMessageRecord(direction: direction, format: .text, text: text)),
            byteCount: text.utf8.count
        )
    }

    private func exchange(_ record: WebSocketRecord) -> RequestExchange {
        RequestExchange(
            projectID: ProjectID(),
            requestID: RequestNodeID(),
            startedAt: Date(timeIntervalSince1970: 0),
            environmentName: "Default",
            spec: .webSocket(WebSocketRequestSpec(url: "wss://example.com")),
            request: ResolvedHTTPRequest(method: "GET", url: "wss://example.com", headers: [], bodyPreview: nil, bodyByteCount: 0),
            outcome: .webSocket(record)
        )
    }

    func testFittingTheHistoryCutsLongMessagesThenTheOldest() {
        let record = WebSocketRecord(url: "wss://x", entries: [
            message(0, .sent, String(repeating: "a", count: 10)),
            WebSocketEntry(sequence: 1, offset: 1, kind: .control(direction: .sent, text: "Ping 1")),
            message(2, .received, String(repeating: "b", count: 10)),
            message(3, .received, "cc")
        ])

        let fitted = record.fittingCache(messageLimit: 6, totalLimit: 9)

        XCTAssertTrue(fitted.wasCut)
        XCTAssertEqual(fitted.record.entries.map(\.sequence), [1, 2, 3], "A control frame costs nothing, so it stays with the newest")
        XCTAssertEqual(fitted.record.entries[1].message?.text, "bbbbbb")
        XCTAssertEqual(fitted.record.entries[1].byteCount, 10, "The size on the wire survives the cut")
        XCTAssertEqual(fitted.record.trimmedEntryCount, 1)
        XCTAssertEqual(fitted.record.receivedByteCount, 12, "Totals describe the whole connection")
        XCTAssertFalse(record.fittingCache(messageLimit: 64, totalLimit: 64).wasCut)
    }

    func testFailureFollowsTheEndAndTheCloseCode() {
        func record(_ end: WebSocketRecord.End?, _ code: Int?) -> WebSocketRecord {
            WebSocketRecord(url: "", close: code.map { WebSocketRecord.Close(code: $0, byServer: true) }, end: end)
        }

        XCTAssertFalse(record(.closed, 1000).isFailure)
        XCTAssertFalse(record(.closed, 1001).isFailure)
        XCTAssertFalse(WebSocketRecord(url: "", close: WebSocketRecord.Close(code: nil, byServer: true), end: .closed).isFailure, "1005")
        XCTAssertFalse(record(.limit, 1000).isFailure)
        XCTAssertFalse(record(.stopped, 1000).isFailure)
        XCTAssertTrue(record(.closed, 4001).isFailure)
        XCTAssertTrue(record(.closed, 1011).isFailure)
        XCTAssertTrue(record(.refused(message: "401"), nil).isFailure)
        XCTAssertTrue(record(.failed(message: "dropped"), nil).isFailure)
        XCTAssertFalse(record(nil, nil).isFailure, "An open connection hasn't failed")
        XCTAssertEqual(exchange(record(.closed, 4001)).outcomeKind, .failed)
    }

    func testTheSummaryShowsARefusalsStatusOrTheCloseCode() {
        var refused = WebSocketRecord(url: "", end: .refused(message: "no"))
        refused.handshake = HTTPResponseRecord(statusCode: 401, headers: [], body: Data(), url: "", startedAt: Date(), duration: 0.2)
        let closed = WebSocketRecord(
            url: "",
            entries: [message(0, .received, "hey")],
            close: WebSocketRecord.Close(code: 1000, byServer: false),
            end: .closed,
            duration: 3
        )
        let dropped = WebSocketRecord(url: "", end: .failed(message: "lost"))

        XCTAssertEqual(RunSummary(exchange(refused)).status, .webSocket(.refused(statusCode: 401)))
        XCTAssertEqual(RunSummary(exchange(closed)).status, .webSocket(.closed(code: 1000)))
        XCTAssertEqual(RunSummary(exchange(closed)).responseByteCount, 3)
        XCTAssertEqual(RunSummary(exchange(closed)).duration, 3)
        XCTAssertEqual(RunSummary(exchange(dropped)).status, .webSocket(.unclosed))
        XCTAssertEqual(RunSummary(exchange(dropped)).specKind, .webSocket)
    }

    func testRunsCompareTheirMessagesHandshakeAndRequest() throws {
        func run(_ reply: String, close: Int) -> RequestExchange {
            var record = WebSocketRecord(
                url: "wss://example.com",
                entries: [message(0, .sent, #"{"op":"hi"}"#), message(1, .received, reply)],
                close: WebSocketRecord.Close(code: close, reason: "bye", byServer: true),
                end: .closed
            )
            let upgrade = [KeyValuePair(key: "Upgrade", value: "websocket")]
            record.handshake = HTTPResponseRecord(statusCode: 101, headers: upgrade, body: Data(), url: "", startedAt: Date(), duration: 0)
            return exchange(record)
        }

        let comparison = try RunComparer.compare(run(#"{"n":1}"#, close: 1000), run(#"{"n":2}"#, close: 1001))

        XCTAssertEqual(comparison.sections.map(\.title), ["Messages", "Handshake", "Request"])
        XCTAssertEqual(comparison.sections.map(\.hasChanges), [true, true, false])
        guard case .diff(let messages) = comparison.sections[0].content else {
            return XCTFail("Messages diff as text")
        }
        let text = String(data: messages.text.bytes, encoding: .utf8) ?? ""
        XCTAssertTrue(text.contains("← Received #2"), text)
        XCTAssertTrue(text.contains("\"n\": 2"), "JSON re-indents: \(text)")
    }

    func testAFailedRunComparesUnderItsSpecsKind() throws {
        let failed = RequestExchange(
            projectID: ProjectID(),
            requestID: RequestNodeID(),
            startedAt: Date(),
            environmentName: nil,
            spec: .webSocket(WebSocketRequestSpec()),
            request: nil,
            outcome: .failure(RunFailure(kind: .transport, message: "Connection refused"))
        )

        let comparison = try RunComparer.compare(failed, failed)

        XCTAssertEqual(comparison.sections.map(\.title), ["Messages", "Handshake", "Request"])
    }

    func testTimelineItemsShowTextAsJSONAndBinaryAsBase64() {
        let json = TimelineItem(message(0, .received, #"{"a":1}"#))
        let plain = TimelineItem(message(1, .sent, "hello"))
        let binary = TimelineItem(WebSocketEntry(
            sequence: 2,
            offset: 2,
            kind: .message(WebSocketMessageRecord(direction: .received, format: .binary, text: "e30=")),
            byteCount: 2
        ))
        let ping = TimelineItem(WebSocketEntry(sequence: 3, offset: 3, kind: .control(direction: .sent, text: "Ping 1")))

        XCTAssertTrue(json.isJSON)
        XCTAssertFalse(plain.isJSON)
        XCTAssertFalse(binary.isJSON, "base64 of JSON is still base64")
        XCTAssertEqual(binary.header, .webSocket(direction: .received, format: .binary, isBase64: true))
        XCTAssertEqual(ping.header, .control(direction: .sent))
        XCTAssertEqual(ping.text, "Ping 1")
        XCTAssertFalse(ping.isJSON)
    }

    @MainActor
    func testBase64TakesEitherAlphabetWithOrWithoutPaddingOrWhitespace() {
        XCTAssertEqual(WebSocketLive.base64("aGk="), Data("hi".utf8))
        XCTAssertEqual(WebSocketLive.base64("aGk"), Data("hi".utf8))
        XCTAssertEqual(WebSocketLive.base64("aG\nk="), Data("hi".utf8))
        XCTAssertEqual(WebSocketLive.base64("-_8"), Data([0xFB, 0xFF]))
        XCTAssertEqual(WebSocketLive.base64(""), Data())
        XCTAssertNil(WebSocketLive.base64("a"))
        XCTAssertNil(WebSocketLive.base64("not base64!"))
    }
}
