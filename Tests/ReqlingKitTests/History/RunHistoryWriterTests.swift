import Foundation
@testable import ReqlingKit
import XCTest

final class RunHistoryWriterTests: XCTestCase {
    private var directory: TemporaryDirectory!
    private let roomy = RunHistoryPolicy(retention: nil, sizeLimit: .max)
    private let day: TimeInterval = 24 * 60 * 60

    override func setUpWithError() throws {
        directory = try TemporaryDirectory()
    }

    override func tearDown() {
        directory.remove()
        directory = nil
    }

    func testReadsWaitForSavesQueuedBeforeThem() {
        let writer = RunHistoryWriter(store: RunHistoryStore(directory: directory.url))
        let key = RunKey(RequestNodeID(), in: ProjectID())
        let exchange = HistoryFixtures.exchange(key, statusCode: 200, at: 1)

        writer.save(exchange, policy: roomy, now: Date(timeIntervalSince1970: 1)) { _ in }

        XCTAssertEqual(writer.summaries(for: key.requestID, in: key.projectID).map(\.id), [exchange.id])
        XCTAssertEqual(writer.latest(for: key.requestID, in: key.projectID), exchange)
        XCTAssertEqual(writer.outcomes(in: key.projectID), [key.requestID: .succeeded])
    }

    /// A removal is on disk when it returns, after any save queued before it, so nothing queued can bring a cleared run
    /// back.
    func testRemovalsLandBeforeTheyReturn() {
        let store = RunHistoryStore(directory: directory.url)
        let writer = RunHistoryWriter(store: store)
        let key = RunKey(RequestNodeID(), in: ProjectID())

        writer.save(HistoryFixtures.exchange(key, statusCode: 200, at: 1), policy: roomy, now: .distantPast) { _ in }
        writer.removeAll(in: key.projectID)
        XCTAssertTrue(store.allEntries().isEmpty, "no flush needed")

        writer.save(HistoryFixtures.exchange(key, statusCode: 200, at: 2), policy: roomy, now: .distantPast) { _ in }
        writer.removeAll(for: key.requestID, in: key.projectID)
        XCTAssertTrue(store.allEntries().isEmpty)

        writer.save(HistoryFixtures.exchange(key, statusCode: 200, at: 3), policy: roomy, now: .distantPast) { _ in }
        writer.removeEverything()
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.url.path))
    }

    /// Retention takes old runs but never a request's newest, so a response from long ago still shows.
    func testRetentionKeepsEachRequestsNewestRun() {
        let busy = RunKey(RequestNodeID(), in: ProjectID())
        let idle = RunKey(RequestNodeID(), in: ProjectID())
        let now = Date(timeIntervalSince1970: 100 * day)
        let catalog = [
            busy: [entry(busy, at: now.addingTimeInterval(-2 * day)), entry(busy, at: now.addingTimeInterval(-3 * day))],
            idle: [entry(idle, at: now.addingTimeInterval(-30 * day))]
        ]

        let doomed = RunHistoryWriter.doomed(in: catalog, policy: RunHistoryPolicy(retention: day, sizeLimit: .max), now: now)

        XCTAssertEqual(doomed, [busy: [catalog[busy]![1].summary.id]])
    }

    /// The size limit takes the oldest runs anywhere first, and a request's newest only once nothing older is left.
    func testTheSizeLimitTakesOlderRunsBeforeAnyRequestsNewest() {
        let first = RunKey(RequestNodeID(), in: ProjectID())
        let second = RunKey(RequestNodeID(), in: ProjectID())
        let catalog = [
            first: [entry(first, at: Date(timeIntervalSince1970: 5)), entry(first, at: Date(timeIntervalSince1970: 1))],
            second: [entry(second, at: Date(timeIntervalSince1970: 3))]
        ]

        let doomed = RunHistoryWriter.doomed(in: catalog, policy: RunHistoryPolicy(retention: nil, sizeLimit: 15), now: .distantFuture)

        XCTAssertEqual(doomed, [first: [catalog[first]![1].summary.id], second: [catalog[second]![0].summary.id]])
        XCTAssertEqual(RunHistoryWriter.doomed(in: catalog, policy: RunHistoryPolicy(retention: nil, sizeLimit: 30), now: .distantFuture), [:])
    }

    /// Pruning after a save takes what the policy no longer allows from disk, then reports it.
    func testASaveThatBreaksThePolicyPrunesAndReports() async {
        let store = RunHistoryStore(directory: directory.url)
        let writer = RunHistoryWriter(store: store)
        let key = RunKey(RequestNodeID(), in: ProjectID())
        let old = HistoryFixtures.exchange(key, statusCode: 200, at: 1)
        let new = HistoryFixtures.exchange(key, statusCode: 200, at: 10 * day)
        let reported = expectation(description: "reported")
        let policy = RunHistoryPolicy(retention: day, sizeLimit: .max)

        writer.save(old, policy: policy, now: Date(timeIntervalSince1970: 10 * day)) { _ in XCTFail("the only run is the newest") }
        writer.save(new, policy: policy, now: Date(timeIntervalSince1970: 10 * day)) { removal in
            XCTAssertEqual(removal, [key: [old.id]])
            reported.fulfill()
        }
        await fulfillment(of: [reported], timeout: 10)

        XCTAssertEqual(writer.summaries(for: key.requestID, in: key.projectID).map(\.id), [new.id])
        var sizes = writer.sizes.makeAsyncIterator()
        let size = await sizes.next()
        XCTAssertEqual(size, store.entries(for: key.requestID, in: key.projectID).first?.storedByteCount, "the newest total only")
    }

    private func entry(_ key: RunKey, at date: Date) -> RunHistoryStore.Entry {
        let exchange = HistoryFixtures.exchange(key, statusCode: 200, at: date.timeIntervalSince1970)
        return RunHistoryStore.Entry(summary: RunSummary(exchange), storedByteCount: 10)
    }
}
