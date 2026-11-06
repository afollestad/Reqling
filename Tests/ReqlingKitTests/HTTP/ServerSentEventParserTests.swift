import Foundation
import ReqlingKit
import XCTest

/// The WHATWG event-stream rules, fed in arbitrary chunks as the network delivers them.
final class ServerSentEventParserTests: XCTestCase {
    func testDataLinesJoinAndEventsDefaultToMessage() {
        XCTAssertEqual(Self.parse("data: a\ndata:b\n\n"), [.event(ServerSentEvent(data: "a\nb"))])
        XCTAssertEqual(Self.parse("data\n\n"), [.event(ServerSentEvent(data: ""))], "A field without a colon has an empty value")
        XCTAssertEqual(Self.parse("data:  two spaces\n\n"), [.event(ServerSentEvent(data: " two spaces"))], "Only one space is stripped")
        XCTAssertEqual(Self.parse("event: tick\ndata: a\n\n"), [.event(ServerSentEvent(type: "tick", data: "a"))])
    }

    func testCommentsUnknownFieldsAndDatalessEventsAreIgnored() {
        XCTAssertEqual(Self.parse(": keep-alive\nunknown: x\nDATA: y\n\n"), [])
        // A type with no data fires nothing, and doesn't carry over to the next event.
        XCTAssertEqual(Self.parse("event: lone\n\ndata: next\n\n"), [.event(ServerSentEvent(data: "next"))])
    }

    func testEveryLineEndingEndsALine() {
        XCTAssertEqual(
            Self.parse("data: a\r\n\r\ndata: b\r\rdata: c\n\n"),
            ["a", "b", "c"].map { .event(ServerSentEvent(data: $0)) }
        )
    }

    /// A CRLF split across chunks is one line ending: its LF must not read as a blank line that fires the event early.
    func testACarriageReturnEndingAChunkPairsWithTheNextChunksLineFeed() {
        XCTAssertEqual(Self.parse(["data: a\r", "\ndata: b\r\n\r\n"]), [.event(ServerSentEvent(data: "a\nb"))])
    }

    func testOnlyALeadingByteOrderMarkIsStripped() {
        XCTAssertEqual(Self.parse("\u{FEFF}data: a\n\n"), [.event(ServerSentEvent(data: "a"))])
        XCTAssertEqual(Self.parse([[0xEF], [0xBB, 0xBF]] + [Array("data: a\n\n".utf8)]), [.event(ServerSentEvent(data: "a"))])
        XCTAssertEqual(Self.parse("data: a\n\u{FEFF}data: b\n\n"), [.event(ServerSentEvent(data: "a"))], "Later, it is part of a field name")
    }

    func testTheLastEventIDPersistsAndUpdatesEvenWithoutAnEvent() {
        XCTAssertEqual(Self.parse("id: 1\ndata: a\n\ndata: b\n\n"), [
            .lastEventID("1"),
            .event(ServerSentEvent(id: "1", data: "a")),
            .event(ServerSentEvent(id: "1", data: "b"))
        ])
        XCTAssertEqual(Self.parse("id: 5\n\n"), [.lastEventID("5")])
        XCTAssertEqual(Self.parse("id: 5\n\nid\ndata: a\n\n"), [.lastEventID("5"), .lastEventID(""), .event(ServerSentEvent(data: "a"))])
        XCTAssertEqual(Self.parse("id: 5\n\nid: a\u{0}b\ndata: c\n\n"), [.lastEventID("5"), .event(ServerSentEvent(id: "5", data: "c"))])
    }

    func testRetryTakesDigitsOnlyAndAppliesAtOnce() {
        XCTAssertEqual(Self.parse("retry: 3000\n"), [.retry(3_000)])
        XCTAssertEqual(Self.parse("retry: 3s\nretry:\nretry: -1\n\n"), [])
    }

    func testAnEventNoBlankLineEndsNeverFires() {
        XCTAssertEqual(Self.parse("data: tail\n"), [])
        XCTAssertEqual(Self.parse("data: tail"), [])
    }

    func testInvalidUTF8IsReplaced() {
        XCTAssertEqual(Self.parse([Array("data: ".utf8) + [0xFF] + Array("\n\n".utf8)]), [.event(ServerSentEvent(data: "\u{FFFD}"))])
    }

    /// However the bytes are split, even through a multi-byte character, the fields come out the same.
    func testSplittingTheInputAnywhereChangesNothing() {
        let stream = Array("\u{FEFF}: hi\r\nid: 9\r\nevent: é\rdata: ünï\r\n\r\nretry: 10\ndata: x\n\n".utf8)
        let whole = Self.parse([stream])
        XCTAssertEqual(whole.count, 4)

        for split in 1..<stream.count {
            XCTAssertEqual(Self.parse([Array(stream[..<split]), Array(stream[split...])]), whole, "Split at \(split)")
        }
        XCTAssertEqual(Self.parse(stream.map { [$0] }), whole, "Byte by byte")
    }

    private static func parse(_ text: String) -> [ServerSentEventField] {
        parse([Array(text.utf8)])
    }

    private static func parse(_ chunks: [String]) -> [ServerSentEventField] {
        parse(chunks.map { Array($0.utf8) })
    }

    private static func parse(_ chunks: [[UInt8]]) -> [ServerSentEventField] {
        var parser = ServerSentEventParser()
        return chunks.flatMap { parser.parse($0) }
    }
}
