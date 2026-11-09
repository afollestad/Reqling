import Foundation
@testable import ReqlingKit
import XCTest

/// Fetching everything again: what a whole fetch tells by leaving things out, and what a refetch asked for outlives.
@MainActor
extension LibrarySyncTests {
    /// A whole fetch reports no deletions, so a project or request it leaves out was deleted.
    func testAWholeFetchTellsDeletionsByWhatItLeavesOut() async throws {
        let deleted = try await shareProject("Deleted")
        let kept = try await shareProject("Kept")
        let requestID = try XCTUnwrap(request(in: macA, kept)).id

        try macA.lifecycle.deleteProject(deleted)
        try macA.library.mutate(kept) { _ = try $0.removeNode(requestID) }
        await macA.sync.syncNow()
        macB.transport.resetState()
        await macB.sync.syncNow()

        XCTAssertNil(macB.library.project(deleted))
        XCTAssertTrue(macB.storage.trashedNames().contains("Deleted.reqling"))
        XCTAssertNil(macB.library.document(kept)?.request(requestID))
        XCTAssertNil(cloud.record(SyncRecordID(zone: .project(kept), name: requestID.description)))
    }

    /// A project held back over a record that wouldn't decode is judged again on the next launch, not only after an update.
    func testAProjectHeldBackOverAnUnreadableRecordIsJudgedAgainOnLaunch() async throws {
        let id = try await shareProject()
        let projectRecord = SyncRecordID(zone: .project(id), name: SyncRecordID.projectName)
        let good = try XCTUnwrap(cloud.record(projectRecord))
        var broken = good
        broken.payload = .string("not a project")
        _ = cloud.save(broken)
        await macB.sync.syncNow()
        XCTAssertEqual(macB.sync.deferredProjects, [id])

        var repaired = try XCTUnwrap(cloud.record(projectRecord))
        repaired.payload = renamed(good.payload, to: "Repaired")
        _ = cloud.save(repaired)
        await macB.restart()

        XCTAssertEqual(macB.sync.deferredProjects, [])
        XCTAssertEqual(macB.library.document(id)?.name, "Repaired")
    }

    /// A refetch asked for, then started in the background and quit before Reqling came forward, still happens later.
    func testARefetchStartedInTheBackgroundSurvivesAQuit() async throws {
        let id = try await shareProject()
        let folder = try XCTUnwrap(macB.library.project(id)).url

        macB.lifecycle.removeProject(id)
        try macA.library.mutate(id) { $0.name = "Renamed while removed" }
        await macA.sync.syncNow()
        await macB.sync.syncNow()
        _ = try macB.lifecycle.addProjectFolder(folder)
        await macB.sync.setActive(false)
        await macB.sync.syncNow()
        await macB.restart()

        XCTAssertEqual(macB.library.document(id)?.name, "Renamed while removed")
    }

    /// A whole fetch that finds none of what synced, not even Global, saw the account's data deleted: sync stops, rather
    /// than detaching every project and sending Global back.
    func testAWholeFetchThatFindsNothingStopsSync() async throws {
        let id = try await shareProject()
        try macB.library.mutateGlobalEnvironment { $0.variables = [Variable(key: "region", value: "eu")] }
        await macB.sync.syncNow()

        cloud.wipe(reason: .purged)
        macB.transport.resetState()
        await macB.sync.syncNow()

        XCTAssertEqual(macB.sync.status, .stopped(.dataDeleted))
        XCTAssertNotNil(macB.library.project(id))
        XCTAssertTrue(cloud.zones.isEmpty, "Nothing sent back")
    }

    /// Background fetches judge each whole one by its own zones: one an earlier fetch delivered and that's gone since
    /// still reads as deleted.
    func testAHeldWholeFetchJudgesDeletionsByItsOwnZones() async throws {
        let id = try await shareProject()

        await macB.sync.setActive(false)
        try macA.library.mutate(id) { $0.name = "Renamed" }
        await macA.sync.syncNow()
        await macB.sync.syncNow()
        try macA.lifecycle.deleteProject(id)
        await macA.sync.syncNow()
        macB.transport.resetState()
        await macB.sync.syncNow()
        await macB.sync.setActive(true)

        XCTAssertNil(macB.library.project(id))
        XCTAssertEqual(macB.storage.trashedNames(), ["API.reqling"])
    }

    /// A project added back merges over what it last synced, so what another Mac deleted while it was away stays deleted.
    func testAProjectAddedBackKeepsDeletionsMadeWhileItWasAway() async throws {
        let id = try await shareProject()
        let folder = try XCTUnwrap(macB.library.project(id)).url
        let requestID = try XCTUnwrap(request(in: macA, id)).id

        macB.lifecycle.removeProject(id)
        try macA.library.mutate(id) { try $0.updateFolder(try XCTUnwrap($0.items.first?.id)) { $0.children = [] } }
        await macA.sync.syncNow()
        await macB.sync.syncNow()
        _ = try macB.lifecycle.addProjectFolder(folder)
        await macB.sync.syncNow()
        await macA.sync.syncNow()

        XCTAssertNil(macB.library.document(id)?.request(requestID))
        XCTAssertNil(macA.library.document(id)?.request(requestID))
    }

    /// A project another Mac created after a background whole fetch, and fetched after it, isn't judged as gone by it.
    func testAProjectFetchedAfterAHeldWholeFetchIsntJudgedGone() async throws {
        try await shareProject()

        await macB.sync.setActive(false)
        macB.transport.resetState()
        await macB.sync.syncNow()
        let created = try macA.lifecycle.createProject(named: "Brand new")
        await macA.sync.syncNow()
        await macB.transport.fetchChanges()
        await macB.sync.setActive(true)
        try macB.library.mutate(created) { $0.name = "Renamed on B" }
        await macB.sync.syncNow()
        await macA.sync.syncNow()

        XCTAssertTrue(macB.sync.issues.isEmpty, "\(macB.sync.issues)")
        XCTAssertEqual(macA.library.document(created)?.name, "Renamed on B")
    }

    /// Adding back an older copy of a removed project keeps what the copy lacks, rather than deleting it everywhere.
    func testAddingBackAnOlderCopyKeepsWhatItLacks() async throws {
        let id = try await shareProject()
        let folder = try XCTUnwrap(macB.library.project(id)).url
        let older = macB.storage.directory.file("Older.reqling")
        try FileManager.default.copyItem(at: folder, to: older)

        try macA.library.mutate(id) { try $0.insert(.request(RequestItem(name: "Added later", kind: .http(HTTPRequestSpec()))), into: nil) }
        await macA.sync.syncNow()
        await macB.sync.syncNow()
        macB.lifecycle.removeProject(id)
        try FileManager.default.removeItem(at: folder)
        try FileManager.default.moveItem(at: older, to: folder)
        _ = try macB.lifecycle.addProjectFolder(folder)
        await macB.sync.syncNow()
        await macA.sync.syncNow()

        XCTAssertEqual(macA.library.document(id)?.allRequests.map(\.0.name).sorted(), ["Added later", "List users"])
        XCTAssertEqual(macB.library.document(id)?.allRequests.map(\.0.name).sorted(), ["Added later", "List users"])
    }

    /// An older copy added back doesn't revert what changed since it was made: what it holds differently merges with
    /// the server's values winning.
    func testAddingBackAnOlderCopyDoesntRevertNewerValues() async throws {
        let id = try await shareProject()
        let folder = try XCTUnwrap(macB.library.project(id)).url
        let older = macB.storage.directory.file("Older.reqling")
        try FileManager.default.copyItem(at: folder, to: older)
        let requestID = try XCTUnwrap(request(in: macA, id)).id

        try macA.library.mutate(id) { try $0.updateNode(requestID) { $0.name = "Renamed on A" } }
        await macA.sync.syncNow()
        await macB.sync.syncNow()
        macB.lifecycle.removeProject(id)
        try FileManager.default.removeItem(at: folder)
        try FileManager.default.moveItem(at: older, to: folder)
        _ = try macB.lifecycle.addProjectFolder(folder)
        await macB.sync.syncNow()
        await macA.sync.syncNow()

        XCTAssertEqual(request(in: macA, id)?.name, "Renamed on A")
        XCTAssertEqual(request(in: macB, id)?.name, "Renamed on A")
    }

    /// `payload` with its `name` member set to `name`.
    func renamed(_ payload: OrderedJSON, to name: String) -> OrderedJSON {
        guard case .object(let members) = payload else {
            return payload
        }
        return .object(members.map { $0.key == "name" ? OrderedJSONMember(key: "name", value: .string(name)) : $0 })
    }
}
