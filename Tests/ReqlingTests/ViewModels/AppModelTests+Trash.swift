import Foundation
import ReqlingKit
import XCTest

@testable import Reqling

@MainActor
extension AppModelTests {
    func testTrashingARequestAsksBeforeDeletingIt() throws {
        let project = try makeProject()
        model.newRequest()
        let request = try XCTUnwrap(model.selection?.nodeID)
        let name = try XCTUnwrap(fixture.library.document(project)?.node(request)?.name)

        model.requestTrash(.node(project, request))

        let confirmation = try XCTUnwrap(model.trashPending)
        XCTAssertEqual(confirmation, TrashConfirmation(item: .node(project, request), name: name, kind: .request))
        XCTAssertNotNil(fixture.library.document(project)?.node(request), "asking deletes nothing")

        model.trash(confirmation)

        XCTAssertNil(model.trashPending)
        XCTAssertNil(fixture.library.document(project)?.node(request))
        XCTAssertNil(model.alert)
    }

    func testTrashingAFolderTakesItsContents() throws {
        let project = try makeProject()
        model.newFolder()
        let folder = try XCTUnwrap(model.selection?.nodeID)
        model.newRequest()
        let request = try XCTUnwrap(model.selection?.nodeID)
        let name = try XCTUnwrap(fixture.library.document(project)?.node(folder)?.name)

        model.requestTrash(.node(project, folder))

        let confirmation = try XCTUnwrap(model.trashPending)
        XCTAssertEqual(confirmation, TrashConfirmation(item: .node(project, folder), name: name, kind: .folder))

        model.trash(confirmation)

        XCTAssertNil(fixture.library.document(project)?.node(folder))
        XCTAssertNil(fixture.library.document(project)?.node(request))
    }

    func testTrashingAProjectAsksBeforeDeletingIt() throws {
        let project = try makeProject()

        model.requestTrash(.project(project))

        let confirmation = try XCTUnwrap(model.trashPending)
        XCTAssertEqual(confirmation, TrashConfirmation(item: .project(project), name: "API", kind: .project))
        XCTAssertNotNil(fixture.library.project(project), "asking deletes nothing")

        model.trash(confirmation)

        XCTAssertNil(model.trashPending)
        XCTAssertNil(fixture.library.project(project))
    }

    /// An agent or a `git pull` can delete the item while its confirmation is up, or before one is asked for; either way
    /// there is nothing left to trash, and nothing to alert about.
    func testTrashingAnItemAlreadyGoneDropsQuietly() throws {
        let project = try makeProject()
        model.newRequest()
        let request = try XCTUnwrap(model.selection?.nodeID)
        model.requestTrash(.node(project, request))
        let confirmation = try XCTUnwrap(model.trashPending)

        try fixture.library.mutate(project) { _ = try $0.removeNode(request) }
        model.trash(confirmation)

        XCTAssertNil(model.trashPending)
        XCTAssertNil(model.alert)

        model.requestTrash(.node(project, request))

        XCTAssertNil(model.trashPending)
    }
}
