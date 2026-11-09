import Foundation
@testable import ReqlingKit
import XCTest

/// A fetch assembled from the engine's events: zones delivered only once complete, and whole only when nothing fell
/// short, since a whole fetch reads every zone it leaves out as deleted.
final class CloudKitFetchAssemblyTests: XCTestCase {
    private let first = SyncZone.project(ProjectID())
    private let second = SyncZone.project(ProjectID())

    func testAWholeFetchThatDeliversEveryZoneIsWhole() throws {
        var fetch = CloudKitFetchAssembly(isWhole: true)
        fetch.name(first)
        fetch.name(second)
        fetch.state = Data("state".utf8)

        fetch.changed(record(in: first, "a"))
        XCTAssertNil(fetch.finish(first, failed: false), "Held for the end")
        fetch.begin(second)
        XCTAssertNil(fetch.finish(second, failed: false))
        let outcome = fetch.finish()

        XCTAssertEqual(outcome.zones.map(\.zone), [first, second])
        XCTAssertEqual(outcome.zones.first?.changed.map(\.id.name), ["a"])
        XCTAssertTrue(outcome.zones.allSatisfy(\.isWhole))
        XCTAssertEqual(outcome.zones.last?.changed, [], "A zone with nothing in it still arrives, so it isn't read as deleted")
        XCTAssertEqual(outcome.state, Data("state".utf8))
        XCTAssertTrue(outcome.wasWhole)
        XCTAssertFalse(outcome.lostChanges)
    }

    /// A zone named but not delivered would read as deleted: the fetch isn't whole, delivers nothing, and is redone.
    func testAWholeFetchMissingAZoneIsntWhole() {
        var fetch = CloudKitFetchAssembly(isWhole: true)
        fetch.name(first)
        fetch.name(second)
        fetch.begin(first)
        _ = fetch.finish(first, failed: false)

        XCTAssertEqual(fetch.finish(), .init(zones: [], state: nil, wasWhole: false, lostChanges: true))
    }

    /// A failed zone drops what it fetched, which the engine's tokens may be past, so everything is fetched again.
    func testAFailedZoneDropsItsChangesAndLosesThem() {
        var fetch = CloudKitFetchAssembly(isWhole: false)
        fetch.changed(record(in: first, "a"))

        XCTAssertNil(fetch.finish(first, failed: true))
        XCTAssertEqual(fetch.finish(), .init(zones: [], state: nil, wasWhole: false, lostChanges: true))
    }

    /// A zone whose fetch never completed never arrives half done.
    func testAZoneThatNeverCompletedIsLost() {
        var fetch = CloudKitFetchAssembly(isWhole: false)
        fetch.changed(record(in: first, "a"))

        XCTAssertTrue(fetch.finish().lostChanges)
    }

    /// An incremental fetch can leave a zone it named for later; the engine fetches it then.
    func testAnIncrementalFetchMayLeaveZonesForLater() {
        var fetch = CloudKitFetchAssembly(isWhole: false)
        fetch.name(first)

        XCTAssertEqual(fetch.finish(), .init(zones: [], state: nil, wasWhole: false, lostChanges: false))
    }

    /// A zone arrives only as begun in this fetch, and a whole one only once: a stray or second delivery would be
    /// incomplete, and in a whole fetch what it lacks would read as deleted, so the whole fetch delivers nothing.
    func testAZoneArrivesOnlyAsBegunAndAWholeOneOnlyOnce() throws {
        var stray = CloudKitFetchAssembly(isWhole: false)
        var twice = CloudKitFetchAssembly(isWhole: true)
        twice.name(first)
        twice.changed(record(in: first, "a"))
        _ = twice.finish(first, failed: false)

        XCTAssertNil(stray.finish(first, failed: false))
        twice.changed(record(in: first, "b"))
        XCTAssertNil(twice.finish(first, failed: false))
        XCTAssertTrue(stray.finish().lostChanges)
        XCTAssertEqual(twice.finish(), .init(zones: [], state: nil, wasWhole: false, lostChanges: true))
    }

    /// Ending a fetch early drops nothing until a zone begins, or a whole one names the account's zones; one that
    /// ended before either fetches the same next time.
    func testAnAbandonedFetchDropsChangesOnlyOnceSomeArrived() {
        var incremental = CloudKitFetchAssembly(isWhole: false)
        var whole = CloudKitFetchAssembly(isWhole: true)
        XCTAssertFalse(incremental.dropsChangesIfAbandoned)
        XCTAssertFalse(whole.dropsChangesIfAbandoned)

        incremental.begin(first)
        whole.name(first)

        XCTAssertTrue(incremental.dropsChangesIfAbandoned)
        XCTAssertTrue(whole.dropsChangesIfAbandoned)
    }

    /// A fresh engine's own fetch runs alongside the one sync asks for: they end together, whichever ends last, as
    /// sync's. The engine's own fetch alone never is, though sync's call be out as it ends.
    func testJoinedFetchesEndTogetherAndAreSyncsOnlyWithOneItAskedFor() {
        var joined = CloudKitFetchAssembly(isWhole: true)
        var own = CloudKitFetchAssembly(isWhole: true)
        joined.join()
        joined.join()
        own.join()

        XCTAssertFalse(joined.leave(asked: true), "The engine's own is still open")
        XCTAssertTrue(joined.leave(asked: false))
        XCTAssertTrue(own.leave(asked: false))

        XCTAssertTrue(joined.isAsked)
        XCTAssertFalse(own.isAsked)
    }

    /// The last word on a record wins: one deleted after changing arrives deleted, and the reverse.
    func testTheLatestWordOnARecordWins() throws {
        var fetch = CloudKitFetchAssembly(isWhole: false)
        fetch.changed(record(in: first, "a"))
        fetch.deleted(SyncRecordID(zone: first, name: "a"))
        fetch.deleted(SyncRecordID(zone: first, name: "b"))
        fetch.changed(record(in: first, "b"))
        fetch.changed(record(in: first, "b"))

        let zone = try XCTUnwrap(fetch.finish(first, failed: false))

        XCTAssertEqual(zone.changed.map(\.id.name), ["b"])
        XCTAssertEqual(zone.deleted.map(\.name), ["a"])
    }

    private func record(in zone: SyncZone, _ name: String) -> SyncRecord {
        SyncRecord(id: SyncRecordID(zone: zone, name: name), type: .request, payload: .object([]))
    }
}
