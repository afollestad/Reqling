import Foundation
@testable import ReqlingKit
import XCTest

final class RunHistoryStoreTests: XCTestCase {
    private var directory: TemporaryDirectory!
    private var store: RunHistoryStore!

    override func setUpWithError() throws {
        directory = try TemporaryDirectory()
        store = RunHistoryStore(directory: directory.url)
    }

    override func tearDown() {
        directory.remove()
        directory = nil
    }

    func testRunsListNewestFirstAndLoadBack() {
        let key = RunKey(RequestNodeID(), in: ProjectID())
        let first = HistoryFixtures.exchange(key, statusCode: 500, at: 1)
        let second = HistoryFixtures.exchange(key, statusCode: 200, at: 2)

        store.save(first)
        store.save(second)

        XCTAssertEqual(store.entries(for: key.requestID, in: key.projectID).map(\.summary.id), [second.id, first.id])
        XCTAssertEqual(store.load(first.id, for: key.requestID, in: key.projectID), first)
        XCTAssertEqual(store.latest(for: key.requestID, in: key.projectID), second)
        XCTAssertEqual(store.outcomes(in: key.projectID), [key.requestID: .succeeded])
    }

    func testABodyOverTheLimitIsCutButItsSummaryKeepsTheFullSize() throws {
        let key = RunKey(RequestNodeID(), in: ProjectID())
        let body = Data(repeating: 0x61, count: RunHistoryStore.bodyLimit + 10)
        let exchange = HistoryFixtures.exchange(key, statusCode: 200, at: 1, body: body)

        let entry = try XCTUnwrap(store.insert(exchange))
        let stored = try XCTUnwrap(store.load(exchange.id, for: key.requestID, in: key.projectID))

        XCTAssertTrue(stored.isBodyTruncated)
        XCTAssertEqual(stored.response?.body.count, RunHistoryStore.bodyLimit)
        XCTAssertEqual(entry.summary.responseByteCount, RunHistoryStore.bodyLimit + 10)
    }

    /// Each event's data is cut, then the oldest events dropped, keeping the newest; the summary keeps every byte.
    func testAStreamIsCutToFitButItsSummaryKeepsEveryByte() throws {
        let key = RunKey(RequestNodeID(), in: ProjectID())
        let data = String(repeating: "é", count: RunHistoryStore.messageLimit)
        let entries = (0..<100).map { EventStreamEntry(sequence: $0, offset: Double($0), kind: .event(ServerSentEvent(data: data))) }
        var exchange = HistoryFixtures.exchange(key, statusCode: 200, at: 1, body: Data())
        if case .response(var response) = exchange.outcome {
            response.eventStream = EventStreamRecord(entries: entries, receivedByteCount: 13_000_000, end: .closed)
            exchange.outcome = .response(response)
        }

        let entry = try XCTUnwrap(store.insert(exchange))
        let stored = try XCTUnwrap(store.load(exchange.id, for: key.requestID, in: key.projectID))

        let stream = try XCTUnwrap(stored.response?.eventStream)
        XCTAssertTrue(stored.isBodyTruncated)
        XCTAssertTrue(stream.events.allSatisfy { $0.data.utf8.count <= RunHistoryStore.messageLimit })
        XCTAssertLessThanOrEqual(stream.events.reduce(0) { $0 + $1.data.utf8.count }, RunHistoryStore.bodyLimit)
        XCTAssertEqual(stream.entries.last?.sequence, 99, "The newest events are kept")
        XCTAssertEqual(stream.trimmedEntryCount, 100 - stream.entries.count)
        XCTAssertEqual(stream.entries.first?.byteCount, data.utf8.count, "Each event keeps its size as received")
        XCTAssertEqual(entry.summary.responseByteCount, 13_000_000)
    }

    /// The outcome index follows each request's newest run as runs go, and forgets the request with its last one.
    func testOutcomesFollowEachRequestsNewestRun() {
        let key = RunKey(RequestNodeID(), in: ProjectID())
        let failed = HistoryFixtures.exchange(key, statusCode: 500, at: 1)
        let succeeded = HistoryFixtures.exchange(key, statusCode: 200, at: 2)
        store.save(failed)
        store.save(succeeded)

        store.remove([succeeded.id], for: key.requestID, in: key.projectID)
        XCTAssertEqual(store.outcomes(in: key.projectID), [key.requestID: .failed])
        XCTAssertNil(store.load(succeeded.id, for: key.requestID, in: key.projectID))

        store.remove([failed.id], for: key.requestID, in: key.projectID)
        XCTAssertEqual(store.outcomes(in: key.projectID), [:])
        XCTAssertTrue(store.allEntries().isEmpty)
    }

    func testMovingCarriesRunsAndTheirOutcomeIntoTheOtherProject() throws {
        let source = RunKey(RequestNodeID(), in: ProjectID())
        let destination = ProjectID()
        let exchange = HistoryFixtures.exchange(source, statusCode: 404, at: 1)
        store.save(exchange)

        store.move([source.requestID], from: source.projectID, to: destination)

        XCTAssertEqual(store.outcomes(in: source.projectID), [:])
        XCTAssertEqual(store.outcomes(in: destination), [source.requestID: .failed])
        let moved = try XCTUnwrap(store.load(exchange.id, for: source.requestID, in: destination))
        XCTAssertEqual(moved.projectID, destination, "a run reads as belonging where it is stored")
        XCTAssertEqual(Array(store.allEntries().keys), [RunKey(source.requestID, in: destination)])
    }

    func testRemovingARequestAProjectAndEverything() {
        let project = ProjectID()
        let kept = RunKey(RequestNodeID(), in: project)
        let cleared = RunKey(RequestNodeID(), in: project)
        let other = RunKey(RequestNodeID(), in: ProjectID())
        for key in [kept, cleared, other] {
            store.save(HistoryFixtures.exchange(key, statusCode: 200, at: 1))
        }

        store.removeAll(for: cleared.requestID, in: project)
        XCTAssertEqual(Set(store.allEntries().keys), [kept, other])
        XCTAssertEqual(store.outcomes(in: project), [kept.requestID: .succeeded])

        store.removeAll(in: project)
        XCTAssertEqual(Set(store.allEntries().keys), [other])

        store.removeEverything()
        XCTAssertTrue(store.allEntries().isEmpty)
    }
}
