import Foundation
import ReqlingKit
import XCTest

@testable import Reqling

@MainActor
final class GRPCResponseViewModelTests: XCTestCase {
    private var fixture: AppFixture!
    private var project: ProjectID!
    private var request: RequestNodeID!
    private var response: GRPCResponseViewModel!

    override func setUp() async throws {
        fixture = AppFixture()
        project = try fixture.library.createProject(named: "Streams")
        request = try GRPCFixtures.addRequest(named: "Chat", spec: GRPCFixtures.descriptorSetSpec(method: "Chat"), to: project, in: fixture)
        response = GRPCResponseViewModel(requestID: request, projectID: project, runner: fixture.component.requestRunner)
    }

    override func tearDown() async throws {
        response = nil
        fixture.tearDown()
        fixture = nil
    }

    /// Makes `record` the request's latest exchange of one run, as each update of a live call does. The runner's
    /// `latest` is Kit's to write, so this goes through the run history: `forget` drops the previous update, and
    /// reading the exchange back loads this one.
    private func publish(_ record: GRPCCallRecord) {
        let runner = fixture.component.requestRunner
        runner.forget(project)
        RunHistoryStore(directory: fixture.profile.historyDirectory).save(RequestExchange(
            projectID: project,
            requestID: request,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            environmentName: nil,
            request: nil,
            outcome: .grpc(record)
        ))
        _ = runner.exchange(for: request, in: project)
    }

    /// A bidirectional call's record holding the messages numbered `sequences`, less `dropped`, as Kit keeps them.
    private func record(_ sequences: Range<Int>, dropped: Set<Int> = []) -> GRPCCallRecord {
        let events = sequences.filter { !dropped.contains($0) }.map { sequence in
            GRPCMessageEvent(
                direction: sequence.isMultiple(of: 2) ? .sent : .received,
                offset: Double(sequence) / 1000,
                json: #"{"index": \#(sequence)}"#,
                byteCount: 2,
                sequence: sequence
            )
        }
        return GRPCCallRecord(
            target: "localhost:50051",
            method: "\(GRPCFixtures.service)/Chat",
            kind: .bidirectionalStreaming,
            events: events,
            sentCount: (sequences.upperBound + 1) / 2,
            receivedCount: sequences.upperBound / 2,
            trimmedEventCount: sequences.lowerBound,
            droppedEventCount: dropped.count
        )
    }

    /// Once a stream fills the record, each update slides its window forward at the same count; the timeline must
    /// follow by sequence rather than freeze on the first messages it saw.
    func testTheTimelineFollowsAStreamPastTheRecordsLimit() {
        let limit = GRPCCallRecord.eventLimit

        publish(record(0..<limit))
        XCTAssertEqual(response.timeline.map(\.id), Array(0..<limit))

        publish(record(1..<limit + 1))
        XCTAssertEqual(response.timeline.map(\.id), Array(1..<limit + 1))
        XCTAssertEqual(response.timeline.last?.event.json, #"{"index": \#(limit)}"#)

        publish(record(700..<limit + 700))
        let timeline = response.timeline
        XCTAssertEqual(timeline.count, limit)
        XCTAssertEqual(timeline.first?.id, 700)
        XCTAssertEqual(timeline.last?.event.json, #"{"index": \#(limit + 699)}"#)
        XCTAssertFalse(timeline.last?.tokens.isEmpty ?? true, "a new message is highlighted")
    }

    func testMessagesDroppedMidStreamLeaveGapsWithoutShiftingTheRest() {
        publish(record(0..<6))
        XCTAssertEqual(response.timeline.map(\.id), Array(0..<6))

        publish(record(0..<10, dropped: [6, 7]))

        XCTAssertEqual(response.timeline.map(\.id), [0, 1, 2, 3, 4, 5, 8, 9])
        XCTAssertEqual(response.timeline.map(\.event.json).last, #"{"index": 9}"#)
    }

    /// The messages tree keeps one identity per call as it streams, so the tree updates in place, and indexes each
    /// message once.
    func testTheMessageTreeKeepsItsIdentityAsTheCallStreams() throws {
        publish(record(0..<3))
        guard case .messages(let first) = try XCTUnwrap(response.messageTree) else {
            return XCTFail("not a timeline")
        }
        publish(record(0..<5))
        guard case .messages(let second) = try XCTUnwrap(response.messageTree) else {
            return XCTFail("not a timeline")
        }
        XCTAssertEqual(first.id, second.id)
        XCTAssertEqual(second.messages.map(\.event.sequence), [0, 1, 2, 3, 4])
        XCTAssertEqual(second.messages[0].index?.id, first.messages[0].index?.id, "indexed once")
        XCTAssertEqual(second.messages[4].fields.map(\.key), ["index"])
    }
}
