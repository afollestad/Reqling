import Foundation
import ReqlingKit
import XCTest

/// Scripts as `.js` files beside their owners: written as typed, read back, moved, trashed, and reserved with them.
@MainActor
extension ProjectLibraryTests {
    private struct ScriptedProject {
        let id: ProjectID
        let folder: RequestFolder
        let request: RequestItem
    }

    private func scriptedProject() throws -> ScriptedProject {
        let id = try fixture.library.createProject(named: "Scripts")
        var folder = RequestFolder(name: "Users")
        folder.scripts.preRequest = "rq.variables.set(\"folder\", 1)\n"
        var request = RequestItem.http("List users")
        request.scripts = ScriptSet(
            preRequest: "// pre\r\nconsole.log('é')",
            stream: "rq.onEvent(() => {})\n",
            postResponse: "rq.test(\"ok\", () => {})\n"
        )
        try fixture.library.mutate(id) { document in
            document.scripts.postResponse = "console.log(\"project\")\n"
            document.scripts.stream = "rq.onMessage(() => {})\n"
            try document.insert(.folder(folder), into: nil)
            try document.insert(.request(request), into: folder.id)
        }
        return ScriptedProject(id: id, folder: folder, request: request)
    }

    func testScriptsAreWrittenBesideTheirOwnersAsTypedAndReadBack() throws {
        let scripted = try scriptedProject()
        let (id, folder, request) = (scripted.id, scripted.folder, scripted.request)

        XCTAssertEqual(try fixture.contents("project.post.js", in: id), "console.log(\"project\")\n")
        XCTAssertEqual(try fixture.contents("project.stream.js", in: id), "rq.onMessage(() => {})\n")
        XCTAssertEqual(try fixture.contents("requests/users/list-users.stream.js", in: id), "rq.onEvent(() => {})\n")
        XCTAssertFalse(fixture.exists("project.pre.js", in: id), "An empty script has no file")
        XCTAssertEqual(try fixture.contents("requests/users/_folder.pre.js", in: id), "rq.variables.set(\"folder\", 1)\n")
        let pre = try Data(contentsOf: fixture.projectURL(id).appendingPathComponent("requests/users/list-users.pre.js"))
        XCTAssertEqual(pre, Data("// pre\r\nconsole.log('é')".utf8), "Line endings and characters stay byte for byte")
        XCTAssertFalse(try fixture.contents("requests/users/list-users.json", in: id).contains("pre"))

        let relaunched = fixture.relaunched()

        XCTAssertEqual(relaunched.document(id), fixture.library.document(id))
        XCTAssertEqual(relaunched.document(id)?.folder(folder.id)?.scripts, folder.scripts)
        XCTAssertEqual(relaunched.document(id)?.request(request.id)?.scripts, request.scripts)
        XCTAssertTrue(relaunched.project(id)?.issues.isEmpty ?? false)
    }

    func testTheInheritFlagIsWrittenOnlyWhenOff() throws {
        let scripted = try scriptedProject()
        let (id, folder, request) = (scripted.id, scripted.folder, scripted.request)
        let before = try fixture.contents("requests/users/_folder.json", in: id)
        XCTAssertFalse(before.contains("inheritScripts"))

        try fixture.library.mutate(id) { document in
            try document.updateFolder(folder.id) { $0.runsInheritedScripts = false }
            try document.updateRequest(request.id) { $0.runsInheritedScripts = false }
        }

        XCTAssertTrue(try fixture.contents("requests/users/_folder.json", in: id).contains("\"inheritScripts\" : false"))
        XCTAssertTrue(try fixture.contents("requests/users/list-users.json", in: id).contains("\"inheritScripts\" : false"))
        XCTAssertEqual(fixture.relaunched().document(id)?.request(request.id)?.runsInheritedScripts, false)
    }

    func testEmptyingAScriptTrashesItsFile() throws {
        let scripted = try scriptedProject()
        let (id, folder, request) = (scripted.id, scripted.folder, scripted.request)

        try fixture.library.mutate(id) { document in
            document.scripts.postResponse = ""
            try document.updateFolder(folder.id) { $0.scripts.preRequest = "" }
            try document.updateRequest(request.id) { $0.scripts.postResponse = "" }
        }

        XCTAssertFalse(fixture.exists("project.post.js", in: id))
        XCTAssertFalse(fixture.exists("requests/users/_folder.pre.js", in: id))
        XCTAssertFalse(fixture.exists("requests/users/list-users.post.js", in: id))
        XCTAssertTrue(fixture.exists("requests/users/list-users.pre.js", in: id))
        XCTAssertEqual(fixture.trashedNames(), ["_folder.pre.js", "list-users.post.js", "project.post.js"])
    }

    func testAnEmptyScriptFileIsLeftAloneAndCanBeTypedIntoLater() throws {
        let scripted = try scriptedProject()
        let (id, request) = (scripted.id, scripted.request)
        try fixture.write("", to: "requests/users/list-users.post.js", in: id)
        fixture.library.reload(id)
        XCTAssertEqual(fixture.library.document(id)?.request(request.id)?.scripts.postResponse, "")

        try fixture.library.mutate(id) { $0.name = "Renamed" }
        XCTAssertTrue(fixture.exists("requests/users/list-users.post.js", in: id))

        try fixture.library.mutate(id) { try $0.updateRequest(request.id) { $0.scripts.postResponse = "typed" } }
        XCTAssertEqual(try fixture.contents("requests/users/list-users.post.js", in: id), "typed")
    }

    func testAnOutsideEditTheReloadHasNotSeenStopsAScriptBeingTrashed() throws {
        let scripted = try scriptedProject()
        let (id, request) = (scripted.id, scripted.request)
        try fixture.write("edited elsewhere", to: "requests/users/list-users.post.js", in: id)

        XCTAssertThrowsError(try fixture.library.mutate(id) { try $0.updateRequest(request.id) { $0.scripts.postResponse = "" } }) { error in
            XCTAssertEqual(error as? ProjectStorageError, .changedOnDisk("requests/users/list-users.post.js"))
        }
        XCTAssertEqual(try fixture.contents("requests/users/list-users.post.js", in: id), "edited elsewhere")
        XCTAssertEqual(fixture.library.document(id)?.request(request.id)?.scripts.postResponse, "edited elsewhere")
    }

    func testRenamingAndMovingCarryScriptsWithTheirOwners() throws {
        let scripted = try scriptedProject()
        let (id, folder, request) = (scripted.id, scripted.folder, scripted.request)

        try fixture.library.mutate(id) { document in
            try document.updateRequest(request.id) { $0.name = "Find users" }
            try document.updateFolder(folder.id) { $0.name = "Accounts" }
        }
        XCTAssertEqual(try fixture.contents("requests/accounts/find-users.post.js", in: id), "rq.test(\"ok\", () => {})\n")
        XCTAssertTrue(fixture.exists("requests/accounts/_folder.pre.js", in: id))
        XCTAssertFalse(fixture.exists("requests/accounts/list-users.post.js", in: id))

        try fixture.library.mutate(id) { try $0.moveNode(request.id, to: nil, at: 0) }
        XCTAssertTrue(fixture.exists("requests/find-users.pre.js", in: id))
        XCTAssertTrue(fixture.exists("requests/find-users.stream.js", in: id))
        XCTAssertTrue(fixture.exists("requests/find-users.post.js", in: id))
        XCTAssertEqual(fixture.relaunched().document(id)?.request(request.id)?.scripts, request.scripts)
        XCTAssertTrue(fixture.trashedNames().isEmpty)
    }

    /// Swapping two requests' names goes through scratch; each one's scripts must land beside its own new name.
    func testSwappingNamesKeepsEachRequestsScripts() throws {
        let id = try fixture.library.createProject(named: "Swap")
        var first = RequestItem.http("A")
        first.scripts.preRequest = "a"
        var second = RequestItem.http("B")
        second.scripts.preRequest = "b"
        try fixture.library.mutate(id) { document in
            try document.insert(.request(first), into: nil)
            try document.insert(.request(second), into: nil)
        }

        try fixture.library.mutate(id) { document in
            try document.updateRequest(first.id) { $0.name = "B" }
            try document.updateRequest(second.id) { $0.name = "A" }
        }

        XCTAssertEqual(try fixture.contents("requests/b.pre.js", in: id), "a")
        XCTAssertEqual(try fixture.contents("requests/a.pre.js", in: id), "b")
        XCTAssertFalse(fixture.exists(".reqling-sync", in: id))
    }

    func testDeletingARequestTrashesItsScriptsAndDuplicatingCopiesThem() throws {
        let scripted = try scriptedProject()
        let (id, folder, request) = (scripted.id, scripted.folder, scripted.request)

        try fixture.library.mutate(id) { document in
            try document.insert(RequestNode.request(request).copy(named: "Copy"), into: folder.id)
            try document.removeNode(request.id)
        }

        XCTAssertEqual(fixture.trashedNames(), ["list-users.json", "list-users.post.js", "list-users.pre.js", "list-users.stream.js"])
        XCTAssertEqual(try fixture.contents("requests/users/copy.post.js", in: id), "rq.test(\"ok\", () => {})\n")
        XCTAssertEqual(try fixture.contents("requests/users/copy.stream.js", in: id), "rq.onEvent(() => {})\n")
    }

    func testAnOrphanedScriptReservesItsNameAndIsLeftAlone() throws {
        let id = try fixture.library.createProject(named: "Orphans")
        try fixture.write("orphan", to: "requests/health.pre.js", in: id)
        try fixture.write("orphan", to: "requests/ping.stream.js", in: id)
        fixture.library.reload(id)

        try fixture.library.mutate(id) { document in
            try document.insert(.request(.http("Health")), into: nil)
            try document.insert(.request(.http("Ping")), into: nil)
        }

        XCTAssertTrue(fixture.exists("requests/health-2.json", in: id))
        XCTAssertTrue(fixture.exists("requests/ping-2.json", in: id))
        XCTAssertEqual(try fixture.contents("requests/health.pre.js", in: id), "orphan")
        XCTAssertEqual(fixture.library.document(id)?.items.first.flatMap { node in
            if case .request(let request) = node { return request.scripts.preRequest }
            return nil
        }, "")
    }

    func testAScriptThatIsNotUTF8IsReportedAndNeverWrittenOver() throws {
        let scripted = try scriptedProject()
        let (id, request) = (scripted.id, scripted.request)
        try Data([0xFF, 0xFE, 0x00]).write(to: fixture.projectURL(id).appendingPathComponent("requests/users/list-users.pre.js"))
        fixture.library.reload(id)

        XCTAssertTrue(fixture.library.project(id)?.issues.contains { $0.path == "requests/users/list-users.pre.js" } ?? false)
        XCTAssertEqual(fixture.library.document(id)?.request(request.id)?.scripts.preRequest, "")
        // Renaming keeps the request's own name free; the unreadable script stays behind.
        try fixture.library.mutate(id) { $0.name = "Touched" }
        XCTAssertTrue(fixture.exists("requests/users/list-users.json", in: id))
        XCTAssertThrowsError(try fixture.library.mutate(id) { try $0.updateRequest(request.id) { $0.scripts.preRequest = "new" } }) { error in
            XCTAssertEqual(error as? ProjectStorageError, .unreadableFileInTheWay("requests/users/list-users.pre.js"))
        }
    }

    func testAnOutsideScriptEditReloadsIntoTheDocument() throws {
        let scripted = try scriptedProject()
        let (id, request) = (scripted.id, scripted.request)
        try fixture.write("pulled", to: "requests/users/list-users.pre.js", in: id)
        try fixture.write("project pulled", to: "project.pre.js", in: id)

        fixture.library.reload(id)

        XCTAssertEqual(fixture.library.document(id)?.request(request.id)?.scripts.preRequest, "pulled")
        XCTAssertEqual(fixture.library.document(id)?.scripts.preRequest, "project pulled")
    }

    func testAnInterruptedSaveRecoversARequestWithItsScripts() throws {
        let id = try fixture.library.createProject(named: "Crashed")
        let stem = UUID().uuidString
        let request = RequestItem.http("Lost")
        let json = try XCTUnwrap(String(bytes: try JSONEncoder().encode(request), encoding: .utf8))
        try fixture.write(json, to: ".reqling-sync/requests/\(stem).json", in: id)
        try fixture.write("recovered", to: ".reqling-sync/requests/\(stem).post.js", in: id)

        fixture.library.reload(id)

        XCTAssertEqual(fixture.library.document(id)?.request(request.id)?.scripts.postResponse, "recovered")
    }
}
