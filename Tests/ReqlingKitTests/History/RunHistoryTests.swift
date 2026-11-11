import Foundation
@testable import ReqlingKit
import XCTest

@MainActor
final class RunHistoryTests: XCTestCase {
    private var directory: TemporaryDirectory!
    private var settings: SettingsStore!
    private let day: TimeInterval = 24 * 60 * 60

    override func setUp() async throws {
        directory = try TemporaryDirectory()
        settings = SettingsStore(preferences: MemoryPreferences())
    }

    override func tearDown() async throws {
        directory.remove()
    }

    /// A recorded run lists before its file is written; pruning, which runs after the write, catches up on its own.
    func testARecordedRunListsAtOnceAndPruningCatchesUp() async {
        settings.update { $0.historyRetention = .day }
        let now = Date(timeIntervalSince1970: 10 * day)
        let history = RunHistory(directory: directory.url, settings: settings, now: { now })
        let key = RunKey(RequestNodeID(), in: ProjectID())
        let old = HistoryFixtures.exchange(key, statusCode: 500, at: 1)
        let new = HistoryFixtures.exchange(key, statusCode: 200, at: 10 * day)
        XCTAssertEqual(history.runs(for: key.requestID, in: key.projectID), [])

        history.record(old)
        history.record(new)

        XCTAssertEqual(history.runs(for: key.requestID, in: key.projectID).map(\.id), [new.id, old.id])
        XCTAssertEqual(history.outcome(for: key.requestID, in: key.projectID), .succeeded)
        await waitUntil("pruned") { history.runs(for: key.requestID, in: key.projectID).count == 1 }
        XCTAssertEqual(history.runs(for: key.requestID, in: key.projectID).map(\.id), [new.id])
        await waitUntil("weighed") { (history.storedBytes ?? 0) > 0 }
        let pruned = await history.exchange(old.id, for: key.requestID, in: key.projectID)
        XCTAssertNil(pruned)
    }

    func testClearingDropsRunsAndOutcomesForGood() {
        let history = RunHistory(directory: directory.url, settings: settings)
        let project = ProjectID()
        let first = RunKey(RequestNodeID(), in: project)
        let second = RunKey(RequestNodeID(), in: project)
        let elsewhere = RunKey(RequestNodeID(), in: ProjectID())
        for key in [first, second, elsewhere] {
            history.record(HistoryFixtures.exchange(key, statusCode: 200, at: 1))
        }

        history.clear(for: first.requestID, in: project)
        XCTAssertEqual(history.runs(for: first.requestID, in: project), [])
        XCTAssertEqual(history.outcome(for: first.requestID, in: project), .notSent)
        XCTAssertEqual(history.outcome(for: second.requestID, in: project), .succeeded)

        history.clear(in: project)
        XCTAssertEqual(history.runs(for: second.requestID, in: project), [])
        XCTAssertEqual(history.outcome(for: elsewhere.requestID, in: elsewhere.projectID), .succeeded)

        history.clearAll()
        history.flush()
        let relaunched = RunHistory(directory: directory.url, settings: settings)
        XCTAssertEqual(relaunched.runs(for: elsewhere.requestID, in: elsewhere.projectID), [])
        XCTAssertEqual(relaunched.outcome(for: elsewhere.requestID, in: elsewhere.projectID), .notSent)
    }
}
