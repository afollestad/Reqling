import Foundation
import ReqlingKit
import XCTest

@testable import Reqling

/// Moving folders and requests within a project and into another, and reordering projects.
@MainActor
extension AppModelTests {
    /// Two projects: API, whose Admin folder holds Ping, and an empty Web.
    private struct MoveFixture {
        let api: ProjectID
        let web: ProjectID
        let admin: RequestFolder
        let ping: RequestItem
    }

    private func makeMoveFixture() throws -> MoveFixture {
        let api = try makeProject()
        model.createProject(named: "Web")
        let web = try XCTUnwrap(model.selection?.projectID)
        let ping = RequestItem(name: "Ping", kind: .http(HTTPRequestSpec(url: "https://api/ping")))
        let admin = RequestFolder(name: "Admin", children: [.request(ping)])
        try fixture.library.mutate(api) { try $0.insert(.folder(admin), into: nil) }
        return MoveFixture(api: api, web: web, admin: admin, ping: ping)
    }

    func testAMoveWithinAProjectPlacesTheItemAndOpensItsNewFolder() throws {
        let project = try makeProject()
        let first = RequestItem(name: "First", kind: .http(HTTPRequestSpec()))
        let second = RequestItem(name: "Second", kind: .http(HTTPRequestSpec()))
        let folder = RequestFolder(name: "Folder")
        try fixture.library.mutate(project) { $0.items = [.request(first), .request(second), .folder(folder)] }

        model.requestMove(second.id, from: project, to: project, into: nil, at: 0)
        model.requestMove(first.id, from: project, to: project, into: folder.id, at: 0)

        let document = try XCTUnwrap(fixture.library.document(project))
        XCTAssertEqual(document.items.map(\.id), [second.id, folder.id])
        XCTAssertEqual(document.folder(folder.id)?.children.map(\.id), [first.id])
        XCTAssertTrue(model.isExpanded(folder: folder.id, in: project))
        XCTAssertNil(model.movePending, "Only a move into another project asks first")
    }

    func testAMoveSavesTheSelectedRequestsPendingEditFirst() throws {
        let project = try makeProject()
        model.newFolder()
        let folder = try XCTUnwrap(model.selection?.nodeID)
        model.selection = .project(project)
        model.newRequest()
        let request = try XCTUnwrap(model.selection?.nodeID)
        model.editor?.asHTTP?.spec.method = .post

        model.requestMove(request, from: project, to: project, into: folder, at: nil)

        let moved = try XCTUnwrap(fixture.library.document(project)?.folder(folder)?.children.first)
        guard case .request(let item) = moved, case .http(let spec) = item.kind else {
            return XCTFail("Expected the HTTP request inside the folder")
        }
        XCTAssertEqual(spec.method, .post)
    }

    /// The item stays put until the move is confirmed; then it lands in the other project, opened to show it, and the
    /// selection inside it follows.
    func testAMoveIntoAnotherProjectWaitsForConfirmationAndTheSelectionFollows() throws {
        let setup = try makeMoveFixture()
        model.setExpanded(false, project: setup.web)
        model.selection = .node(setup.api, setup.ping.id)

        model.requestMove(setup.admin.id, from: setup.api, to: setup.web, into: nil, at: nil)

        let pending = try XCTUnwrap(model.movePending)
        XCTAssertEqual(pending.title, "Move “Admin” to “Web”?")
        XCTAssertNotNil(fixture.library.document(setup.api)?.folder(setup.admin.id))

        model.move(pending)

        XCTAssertNil(model.movePending)
        XCTAssertTrue(try XCTUnwrap(fixture.library.document(setup.api)).items.isEmpty)
        XCTAssertEqual(fixture.library.document(setup.web)?.folder(setup.admin.id)?.children.map(\.id), [setup.ping.id])
        XCTAssertEqual(model.selection, .node(setup.web, setup.ping.id))
        XCTAssertTrue(model.isExpanded(setup.web))
        XCTAssertTrue(model.isExpanded(folder: setup.admin.id, in: setup.web))
        XCTAssertNil(model.alert)
    }

    /// A destination that already uses one of the item's IDs gets a copy with fresh ones, so a selection inside it can
    /// only follow to the item itself.
    func testASelectionInsideAnItemGivenFreshIDsLandsOnTheItem() throws {
        let setup = try makeMoveFixture()
        try fixture.library.mutate(setup.web) { try $0.insert(.request(setup.ping), into: nil) }
        model.selection = .node(setup.api, setup.ping.id)

        model.requestMove(setup.admin.id, from: setup.api, to: setup.web, into: nil, at: 0)
        model.move(try XCTUnwrap(model.movePending))

        let landed = try XCTUnwrap(fixture.library.document(setup.web)?.items.first)
        XCTAssertEqual(landed.name, "Admin")
        XCTAssertNotEqual(landed.id, setup.admin.id)
        XCTAssertEqual(model.selection, .node(setup.web, landed.id))
    }

    /// A file shared by a path inside the source's folder is outside the destination's, so the move keeps it on this
    /// Mac only and says which.
    func testAMoveIntoAnotherProjectNamesTheFilesNowFoundOnThisMacOnly() throws {
        let setup = try makeMoveFixture()
        let apiFolder = try XCTUnwrap(fixture.library.project(setup.api)?.url)
        let file = apiFolder.appendingPathComponent("body.bin")
        try Data([1, 2, 3]).write(to: file)
        var spec = HTTPRequestSpec(url: "https://api/upload")
        spec.body.binary.file = .relative("body.bin")
        let upload = RequestItem(name: "Upload", kind: .http(spec))
        try fixture.library.mutate(setup.api) { try $0.insert(.request(upload), into: nil) }

        model.requestMove(upload.id, from: setup.api, to: setup.web, into: nil, at: nil)
        model.move(try XCTUnwrap(model.movePending))

        let alert = try XCTUnwrap(model.alert)
        XCTAssertEqual(alert.title, "Files Now Found on This Mac Only")
        XCTAssertTrue(alert.message.contains(file.path), alert.message)
        XCTAssertNotNil(fixture.library.document(setup.web)?.request(upload.id))
    }

    /// A source that can't let go leaves the item in both projects rather than in neither, and says so.
    func testAMoveThatCantLeaveItsProjectSaysItIsInBoth() throws {
        let setup = try makeMoveFixture()
        let trash = fixture.profile.trashDirectory
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: trash.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: trash.path) }

        model.requestMove(setup.ping.id, from: setup.api, to: setup.web, into: nil, at: nil)
        model.move(try XCTUnwrap(model.movePending))

        let alert = try XCTUnwrap(model.alert)
        XCTAssertTrue(alert.message.contains("so it is in both"), alert.message)
        XCTAssertNotNil(fixture.library.document(setup.api)?.request(setup.ping.id))
        XCTAssertNotNil(fixture.library.document(setup.web)?.request(setup.ping.id))
    }

    /// A project saved by a newer Reqling opens read-only, so nothing moves into or out of it.
    func testAReadOnlyProjectTakesNoMoveInOrOut() throws {
        let setup = try makeMoveFixture()
        let projectFile = try XCTUnwrap(fixture.library.project(setup.web)?.url).appendingPathComponent("project.json")
        let json = try String(contentsOf: projectFile, encoding: .utf8)
            .replacingOccurrences(of: #""formatVersion" : 1"#, with: #""formatVersion" : 99"#)
        try json.write(to: projectFile, atomically: true, encoding: .utf8)
        fixture.library.reload(setup.web)
        XCTAssertEqual(fixture.library.project(setup.web)?.isReadOnly, true)

        model.requestMove(setup.ping.id, from: setup.api, to: setup.web, into: nil, at: nil)

        XCTAssertFalse(model.canMoveNode(setup.ping.id, from: setup.api, to: setup.web, into: nil))
        XCTAssertNil(model.movePending)
        XCTAssertNotNil(fixture.library.document(setup.api)?.request(setup.ping.id))
    }

    /// An item deleted while its confirmation is up is dropped quietly when the move is confirmed.
    func testConfirmingTheMoveOfAnItemSinceDeletedDoesNothing() throws {
        let setup = try makeMoveFixture()
        model.requestMove(setup.ping.id, from: setup.api, to: setup.web, into: nil, at: nil)
        let pending = try XCTUnwrap(model.movePending)

        model.delete(setup.ping.id, in: setup.api)
        model.move(pending)

        XCTAssertNil(model.alert)
        XCTAssertTrue(try XCTUnwrap(fixture.library.document(setup.web)).items.isEmpty)
    }

    func testMovingAProjectReordersTheSidebar() throws {
        let api = try makeProject()
        model.createProject(named: "Web")
        let web = try XCTUnwrap(model.selection?.projectID)
        model.createProject(named: "Admin")
        let admin = try XCTUnwrap(model.selection?.projectID)
        XCTAssertEqual(fixture.library.projects.map(\.id), [api, web, admin])

        model.moveProject(admin, to: 0)
        model.moveProject(api, to: 2)

        XCTAssertEqual(fixture.library.projects.map(\.id), [admin, web, api])
    }
}
