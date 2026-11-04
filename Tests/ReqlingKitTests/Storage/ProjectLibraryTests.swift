import Foundation
import ReqlingKit
import XCTest

@MainActor
final class ProjectLibraryTests: XCTestCase {
    var fixture: LibraryFixture!

    override func setUp() async throws {
        fixture = try LibraryFixture()
    }

    override func tearDown() async throws {
        fixture.directory.remove()
        fixture = nil
    }

    func testCreatingAProjectWritesTheLayoutWithADefaultEnvironment() throws {
        let id = try fixture.library.createProject(named: "My API")

        XCTAssertEqual(fixture.projectURL(id).lastPathComponent, "My API.reqling")
        XCTAssertTrue(fixture.exists("project.json", in: id))
        XCTAssertTrue(fixture.exists("environments/default.json", in: id))
        XCTAssertTrue(fixture.exists("requests", in: id))
        XCTAssertEqual(fixture.library.document(id)?.defaultEnvironment.name, "Default")
    }

    func testCreatingASecondProjectWithTheSameNamePicksANewFolder() throws {
        let first = try fixture.library.createProject(named: "API")
        let second = try fixture.library.createProject(named: "API")

        XCTAssertEqual(fixture.projectURL(first).lastPathComponent, "API.reqling")
        XCTAssertEqual(fixture.projectURL(second).lastPathComponent, "API 2.reqling")
    }

    func testDocumentsRoundTripThroughDiskAcrossARelaunch() throws {
        let id = try fixture.library.createProject(named: "Round Trip")
        let request = RequestItem(name: "Create user", kind: .http(HTTPRequestSpec(
            method: .post,
            url: "{{baseUrl}}/users",
            queryParameters: [KeyValuePair(key: "verbose", value: "1", isEnabled: false)],
            headers: [KeyValuePair(key: "X-Trace", value: "{{$uuid}}")],
            body: .raw(#"{"name": "{{name}}"}"#),
            auth: .bearer(token: "{{token}}"),
            options: HTTPRequestOptions(timeoutSeconds: 5)
        )))
        try fixture.library.mutate(id) { document in
            try document.insert(.folder(RequestFolder(name: "Users", auth: .basic(username: "u", password: "p"))), into: nil)
            let folderID = document.items[0].id
            try document.insert(.request(request), into: folderID)
            try document.insert(.request(.http("Health")), into: nil)
            document.environments.append(RequestEnvironment(name: "Staging", variables: [Variable(key: "baseUrl", value: "https://staging")]))
            document.defaultEnvironment.variables.append(Variable(key: "name", value: "Ada"))
        }

        let relaunched = fixture.relaunched()

        XCTAssertEqual(relaunched.document(id), fixture.library.document(id))
        XCTAssertTrue(fixture.exists("requests/users/_folder.json", in: id))
        XCTAssertTrue(fixture.exists("requests/users/create-user.json", in: id))
        XCTAssertTrue(fixture.exists("requests/health.json", in: id))
        XCTAssertTrue(fixture.exists("environments/staging.json", in: id))
    }

    func testRenamingARequestMovesItsFileAndLeavesSiblingsUntouched() throws {
        let id = try fixture.library.createProject(named: "Renames")
        let request = RequestItem.http("Old name")
        try fixture.library.mutate(id) { document in
            try document.insert(.request(request), into: nil)
            try document.insert(.request(.http("Sibling")), into: nil)
        }
        let siblingURL = fixture.projectURL(id).appendingPathComponent("requests/sibling.json")
        let siblingDate = try siblingURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate

        try fixture.library.mutate(id) { document in
            try document.updateRequest(request.id) { $0.name = "New name" }
        }

        XCTAssertFalse(fixture.exists("requests/old-name.json", in: id))
        XCTAssertTrue(try fixture.contents("requests/new-name.json", in: id).contains(#""name" : "New name""#))
        let newSiblingDate = try siblingURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        XCTAssertEqual(siblingDate, newSiblingDate)
    }

    func testRenamingAFolderMovesItsContentsWithIt() throws {
        let id = try fixture.library.createProject(named: "Folders")
        let folder = RequestFolder(name: "Accounts")
        try fixture.library.mutate(id) { document in
            try document.insert(.folder(folder), into: nil)
            try document.insert(.request(.http("List")), into: folder.id)
        }

        try fixture.library.mutate(id) { document in
            try document.updateFolder(folder.id) { $0.name = "Billing" }
        }

        XCTAssertFalse(fixture.exists("requests/accounts", in: id))
        XCTAssertTrue(fixture.exists("requests/billing/list.json", in: id))
        XCTAssertEqual(fixture.relaunched().document(id), fixture.library.document(id))
    }

    func testSwappingTwoSiblingNamesInOneSave() throws {
        let id = try fixture.library.createProject(named: "Swap")
        let first = RequestItem.http("Alpha", url: "https://alpha")
        let second = RequestItem.http("Beta", url: "https://beta")
        try fixture.library.mutate(id) { document in
            try document.insert(.request(first), into: nil)
            try document.insert(.request(second), into: nil)
        }

        try fixture.library.mutate(id) { document in
            try document.updateRequest(first.id) { $0.name = "Beta" }
            try document.updateRequest(second.id) { $0.name = "Alpha" }
        }

        XCTAssertTrue(try fixture.contents("requests/alpha.json", in: id).contains("https://beta"))
        XCTAssertTrue(try fixture.contents("requests/beta.json", in: id).contains("https://alpha"))
        XCTAssertFalse(fixture.exists(".reqling-sync", in: id))
        XCTAssertEqual(fixture.relaunched().document(id), fixture.library.document(id))
    }

    func testMovingARequestOutOfAFolderDeletedInTheSameSaveKeepsTheRequest() throws {
        let id = try fixture.library.createProject(named: "Rescue")
        let folder = RequestFolder(name: "Doomed")
        let survivor = RequestItem.http("Survivor")
        try fixture.library.mutate(id) { document in
            try document.insert(.folder(folder), into: nil)
            try document.insert(.request(survivor), into: folder.id)
            try document.insert(.request(.http("Casualty")), into: folder.id)
        }

        try fixture.library.mutate(id) { document in
            try document.moveNode(survivor.id, to: nil)
            try document.removeNode(folder.id)
        }

        XCTAssertTrue(fixture.exists("requests/survivor.json", in: id))
        XCTAssertFalse(fixture.exists("requests/doomed", in: id))
        XCTAssertEqual(fixture.trashedNames(), ["doomed"])
        XCTAssertEqual(fixture.relaunched().document(id)?.items.map(\.name), ["Survivor"])
    }

    func testDuplicateNamesGetNumberedSlugsThatStayPutWhenTheFirstIsDeleted() throws {
        let id = try fixture.library.createProject(named: "Slugs")
        let first = RequestItem.http("Get user", url: "https://one")
        let second = RequestItem.http("Get user", url: "https://two")
        try fixture.library.mutate(id) { document in
            try document.insert(.request(first), into: nil)
            try document.insert(.request(second), into: nil)
        }
        XCTAssertTrue(fixture.exists("requests/get-user.json", in: id))
        XCTAssertTrue(fixture.exists("requests/get-user-2.json", in: id))

        try fixture.library.mutate(id) { document in
            try document.removeNode(first.id)
        }

        XCTAssertFalse(fixture.exists("requests/get-user.json", in: id))
        XCTAssertTrue(try fixture.contents("requests/get-user-2.json", in: id).contains("https://two"))
        XCTAssertEqual(fixture.trashedNames(), ["get-user.json"])
    }

    func testOrderSurvivesARelaunch() throws {
        let id = try fixture.library.createProject(named: "Order")
        try fixture.library.mutate(id) { document in
            for name in ["Zeta", "Alpha", "Mu"] {
                try document.insert(.request(.http(name)), into: nil)
            }
        }

        XCTAssertEqual(fixture.relaunched().document(id)?.items.map(\.name), ["Zeta", "Alpha", "Mu"])
    }

    func testEnvironmentsRenameTheirFilesAndNeverClaimTheDefaultName() throws {
        let id = try fixture.library.createProject(named: "Envs")
        let environment = RequestEnvironment(name: "Default")
        try fixture.library.mutate(id) { $0.environments.append(environment) }
        XCTAssertTrue(fixture.exists("environments/default-2.json", in: id))

        try fixture.library.mutate(id) { document in
            document.updateEnvironment(environment.id) { $0.name = "Production" }
        }

        XCTAssertFalse(fixture.exists("environments/default-2.json", in: id))
        XCTAssertTrue(fixture.exists("environments/production.json", in: id))
        XCTAssertEqual(fixture.relaunched().document(id)?.allEnvironments.map(\.name), ["Default", "Production"])
    }

    func testAnUnchangedMutationWritesNothing() throws {
        let id = try fixture.library.createProject(named: "Quiet")
        let projectFile = fixture.projectURL(id).appendingPathComponent("project.json")
        try FileManager.default.removeItem(at: projectFile)

        try fixture.library.mutate(id) { _ in }

        XCTAssertFalse(FileManager.default.fileExists(atPath: projectFile.path))
    }

    func testSecretValuesStayOutOfProjectFiles() throws {
        let id = try fixture.library.createProject(named: "Secrets")
        try fixture.library.mutate(id) { document in
            document.defaultEnvironment.variables.append(Variable(key: "token", value: "s3cr3t", isSecret: true))
        }

        let json = try fixture.contents("environments/default.json", in: id)
        XCTAssertFalse(json.contains("s3cr3t"))
        XCTAssertTrue(json.contains(#""secret" : true"#))
        XCTAssertEqual(fixture.relaunched().document(id)?.defaultEnvironment.variables.first?.value, "s3cr3t")
    }

    func testUntouchedSecretsSurviveASaveWhenTheKeychainCouldNotBeReadAtLoad() throws {
        let id = try fixture.library.createProject(named: "Locked")
        let secret = Variable(key: "token", value: "s3cr3t", isSecret: true)
        try fixture.library.mutate(id) { $0.defaultEnvironment.variables.append(secret) }
        let lockedStore = LockableSecretStore(wrapping: fixture.secrets)
        let locked = fixture.relaunched(secretStore: lockedStore)
        XCTAssertEqual(locked.document(id)?.defaultEnvironment.variables.first?.value, "")
        XCTAssertEqual(locked.project(id)?.issues.map(\.message), ["Secret values could not be read from the Keychain."])
        lockedStore.isLocked = false

        try locked.mutate(id) { $0.name = "Renamed" }
        XCTAssertEqual(try fixture.secrets.secrets(for: id).values.sorted(), ["s3cr3t"])

        try locked.mutate(id) { $0.defaultEnvironment.variables[0].value = "rotated" }
        XCTAssertEqual(try fixture.secrets.secrets(for: id).values.sorted(), ["rotated"])
    }

    func testAProjectFromANewerFormatIsReadOnly() throws {
        let id = try fixture.library.createProject(named: "Future")
        let projectFile = fixture.projectURL(id).appendingPathComponent("project.json")
        let json = try String(contentsOf: projectFile, encoding: .utf8)
            .replacingOccurrences(of: #""formatVersion" : 1"#, with: #""formatVersion" : 99"#)
        try json.write(to: projectFile, atomically: true, encoding: .utf8)
        fixture.library.reload(id)

        XCTAssertTrue(fixture.library.project(id)!.isReadOnly)
        XCTAssertThrowsError(try fixture.library.mutate(id) { $0.name = "Nope" }) { error in
            XCTAssertEqual(error as? ProjectStorageError, .readOnly)
        }
    }

    func testAnUnreadableRequestFileIsReportedAndNeverOverwritten() throws {
        let id = try fixture.library.createProject(named: "Broken")
        let broken = fixture.projectURL(id).appendingPathComponent("requests/health.json")
        try "{ not json".write(to: broken, atomically: true, encoding: .utf8)
        fixture.library.reload(id)
        XCTAssertEqual(fixture.library.project(id)?.issues.map(\.path), ["requests/health.json"])

        try fixture.library.mutate(id) { try $0.insert(.request(.http("Health")), into: nil) }

        XCTAssertEqual(try String(contentsOf: broken, encoding: .utf8), "{ not json")
        XCTAssertTrue(fixture.exists("requests/health-2.json", in: id))
    }

    func testReloadPicksUpAnExternalEditButIgnoresItsOwnWrites() throws {
        let id = try fixture.library.createProject(named: "External")
        let request = RequestItem.http("Ping", url: "https://before")
        try fixture.library.mutate(id) { try $0.insert(.request(request), into: nil) }
        let before = fixture.library.projects

        fixture.library.reload(id)
        XCTAssertEqual(fixture.library.projects, before)

        let file = fixture.projectURL(id).appendingPathComponent("requests/ping.json")
        let edited = try String(contentsOf: file, encoding: .utf8).replacingOccurrences(of: "https://before", with: "https://after")
        try edited.write(to: file, atomically: true, encoding: .utf8)
        fixture.library.reload(id)

        XCTAssertEqual(fixture.library.document(id)?.request(request.id)?.kind.httpSpec?.url, "https://after")
    }

    func testRemovingKeepsTheFolderWhileDeletingTrashesIt() throws {
        let kept = try fixture.library.createProject(named: "Kept")
        let deleted = try fixture.library.createProject(named: "Deleted")
        let keptURL = fixture.projectURL(kept)

        fixture.library.removeProject(kept)
        try fixture.library.deleteProject(deleted)

        XCTAssertTrue(FileManager.default.fileExists(atPath: keptURL.path))
        XCTAssertEqual(fixture.trashedNames(), ["Deleted.reqling"])
        XCTAssertTrue(fixture.library.projects.isEmpty)
        XCTAssertTrue(fixture.relaunched().projects.isEmpty)

        XCTAssertEqual(try fixture.library.addProjectFolder(keptURL), kept)
        XCTAssertThrowsError(try fixture.library.addProjectFolder(keptURL))
    }

    func testAMissingFolderLoadsAsUnavailable() throws {
        let id = try fixture.library.createProject(named: "Gone")
        try FileManager.default.removeItem(at: fixture.projectURL(id))

        let project = fixture.relaunched().project(id)

        XCTAssertNil(project?.document)
        XCTAssertEqual(project?.name, "Gone")
    }
}
