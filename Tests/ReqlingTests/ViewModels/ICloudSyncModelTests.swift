import Foundation
@testable import ReqlingKit
import XCTest

@testable import Reqling

/// Settings ▸ iCloud's controls and the app's lifecycle reaching sync: on and off, syncing soon after edits, following
/// sync when it turns itself off, and the choices handed back to it.
@MainActor
final class ICloudSyncModelTests: XCTestCase {
    private var fixture: AppFixture!
    private var transport: StubSyncTransport!
    private var gate: SleepGate!

    override func setUp() async throws {
        transport = StubSyncTransport()
        let gate = SleepGate()
        self.gate = gate
        fixture = AppFixture.syncing(over: transport, now: { Date(timeIntervalSince1970: 1_000_000) }, sleep: { _ in
            await gate.sleep()
            try Task.checkCancellation()
        })
    }

    override func tearDown() async throws {
        fixture.tearDown()
    }

    private var model: ICloudSyncModel {
        fixture.model.iCloud
    }

    func testTurningSyncOffStopsItAndOnStartsIt() async throws {
        model.start()
        await waitUntil("sync to finish its first sync") { isUpToDate }
        XCTAssertTrue(model.showsFirstSyncNotice, "Its first sync on this Mac says what syncs")

        model.setOn(false)
        XCTAssertFalse(fixture.component.settingsStore.settings.syncsWithICloud)
        XCTAssertEqual(model.status, .off)

        model.setOn(true)
        XCTAssertTrue(fixture.component.settingsStore.settings.syncsWithICloud)
        await waitUntil("sync to start again") { isUpToDate }
    }

    /// Turned on and straight off again, sync stays off.
    func testTurningSyncOnAndStraightOffLeavesItOff() async {
        fixture.component.settingsStore.update { $0.syncsWithICloud = false }

        model.setOn(true)
        model.setOn(false)
        for _ in 0..<50 {
            await Task.yield()
        }

        XCTAssertEqual(model.status, .off)
        XCTAssertEqual(transport.fetches, 0)
    }

    /// A burst of edits syncs once, after it pauses, fetching first so a deletion can go out too.
    func testEditsSyncOnceTheyPause() async throws {
        model.start()
        await waitUntil("the first sync") { isUpToDate }
        let fetches = transport.fetches
        let project = try fixture.component.projectLibrary.createProject(named: "API")

        try fixture.library.mutate(project) { $0.name = "Renamed" }
        try fixture.library.mutate(project) { $0.name = "Renamed again" }
        await waitUntil("both edits to wait") { gate.pendingCount == 3 }
        gate.releaseAll()
        await waitUntil("the sync") { transport.fetches == fetches + 1 }
        for _ in 0..<50 {
            await Task.yield()
        }

        XCTAssertEqual(transport.fetches, fetches + 1, "Only the last edit's pause syncs")
    }

    /// Sync turning itself off, as after its iCloud data was deleted, turns the setting off but keeps saying why.
    func testSyncStoppingItselfTurnsTheSettingOffAndSaysWhy() async throws {
        model.start()
        await waitUntil("the first sync") { isUpToDate }

        model.sync?.stopAfterServerReset(.dataDeleted)

        XCTAssertFalse(model.isOn)
        XCTAssertEqual(model.status, .stopped(.dataDeleted))
    }

    /// The account choice says what merging takes along and what staying out means.
    func testTheAccountChoiceSaysWhatMergingTakesAlong() {
        XCTAssertEqual(ICloudAccountChoice.explanation, "This Mac's projects last synced with another iCloud account. The ones "
            + "you choose merge into this one, with their secret values, and Global and current values go along unless you "
            + "choose none. The rest stay on this Mac, out of sync.")
    }

    /// A project that synced with the last account starts unticked, since it may be that account's data.
    func testTheAccountChoiceTicksOnlyThisMacsOwnProjects() {
        let own = AccountChangeCandidate(id: ProjectID(), name: "Mine", syncedWithPreviousAccount: false)
        let theirs = AccountChangeCandidate(id: ProjectID(), name: "Work", syncedWithPreviousAccount: true)

        XCTAssertTrue(model.isMerging(own))
        XCTAssertFalse(model.isMerging(theirs))
        model.setMerging(theirs, true)
        model.setMerging(own, false)
        XCTAssertTrue(model.isMerging(theirs))
        XCTAssertFalse(model.isMerging(own))
    }

    /// The profile's expiry is warned of within 30 days, never before.
    func testTheProfileExpiryIsWarnedOfAMonthAhead() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let day: TimeInterval = 24 * 60 * 60
        func warning(_ expiry: Date?) -> Date? {
            ICloudSyncModel(
                sync: nil,
                library: fixture.library,
                settings: fixture.component.settingsStore,
                system: fixture.system,
                profileExpiry: expiry,
                now: { now }
            ).profileExpiryWarning
        }

        XCTAssertEqual(warning(now.addingTimeInterval(10 * day)), now.addingTimeInterval(10 * day))
        XCTAssertNil(warning(now.addingTimeInterval(60 * day)))
        XCTAssertNil(warning(nil))
    }

    /// Deleting what syncs says it goes to the Trash on the other Macs too; once sync is off, only here.
    func testTrashingWhatSyncsSaysItReachesTheOtherMacs() async throws {
        model.start()
        await waitUntil("the first sync") { isUpToDate }
        fixture.model.createProject(named: "API")
        let project = try XCTUnwrap(fixture.model.selection?.projectID)

        fixture.model.requestTrash(.project(project))
        let synced = try XCTUnwrap(fixture.model.trashPending)
        model.setOn(false)
        fixture.model.requestTrash(.project(project))
        let local = try XCTUnwrap(fixture.model.trashPending)

        XCTAssertTrue(synced.consequences.hasPrefix("Its folder goes to the Trash on this Mac and your other Macs that sync it, "))
        XCTAssertTrue(local.consequences.hasPrefix("Its folder goes to the Trash, "))
    }

    func testOpenICloudSettingsOpensTheAppleAccountPane() {
        model.openICloudSettings()

        XCTAssertEqual(fixture.system.opened.map(\.absoluteString), [
            "x-apple.systempreferences:com.apple.systempreferences.AppleIDSettings?iCloud"
        ])
    }

    private var isUpToDate: Bool {
        if case .upToDate = model.status {
            return true
        }
        return false
    }
}
