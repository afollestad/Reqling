import Foundation
@testable import ReqlingKit
import XCTest

/// Connecting and stopping: what a failed connection, a stop, or a server reset leaves running, and what it keeps.
@MainActor
extension LibrarySyncTests {
    /// A connection that can't read its key drops the previous account's state rather than syncing on with it.
    func testAConnectionThatCantReadItsKeyKeepsNothingOfTheLastOne() async throws {
        let id = try await shareProject()

        macB.storage.secrets.isFailingReads = true
        cloud.account = "account-b"
        await macB.sync.connect()
        try macB.library.mutate(id) { $0.name = "Edited on B" }
        await macB.transport.sendChanges()
        await macA.sync.syncNow()

        XCTAssertNil(macB.sync.store)
        XCTAssertEqual(macA.library.document(id)?.name, "API")

        // Once the key can be read, coming forward connects again.
        macB.storage.secrets.isFailingReads = false
        cloud.account = "account-a"
        await macB.sync.setActive(true)

        XCTAssertNotNil(macB.sync.store)
    }

    /// A stopped coordinator ignores the account changing.
    func testAStoppedSyncDoesntReconnect() async throws {
        try await shareProject()

        macB.sync.stop()
        await macB.sync.connect()

        XCTAssertEqual(macB.sync.status, .off)
        XCTAssertNil(macB.sync.store)
    }

    /// Failing to read the account isn't being signed out: coming forward tries again.
    func testAnAccountThatCouldntBeReadIsTriedAgainOnComingForward() async throws {
        let id = try await shareProject()

        macB.sync.stop()
        cloud.accountFailure = URLError(.notConnectedToInternet)
        await macB.sync.start()
        guard case .failed = macB.sync.status else {
            return XCTFail("Expected a failure, got \(macB.sync.status)")
        }

        cloud.accountFailure = nil
        try macA.library.mutate(id) { $0.name = "Renamed" }
        await macA.sync.syncNow()
        await macB.sync.setActive(true)

        XCTAssertEqual(macB.library.document(id)?.name, "Renamed")
    }

    /// Projects kept out of an account stay out after its data was deleted from iCloud and sync is turned back on.
    func testProjectsKeptOutOfAnAccountStayOutAfterItsDataIsDeleted() async throws {
        let id = try await shareProject()
        cloud.account = "account-b"
        macB.sync.stop()
        await macB.sync.start()
        await macB.sync.resolveAccountChange(merging: [])

        cloud.wipe(reason: .purged)
        await macB.sync.syncNow()
        XCTAssertEqual(macB.sync.status, .stopped(.dataDeleted))
        await macB.sync.start()

        XCTAssertNotNil(macB.library.project(id))
        XCTAssertFalse(cloud.zones.contains(.project(id)), "Kept out, so not uploaded")
    }

    /// A damaged `state.json` loses what sync knew of the server, never which projects the person kept out.
    func testADamagedStateKeepsTheProjectsKeptOut() async throws {
        let id = try await shareProject()
        let folder = macB.storage.directory.file("Support/Sync").appendingPathComponent(SyncBaseStore.folderName(for: "account-a"))

        macB.lifecycle.removeProject(id)
        macB.sync.stop()
        try Data("not json".utf8).write(to: folder.appendingPathComponent("state.json"))
        await macB.sync.start()
        try macA.library.mutate(id) { $0.name = "Renamed" }
        await macA.sync.syncNow()
        await macB.sync.syncNow()

        XCTAssertNil(macB.library.project(id))
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        XCTAssertTrue(names.contains { $0.hasPrefix("state.corrupt-") }, "Set aside, not overwritten: \(names)")
    }
}
