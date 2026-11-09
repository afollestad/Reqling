import Foundation
@testable import ReqlingKit
import XCTest

/// Orderings a real transport produces: batches split mid-change, sends before fetches, edits made while sync is
/// paused, and clocks that disagree.
@MainActor
extension LibrarySyncTests {
    /// A folder's deletion split across two batches never leaves its request behind to come back at the top level.
    func testAFolderDeletedAcrossTwoBatchesTakesItsRequestWithIt() async throws {
        let id = try await shareProject()
        let folder = try folderID(in: macA, id)
        let requestID = try XCTUnwrap(request(in: macA, id)).id

        try macA.library.mutate(id) { _ = try $0.removeNode(folder) }
        await macA.transport.fetchChanges()
        // The project's new order, then one deletion at a time, with Mac B fetching after each.
        for _ in 0..<3 {
            macA.transport.sendBatch(limit: 1)
            await macB.sync.syncNow()
        }
        await macA.sync.syncNow()
        await macB.sync.syncNow()

        XCTAssertEqual(macB.library.document(id)?.items, [])
        XCTAssertNil(cloud.record(SyncRecordID(zone: .project(id), name: requestID.description)))
        XCTAssertEqual(macA.library.document(id)?.items, [])
    }

    /// An edit sent before this Mac learns another deleted the project doesn't bring the project back; the next fetch
    /// moves it to the Trash here as usual.
    func testAnEditSentBeforeFetchingADeletionDoesntRecreateTheProject() async throws {
        let id = try await shareProject()

        try macA.lifecycle.deleteProject(id)
        await macA.sync.syncNow()
        try macB.library.mutate(id) { $0.name = "Edited on B" }
        await macB.transport.sendChanges()

        XCTAssertFalse(cloud.zones.contains(.project(id)))

        await macB.sync.syncNow()

        XCTAssertNil(macB.library.project(id))
        XCTAssertEqual(macB.storage.trashedNames(), ["API.reqling"])
        XCTAssertFalse(cloud.zones.contains(.project(id)))
    }

    /// An edit made while deletions wait for a confirmation keeps the time it was made, not the time it goes out.
    func testAnEditMadeWhileDeletionsWaitKeepsItsTime() async throws {
        let first = try await shareProject("One")
        let second = try await shareProject("Two")
        let kept = try await shareProject("Kept")
        try macA.lifecycle.deleteProject(first)
        try macA.lifecycle.deleteProject(second)
        await macA.sync.syncNow()
        await macB.sync.syncNow()
        XCTAssertEqual(Set(caseValues(macB.sync.status)), [first, second])

        macB.tick()
        try macB.library.mutate(kept) { $0.name = "From B, earlier" }
        macA.tick(5)
        try macA.library.mutate(kept) { $0.name = "From A, later" }
        await macA.sync.syncNow()
        macB.tick(10)
        await macB.sync.confirmDeletions(true)
        await macA.sync.syncNow()

        XCTAssertEqual(macB.library.document(kept)?.name, "From A, later")
        XCTAssertEqual(macA.library.document(kept)?.name, "From A, later")
    }

    /// A Mac whose clock runs ahead doesn't win a field it changed earlier than another Mac did.
    func testAClockRunningAheadDoesntWinAnEarlierEdit() async throws {
        macA.clockOffset = 3_600
        let id = try await shareProject()

        macA.tick()
        try macA.library.mutate(id) { $0.name = "From A, earlier" }
        macB.tick(5)
        try macB.library.mutate(id) { $0.name = "From B, later" }
        await macB.sync.syncNow()
        await macA.sync.syncNow()
        await macB.sync.syncNow()

        XCTAssertEqual(macA.library.document(id)?.name, "From B, later")
        XCTAssertEqual(macB.library.document(id)?.name, "From B, later")
    }

    /// An edit that lost a merge isn't sent again as a newer one, which would beat a later edit from a third Mac.
    func testAnEditThatLostAMergeIsntResentAsNewer() async throws {
        let macC = try SyncTestMac(cloud: cloud)
        defer { macC.cleanUp() }
        await macC.sync.start()
        let id = try await shareProject()
        await macC.sync.syncNow()

        macB.tick()
        try macB.library.mutate(id) { $0.name = "From B, first" }
        macA.tick()
        try macA.library.mutate(id) { $0.name = "From A, second" }
        await macA.sync.syncNow()
        macC.tick()
        try macC.library.mutate(id) { $0.name = "From C, third" }
        macB.tick()
        await macB.sync.syncNow()
        await macC.sync.syncNow()
        await macB.sync.syncNow()

        XCTAssertEqual(macC.library.document(id)?.name, "From C, third")
        XCTAssertEqual(macB.library.document(id)?.name, "From C, third")
    }

    /// A Mac whose clock runs behind sends its edits on the server's clock, so a later edit of its still wins, and a
    /// relaunch keeps what it measured.
    func testAClockRunningBehindStillWinsALaterEditAfterARelaunch() async throws {
        macA.clockOffset = -3_600
        let id = try await shareProject()
        await macA.restart()

        macB.tick()
        try macB.library.mutate(id) { $0.name = "From B, earlier" }
        macA.tick(5)
        try macA.library.mutate(id) { $0.name = "From A, later" }
        await macA.sync.syncNow()
        await macB.sync.syncNow()
        await macA.sync.syncNow()

        XCTAssertEqual(macB.library.document(id)?.name, "From A, later")
        XCTAssertEqual(macA.library.document(id)?.name, "From A, later")
    }

    /// A conflict whose merge can't be written isn't sent again and again: it waits for the next fetch.
    func testAConflictThatCantBeWrittenIsntResentEndlessly() async throws {
        let id = try await shareProject()
        let environment = SyncRecordID(zone: .project(id), name: try XCTUnwrap(macA.library.document(id)).defaultEnvironment.id.description)
        func setToken(_ value: String, on mac: SyncTestMac) throws {
            try mac.library.mutate(id) { document in
                if let index = document.defaultEnvironment.variables.firstIndex(where: { $0.key == "token" }) {
                    document.defaultEnvironment.variables[index].value = value
                }
            }
        }

        macB.tick()
        try setToken("from B", on: macB)
        macA.tick(5)
        try setToken("from A", on: macA)
        await macA.sync.syncNow()
        let attempts = cloud.saveAttempts[environment] ?? 0
        macB.storage.secrets.isFailingWrites = true
        await macB.transport.sendChanges()

        XCTAssertEqual(cloud.saveAttempts[environment], attempts + 1)
    }
}
