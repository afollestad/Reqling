import Foundation
@testable import ReqlingKit
import ReqlingTemplating
import XCTest

/// What sync keeps across a quit, how a project comes back after leaving, and how resets reach the other Mac.
@MainActor
extension LibrarySyncTests {
    func testADeletionMadeJustBeforeAQuitStillReachesTheOtherMac() async throws {
        let id = try await shareProject()

        try macA.lifecycle.deleteProject(id)
        await macA.restart()
        await macB.sync.syncNow()

        XCTAssertNil(macB.library.project(id))
        XCTAssertEqual(macB.storage.trashedNames(), ["API.reqling"])
        XCTAssertFalse(cloud.zones.contains(.project(id)))
    }

    /// A pending question about deletions outlives a quit; declining keeps the projects here, and adding one back
    /// withdraws its deletion, so it returns on the Mac that deleted it.
    func testAConfirmationOutlivesAQuitAndDecliningKeepsTheProjects() async throws {
        let first = try await shareProject("One")
        let second = try await shareProject("Two")
        try macA.lifecycle.deleteProject(first)
        try macA.lifecycle.deleteProject(second)
        await macA.sync.syncNow()
        await macB.sync.syncNow()

        await macB.restart()
        XCTAssertEqual(Set(caseValues(macB.sync.status)), [first, second])

        await macB.sync.confirmDeletions(false)
        try macB.library.mutate(first) { $0.name = "Kept on B" }
        await macB.sync.syncNow()

        XCTAssertEqual(macB.library.document(first)?.name, "Kept on B")
        XCTAssertEqual(macB.storage.trashedNames(), [])
        XCTAssertFalse(cloud.zones.contains(.project(first)), "Kept on this Mac only")

        let folder = try XCTUnwrap(macB.library.project(first)).url
        macB.lifecycle.removeProject(first)
        _ = try macB.lifecycle.addProjectFolder(folder)
        await macB.sync.syncNow()
        await macA.sync.syncNow()

        XCTAssertNil(cloud.record(LibraryRecordCoder.tombstoneRecordID(first)))
        XCTAssertEqual(macA.library.document(first)?.name, "Kept on B")
        XCTAssertNil(macA.library.project(second))
    }

    func testAProjectAddedBackAfterBeingRemovedCatchesUpOnWhatItMissed() async throws {
        let id = try await shareProject()
        let folder = try XCTUnwrap(macB.library.project(id)).url

        macB.lifecycle.removeProject(id)
        try macA.library.mutate(id) {
            $0.name = "Renamed while removed"
            try $0.insert(.request(RequestItem(name: "Added while removed", kind: .http(HTTPRequestSpec()))), into: nil)
        }
        await macA.sync.syncNow()
        await macB.sync.syncNow()
        _ = try macB.lifecycle.addProjectFolder(folder)
        await macB.sync.syncNow()
        await macA.sync.syncNow()

        XCTAssertEqual(macB.library.document(id)?.name, "Renamed while removed")
        XCTAssertEqual(macB.library.document(id)?.allRequests.map(\.0.name).sorted(), ["Added while removed", "List users"])
        XCTAssertEqual(macA.library.document(id)?.name, "Renamed while removed")
    }

    func testAProjectRemovedWhileSyncWasOffStaysRemoved() async throws {
        let id = try await shareProject()

        macB.sync.stop()
        macB.lifecycle.removeProject(id)
        await macB.sync.start()
        try macA.library.mutate(id) { $0.name = "Renamed" }
        await macA.sync.syncNow()
        await macB.sync.syncNow()
        await macB.restart()

        XCTAssertNil(macB.library.project(id))
        XCTAssertEqual(macB.sync.deferredProjects, [])
    }

    func testResettingGlobalCurrentValuesReachesTheOtherMac() async throws {
        macA.library.currentValues.apply(["session": .value(TemplateVariable(value: "abc"))], in: .global)
        await macA.sync.syncNow()
        await macB.sync.syncNow()
        XCTAssertEqual(macB.library.currentValues.values(in: .global)["session"], .value(TemplateVariable(value: "abc")))

        macB.library.currentValues.reset(in: .global)
        await macB.sync.syncNow()
        await macA.sync.syncNow()
        await macB.sync.syncNow()

        XCTAssertNil(macA.library.currentValues.values(in: .global)["session"])
        XCTAssertNil(macB.library.currentValues.values(in: .global)["session"])
    }

    /// Values one Mac changed outlive their reset on another that hadn't seen the change.
    func testCurrentValuesChangedOnOneMacSurviveTheirResetOnAnother() async throws {
        let id = try await shareProject()
        let scope = CurrentValueScope.environment(id, try XCTUnwrap(macA.library.document(id)).defaultEnvironment.id)
        macA.library.currentValues.apply(["session": .value(TemplateVariable(value: "one"))], in: scope)
        await macA.sync.syncNow()
        await macB.sync.syncNow()

        macB.library.currentValues.reset(in: scope)
        await macB.sync.syncNow()
        macA.library.currentValues.apply(["session": .value(TemplateVariable(value: "two"))], in: scope)
        await macA.sync.syncNow()
        await macB.sync.syncNow()

        XCTAssertEqual(macA.library.currentValues.values(in: scope)["session"], .value(TemplateVariable(value: "two")))
        XCTAssertEqual(macB.library.currentValues.values(in: scope)["session"], .value(TemplateVariable(value: "two")))
    }

    /// A synced project that fell off a set-aside list with its folder gone too is fetched whole again, never rebuilt
    /// from what changed, which would delete the rest everywhere.
    func testAProjectLostWithTheListComesBackWholeAndDeletesNothing() async throws {
        let id = try await shareProject()
        let folder = try XCTUnwrap(macB.library.project(id)).url

        macB.sync.stop()
        macB.lifecycle.removeProject(id)
        try FileManager.default.removeItem(at: folder)
        macB.library.registryWasSetAside = true
        await macB.sync.start()
        try macA.library.mutate(id) { $0.name = "Renamed" }
        await macA.sync.syncNow()
        await macB.sync.syncNow()
        await macA.sync.syncNow()

        XCTAssertEqual(macB.library.document(id)?.name, "Renamed")
        XCTAssertEqual(request(in: macB, id)?.name, "List users")
        XCTAssertEqual(request(in: macA, id)?.name, "List users")
    }

    /// A project this Mac deleted and then put back from the Trash syncs again, rather than reading as deleted elsewhere.
    func testAProjectPutBackFromTheTrashSyncsAgain() async throws {
        let id = try await shareProject()
        try macA.lifecycle.deleteProject(id)
        await macA.sync.syncNow()
        await macB.sync.syncNow()
        await macA.sync.syncNow()

        let trashed = try XCTUnwrap(try FileManager.default.contentsOfDirectory(atPath: macA.storage.trashDirectory.path).first)
        let restored = macA.library.configuration.defaultProjectsDirectory.appendingPathComponent("API.reqling")
        try FileManager.default.moveItem(at: macA.storage.trashDirectory.appendingPathComponent(trashed), to: restored)
        _ = try macA.lifecycle.addProjectFolder(restored)
        await macA.sync.syncNow()
        await macB.sync.syncNow()

        XCTAssertEqual(macA.sync.deferredProjects, [])
        XCTAssertTrue(macA.sync.issues.isEmpty, "\(macA.sync.issues)")
        XCTAssertTrue(cloud.zones.contains(.project(id)))
        XCTAssertNil(cloud.record(LibraryRecordCoder.tombstoneRecordID(id)))
        XCTAssertEqual(request(in: macB, id)?.name, "List users")
    }

    /// A project put back and then reopened before its tombstone's deletion went out still withdraws the tombstone, so
    /// other Macs keep sending its edits.
    func testAProjectPutBackWithdrawsItsTombstoneAcrossARelaunch() async throws {
        let id = try await shareProject()
        try macA.lifecycle.deleteProject(id)
        await macA.sync.syncNow()
        await macB.sync.syncNow()
        await macA.sync.syncNow()

        let trashed = try XCTUnwrap(try FileManager.default.contentsOfDirectory(atPath: macA.storage.trashDirectory.path).first)
        let restored = macA.library.configuration.defaultProjectsDirectory.appendingPathComponent("API.reqling")
        try FileManager.default.moveItem(at: macA.storage.trashDirectory.appendingPathComponent(trashed), to: restored)
        _ = try macA.lifecycle.addProjectFolder(restored)
        await macA.restart()
        await macA.sync.syncNow()
        await macB.sync.syncNow()
        try macB.library.mutate(id) { $0.name = "Edited on B" }
        await macB.sync.syncNow()
        await macA.sync.syncNow()

        XCTAssertNil(cloud.record(LibraryRecordCoder.tombstoneRecordID(id)))
        XCTAssertEqual(macA.library.document(id)?.name, "Edited on B")
    }
}
