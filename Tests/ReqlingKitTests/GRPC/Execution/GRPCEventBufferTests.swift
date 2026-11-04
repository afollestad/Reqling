import Foundation
@testable import ReqlingKit
import XCTest

/// The executor's event buffer: lossy for messages only, within a count and a byte budget.
final class GRPCEventBufferTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 0)

    func testMessagesStayWithinBothBudgetsAndOtherEventsAreNeverDropped() async {
        let buffer = GRPCEventBuffer(messageLimit: 3, byteLimit: 100)
        buffer.appendControl(.opened(timestamp: start))
        buffer.appendMessage(bytes: 0, isSent: true) { .sent(index: 0, sequence: $0, timestamp: .distantPast) }
        buffer.appendControl(.initialMetadata([], timestamp: start))
        for _ in 0..<5 {
            buffer.appendMessage(bytes: 40, isSent: false) { .received([], sequence: $0, timestamp: .distantPast) }
        }
        buffer.finish()

        let events = await Self.drain(buffer)

        // The byte budget keeps two 40-byte messages; the count budget alone would have kept three.
        XCTAssertEqual(events.sequences, [4, 5])
        guard events.count == 5, case .omitted(1, 3) = events[0], case .opened = events[1], case .initialMetadata = events[2] else {
            return XCTFail("The totals come first, then the kept events in order: \(events)")
        }
        XCTAssertEqual(buffer.dropped.sent, 1)
        XCTAssertEqual(buffer.dropped.received, 3)
    }

    /// An open stream that overflows reports its running totals right away, not only when it ends.
    func testDropsAreReportedWhileTheStreamIsOpen() async {
        let buffer = GRPCEventBuffer(messageLimit: 2, byteLimit: 1_000)
        func receive(_ count: Int) {
            for _ in 0..<count {
                buffer.appendMessage(bytes: 1, isSent: false) { .received([], sequence: $0, timestamp: .distantPast) }
            }
        }

        receive(5)
        let first = await buffer.next()
        let second = await buffer.next()
        receive(3)
        let third = await buffer.next()

        guard case .omitted(0, 3) = first, case .received(_, 3, _) = second, case .omitted(0, 5) = third else {
            return XCTFail("Running totals precede the next message: \(String(describing: [first, second, third]))")
        }
        buffer.finish()
        let rest = await Self.drain(buffer)
        XCTAssertEqual(rest.sequences, [6, 7], "No repeat report when nothing more was dropped")
    }

    func testOneMessageLargerThanTheBudgetStillComesThrough() async {
        let buffer = GRPCEventBuffer(messageLimit: 10, byteLimit: 100)
        buffer.appendMessage(bytes: 500, isSent: false) { .received([], sequence: $0, timestamp: .distantPast) }
        buffer.finish()

        let events = await Self.drain(buffer)

        XCTAssertEqual(events.sequences, [0])
    }

    func testSkippingTheBacklogDropsMessagesButKeepsOtherEvents() async {
        let buffer = GRPCEventBuffer(messageLimit: 10, byteLimit: 1_000)
        for _ in 0..<3 {
            buffer.appendMessage(bytes: 1, isSent: false) { .received([], sequence: $0, timestamp: .distantPast) }
        }
        buffer.skipBacklog()
        buffer.appendControl(.initialMetadata([], timestamp: start))
        buffer.appendMessage(bytes: 1, isSent: true) { .sent(index: 0, sequence: $0, timestamp: .distantPast) }
        buffer.finish()

        let events = await Self.drain(buffer)

        guard events.count == 2, case .omitted(1, 3) = events[0], case .initialMetadata = events[1] else {
            return XCTFail("Only the totals and the metadata come through: \(events)")
        }
        XCTAssertEqual(buffer.dropped.received, 3)
        XCTAssertEqual(buffer.dropped.sent, 1, "Messages after the skip are counted too")
    }

    func testAWaitingReceiverGetsEventsAsTheyArrive() async {
        let buffer = GRPCEventBuffer(messageLimit: 10, byteLimit: 1_000)
        let receiving = Task { await Self.drain(buffer) }
        buffer.appendMessage(bytes: 1, isSent: false) { .received([], sequence: $0, timestamp: .distantPast) }
        buffer.appendControl(.opened(timestamp: start))
        buffer.finish()

        let events = await bounded("drain", receiving)

        XCTAssertEqual(events?.count, 2)
    }

    private static func drain(_ buffer: GRPCEventBuffer) async -> [GRPCCallEvent] {
        var events: [GRPCCallEvent] = []
        while let event = await buffer.next() {
            events.append(event)
        }
        return events
    }
}
