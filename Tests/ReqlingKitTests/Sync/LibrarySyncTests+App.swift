import Foundation
@testable import ReqlingKit
import XCTest

/// What sync offers the app: the copy taken before an account first syncs here, the calls that let it sync soon and
/// say what syncs, the account choice, and what a fetch that fell short asks for.
@MainActor
extension LibrarySyncTests {
    /// An account's first sync on a Mac copies what's there before anything arrives, and says so once.
    func testAnAccountsFirstSyncHereBacksUpFirstAndSaysSoOnce() async throws {
        let shared = try await shareProject()
        let macC = try SyncTestMac(cloud: cloud)
        defer { macC.cleanUp() }
        try macC.lifecycle.createProject(named: "Local")
        var firstSyncs = 0
        macC.sync.onFirstSync = { firstSyncs += 1 }

        await macC.sync.start()
        macC.sync.stop()
        await macC.sync.start()

        let backup = try XCTUnwrap(macC.sync.backupDirectory)
        let projects = try FileManager.default.contentsOfDirectory(atPath: backup.appendingPathComponent("Projects").path)
        XCTAssertEqual(firstSyncs, 1)
        XCTAssertEqual(projects, ["Local.reqling"], "Copied before the shared project arrived")
        XCTAssertNotNil(macC.library.project(shared))
    }

    /// The copy is the person's, not a cache of the server's, so deleting Reqling's iCloud data keeps it.
    func testTheBackupOutlivesDeletingTheAccountsData() async throws {
        try await shareProject()
        let backup = try XCTUnwrap(macB.sync.backupDirectory)

        cloud.wipe(reason: .purged)
        await macB.sync.syncNow()

        XCTAssertEqual(macB.sync.status, .stopped(.dataDeleted))
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path))
    }

    /// A change made here asks the app to sync soon; one sync applied from another Mac doesn't.
    func testOnlyAChangeMadeHereAsksToSyncSoon() async throws {
        let id = try await shareProject()
        var asked: [String] = []
        macA.sync.onLocalChange = { asked.append("A") }
        macB.sync.onLocalChange = { asked.append("B") }

        try macA.library.mutate(id) { $0.name = "Renamed" }
        await macA.sync.syncNow()
        await macB.sync.syncNow()

        XCTAssertEqual(asked, ["A"])
        XCTAssertEqual(macB.library.document(id)?.name, "Renamed")
    }

    /// A save iCloud refused for now, as for a full quota, which it drops from its queue, goes again on Sync Now.
    func testAChangeThatFailedToSendGoesAgainNextSync() async throws {
        let id = try await shareProject()
        cloud.saveFailure = "Your iCloud storage is full."

        try macA.library.mutate(id) { $0.name = "Renamed" }
        await macA.sync.syncNow()
        XCTAssertEqual(macA.sync.status, .failed("Your iCloud storage is full."))
        cloud.saveFailure = nil
        await macA.sync.syncNow()
        await macB.sync.syncNow()
        XCTAssertEqual(macB.library.document(id)?.name, "API", "Not after every sync, which would send it each time")
        await macA.sync.syncNow(retryingFailures: true)
        await macB.sync.syncNow()

        XCTAssertEqual(macB.library.document(id)?.name, "Renamed")
        guard case .upToDate = macA.sync.status else {
            return XCTFail("Expected up to date, got \(macA.sync.status)")
        }
    }

    /// Sync Now looks for an account again after finding none, as when signing in went unnoticed.
    func testSyncNowLooksForAnAccountAgain() async throws {
        let id = try await shareProject()
        cloud.account = nil
        macB.sync.stop()
        await macB.sync.start()
        XCTAssertEqual(macB.sync.status, .signedOut)

        cloud.account = "account-a"
        try macA.library.mutate(id) { $0.name = "Renamed" }
        await macA.sync.syncNow()
        await macB.sync.syncNow()
        await macB.sync.syncNow()

        XCTAssertEqual(macB.library.document(id)?.name, "Renamed")
    }

    /// A fetch over from the start that falls short, or isn't reported whole, isn't repeated on every sync, only on
    /// Sync Now.
    func testAFetchFromTheStartThatFallsShortWaitsForSyncNow() async throws {
        try await shareProject()
        for mac in [macA, macB] {
            mac?.sync.transportFetchFailed("Lost", lostChanges: true)
        }
        macA.transport.foldsWhole = true
        macB.transport.fallsShort = true

        for mac in [macA, macB] {
            await mac?.sync.syncNow()
            await mac?.sync.syncNow()
        }
        let afterSyncs = [macA.transport.resets, macB.transport.resets]
        await macB.sync.syncNow(retryingFailures: true)

        XCTAssertEqual(afterSyncs, [1, 1], "Once, not twice a sync")
        XCTAssertEqual(macB.transport.resets, 2)
    }

    /// A refetch made in the background, whose end waits to be applied, doesn't hold off the next one.
    func testARefetchInTheBackgroundDoesntHoldOffTheNext() async throws {
        try await shareProject()
        macB.sync.transportFetchFailed("Lost", lostChanges: true)
        await macB.sync.setActive(false)
        await macB.sync.syncNow()
        await macB.sync.setActive(true)
        let resets = macB.transport.resets

        macB.sync.transportFetchFailed("Lost again", lostChanges: true)
        await macB.sync.syncNow()

        XCTAssertEqual(macB.transport.resets, resets + 1)
    }

    /// In the background, what a send reports waits behind the fetched changes waiting there, and no fetch starts over
    /// from the start, which each change made meanwhile would repeat.
    func testInTheBackgroundSendsWaitBehindFetchesAndNothingStartsOver() async throws {
        let id = try await shareProject()
        let added = RequestItem(name: "Added", kind: .http(HTTPRequestSpec()))
        try macA.library.mutate(id) { try $0.insert(.request(added), into: nil) }
        await macA.sync.syncNow()
        let record = try XCTUnwrap(cloud.record(SyncRecordID(zone: .project(id), name: added.id.description)))

        await macB.sync.setActive(false)
        macB.sync.transportFetchFailed("Lost", lostChanges: true)
        let resets = macB.transport.resets
        await macB.sync.syncNow()
        macB.sync.transport(didSend: [.saved(record)])

        XCTAssertEqual(macB.transport.resets, resets, "No fetch over from the start in the background")
        XCTAssertNil(macB.sync.store?.base(record.id), "Waits behind the fetch it followed")
        await macB.sync.setActive(true)
        XCTAssertNotNil(macB.sync.store?.base(record.id))
    }

    /// A zone whose save failed for good holds its records until Sync Now, rather than each queuing the zone again; a
    /// deletion an earlier fetch reported is dropped once a whole fetch delivers the zone.
    func testAZoneThatFailsToSaveHoldsItsRecordsAndADeliveredZoneIsntDeleted() async throws {
        let id = try await shareProject()
        let fresh = try macB.lifecycle.createProject(named: "Fresh")
        let record = SyncRecordID(zone: .project(fresh), name: SyncRecordID.projectName)

        macB.sync.handleSent([.zoneSaveFailed(.project(fresh), "Your iCloud storage is full."), .zoneMissing(record)])
        macB.sync.heldZoneDeletions = [(.project(id), .deleted)]
        macB.sync.finish(wholeDelivery: [.project(id), .library], fetchedAt: macB.clock)

        XCTAssertEqual(macB.sync.failedSends, [record], "Waits for Sync Now rather than queuing its zone again")
        XCTAssertEqual(macB.sync.status, .failed("Your iCloud storage is full."))
        XCTAssertTrue(macB.sync.syncs(id), "Still syncing, not detached")
        XCTAssertNotNil(macB.library.project(id))
    }

    /// A failure never hides a choice sync paused for, and a zone isn't made again for a project that stopped syncing.
    func testAFailureKeepsAPausedChoiceAndMakesNoZoneForAProjectGone() async throws {
        let id = try await shareProject()
        macB.lifecycle.removeProject(id)

        macB.sync.status = .confirmingDeletions([id])
        macB.sync.transportFetchFailed("Reqling couldn't reach iCloud.", lostChanges: false)
        macB.sync.handleSent([.zoneMissing(SyncRecordID(zone: .project(id), name: SyncRecordID.projectName))])

        XCTAssertEqual(macB.sync.status, .confirmingDeletions([id]))
        XCTAssertFalse(macB.transport.pending.contains(.saveZone(.project(id))))
    }

    /// Turning sync on again after its iCloud data was deleted merges without bases, so it backs up again first.
    func testSyncingAgainAfterTheDataWasDeletedBacksUpAgain() async throws {
        try await shareProject()
        var firstSyncs = 0
        macB.sync.onFirstSync = { firstSyncs += 1 }

        cloud.wipe(reason: .purged)
        await macB.sync.syncNow()
        await macB.sync.start()

        XCTAssertEqual(firstSyncs, 1)
    }

    /// An edit made while the request's last save was out goes too, though iCloud drops the queued save with the one it
    /// took.
    func testAnEditMadeWhileItsLastSaveWasOutGoesToo() async throws {
        let id = try await shareProject()
        try macA.library.mutate(id) { $0.name = "First" }
        macA.transport.whileSending = { [macA] in
            macA?.transport.whileSending = nil
            try? macA?.library.mutate(id) { $0.name = "Second" }
        }

        await macA.sync.syncNow()
        await macB.sync.syncNow()

        XCTAssertEqual(macB.library.document(id)?.name, "Second")
    }

    /// A project deleted while its first upload is out leaves nothing behind for another Mac to take up.
    func testAProjectDeletedDuringItsFirstUploadIsGoneEverywhere() async throws {
        try await shareProject()
        let id = try macA.lifecycle.createProject(named: "Brief")
        macA.transport.whileSending = { [macA] in
            macA?.transport.whileSending = nil
            try? macA?.lifecycle.deleteProject(id)
        }

        await macA.sync.syncNow()
        await macA.sync.syncNow()
        await macB.sync.syncNow()

        XCTAssertNil(macB.library.project(id))
        XCTAssertFalse(cloud.zones.contains(.project(id)))
    }

    /// Another Mac's deletion is judged with its tombstone, though the fetch that reported it dropped the tombstone.
    func testADeletionIsJudgedOnceItsTombstoneArrives() async throws {
        let id = try await shareProject()

        try macA.lifecycle.deleteProject(id)
        await macA.sync.syncNow()
        macB.transport.dropsZoneOnce = .library
        await macB.sync.syncNow()

        XCTAssertNil(macB.library.project(id))
        XCTAssertEqual(macB.storage.trashedNames(), ["API.reqling"], "Trashed, not kept as if it vanished")
    }

    /// A request put back as it was synced withdraws the deletion still queued for it.
    func testARequestPutBackWithdrawsItsQueuedDeletion() async throws {
        let id = try await shareProject()
        let original = try XCTUnwrap(request(in: macB, id))
        let folder = try XCTUnwrap(macB.library.document(id)?.items.first?.id)

        await macB.sync.setActive(false)
        try macB.library.mutate(id) { _ = try $0.removeNode(original.id) }
        try macB.library.mutate(id) { try $0.insert(.request(original), into: folder) }
        await macB.sync.setActive(true)
        await macA.sync.syncNow()

        XCTAssertEqual(request(in: macA, id)?.id, original.id)
    }

    /// Changes a fetch dropped undelivered are fetched again whole; a fetch that merely failed says so.
    func testAFetchThatFellShortFetchesEverythingAgain() async throws {
        let id = try await shareProject()
        try macA.library.mutate(id) { $0.name = "Renamed" }
        await macA.sync.syncNow()

        macB.sync.transportFetchFailed("Lost", lostChanges: true)
        XCTAssertEqual(macB.sync.store?.state.needsRefetch, true)
        await macB.sync.syncNow()
        macA.sync.transportFetchFailed("Reqling couldn't reach iCloud.", lostChanges: false)

        XCTAssertEqual(macB.sync.store?.state.needsRefetch, false)
        XCTAssertEqual(macB.library.document(id)?.name, "Renamed")
        XCTAssertEqual(macA.sync.status, .failed("Reqling couldn't reach iCloud."))
    }

    /// A record of a kind a newer Reqling added holds its project back, rather than being dropped as one this version
    /// can't place.
    func testARecordOfAKindANewerVersionAddedHoldsItsProjectBack() async throws {
        let id = try await shareProject()

        let unknown = SyncRecordID(zone: .project(id), name: "collection-1")
        _ = cloud.save(SyncRecord(id: unknown, type: .currentValues, payload: .object([]), schemaVersion: .max))
        await macB.sync.syncNow()

        XCTAssertEqual(macB.sync.deferredProjects, [id])
    }

    /// The account choice offers every project in scope, those that synced with the last account unticked, since they
    /// may be its data; a project elsewhere isn't offered, and never syncs.
    func testTheAccountChoiceOffersProjectsFromTheLastAccountUnticked() async throws {
        let synced = try await shareProject()
        let local = try macB.lifecycle.createProject(named: "Mine")
        let elsewhere = macB.storage.directory.file("Elsewhere")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let outside = try macB.lifecycle.createProject(named: "Outside", in: elsewhere)
        XCTAssertTrue(macB.sync.syncs(synced))
        XCTAssertFalse(macB.sync.syncs(outside))

        cloud.account = "account-b"
        macB.sync.stop()
        await macB.sync.start()

        XCTAssertEqual(macB.sync.status, .accountChanged)
        let offered = Dictionary(uniqueKeysWithValues: macB.sync.accountChangeCandidates.map { ($0.id, $0.syncedWithPreviousAccount) })
        XCTAssertEqual(offered, [synced: true, local: false])

        // The choice itself says what syncs, so the new account's first sync backs up without a word.
        var announced = 0
        macB.sync.onFirstSync = { announced += 1 }
        await macB.sync.resolveAccountChange(merging: [local])
        XCTAssertEqual(announced, 0)
        XCTAssertNotNil(macB.sync.backupDirectory)
    }
}
