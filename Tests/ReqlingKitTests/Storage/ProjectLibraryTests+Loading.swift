import Foundation
import Observation
import ReqlingKit
import Synchronization
import XCTest

/// Loads that must surface, recover, or keep stable what other tools and interrupted saves leave behind.
@MainActor
extension ProjectLibraryTests {
    func testItemsAnInterruptedSaveLeftInScratchAreRecoveredAndPutBack() throws {
        let id = try fixture.library.createProject(named: "Crash")
        let orphan = RequestItem.http("Orphan")
        try fixture.library.mutate(id) { try $0.insert(.request(orphan), into: nil) }
        try fixture.move("requests/orphan.json", to: ".reqling-sync/requests/\(UUID().uuidString).json", in: id)

        let relaunched = fixture.relaunched()

        XCTAssertEqual(relaunched.document(id)?.request(orphan.id)?.name, "Orphan")
        XCTAssertEqual(relaunched.project(id)?.issues.map(\.path), [".reqling-sync"])
        try relaunched.mutate(id) { $0.name = "Saved" }
        XCTAssertTrue(fixture.exists("requests/orphan.json", in: id))
        XCTAssertFalse(fixture.exists(".reqling-sync", in: id))
    }

    func testScratchEntriesThatCannotBeRecoveredAreReportedAndKept() throws {
        let id = try fixture.library.createProject(named: "Debris")
        try fixture.write("{ broken", to: ".reqling-sync/requests/\(UUID().uuidString).json", in: id)
        try fixture.write("stray", to: ".reqling-sync/stray", in: id)

        let relaunched = fixture.relaunched()
        try relaunched.mutate(id) { $0.name = "Saved" }

        XCTAssertEqual(relaunched.project(id)?.issues.count, 2)
        XCTAssertTrue(fixture.exists(".reqling-sync/stray", in: id))
    }

    func testAFolderFileThatCannotBeReadIsReportedAndNeverAdopted() throws {
        let id = try fixture.library.createProject(named: "Unreadable")
        let folder = RequestFolder(name: "Users")
        try fixture.library.mutate(id) { document in
            try document.insert(.folder(folder), into: nil)
            try document.insert(.request(.http("List")), into: folder.id)
        }
        // A directory where the file belongs fails to read without being missing, as a permission error would.
        let folderFile = fixture.projectURL(id).appendingPathComponent("requests/users/_folder.json")
        try FileManager.default.removeItem(at: folderFile)
        try FileManager.default.createDirectory(at: folderFile, withIntermediateDirectories: false)
        fixture.library.reload(id)

        XCTAssertNil(fixture.library.document(id)?.folder(folder.id))
        XCTAssertEqual(fixture.library.project(id)?.issues.map(\.path), ["requests/users/_folder.json"])
        try fixture.library.mutate(id) { try $0.insert(.folder(RequestFolder(name: "Users")), into: nil) }
        XCTAssertTrue(fixture.exists("requests/users-2/_folder.json", in: id))
        XCTAssertTrue(fixture.exists("requests/users/list.json", in: id))
    }

    func testFallbackIDsStayTheSameAcrossReloadsUntilSaved() throws {
        let id = try fixture.library.createProject(named: "Stable")
        let original = RequestItem.http("Original")
        try fixture.library.mutate(id) { try $0.insert(.request(original), into: nil) }
        try fixture.write(#"{"name": "No ID", "kind": "http"}"#, to: "requests/no-id.json", in: id)
        try fixture.write(try fixture.contents("requests/original.json", in: id), to: "requests/copy.json", in: id)
        let adopted = fixture.projectURL(id).appendingPathComponent("requests/adopted")
        try FileManager.default.createDirectory(at: adopted, withIntermediateDirectories: false)

        let first = try XCTUnwrap(fixture.relaunched().document(id))
        let second = try XCTUnwrap(fixture.relaunched().document(id))

        XCTAssertEqual(first.items.map(\.name), ["Original", "adopted", "Original", "No ID"])
        XCTAssertEqual(first.items.first?.id, original.id)
        XCTAssertEqual(first.items.map(\.id), second.items.map(\.id))
        XCTAssertEqual(Set(first.items.map(\.id)).count, 4)
        let saving = fixture.relaunched()
        try saving.mutate(id) { $0.name = "Saved" }
        XCTAssertEqual(fixture.relaunched().document(id)?.items.map(\.id), first.items.map(\.id))
    }

    /// Files written before rows carried IDs, or by hand, still load the same document every time, so the change
    /// monitor's reload of an untouched file publishes nothing and saving other changes leaves the file alone.
    func testRowsStoredWithoutIDsKeepStableIDsAcrossReloadsAndRelaunches() throws {
        let id = try fixture.library.createProject(named: "Legacy rows")
        let request = RequestNodeID()
        let json = #"""
        {"id": "\#(request)", "name": "Legacy", "kind": "http", "http": {"method": "GET", "url": "https://x",
         "queryParameters": [{"key": "q", "value": "1"}], "headers": [{"key": "A", "value": "1"}, {"key": "B", "value": "2"}]}}
        """#
        try fixture.write(json, to: "requests/legacy.json", in: id)
        fixture.library.reload(id)
        let loaded = try XCTUnwrap(fixture.library.document(id))
        let headers = try XCTUnwrap(loaded.request(request)?.kind.httpSpec?.headers)
        XCTAssertEqual(Set(headers.map(\.id)).count, 2)

        let before = fixture.library.projects
        let published = Mutex(false)
        withObservationTracking {
            _ = fixture.library.projects
        } onChange: {
            published.withLock { $0 = true }
        }
        fixture.library.reload(id)

        XCTAssertFalse(published.withLock { $0 })
        XCTAssertEqual(fixture.library.projects, before)
        XCTAssertEqual(fixture.relaunched().document(id), loaded)
        XCTAssertEqual(fixture.relaunched().document(id), fixture.relaunched().document(id))
        try fixture.library.mutate(id) { $0.name = "Renamed" }
        XCTAssertEqual(try fixture.contents("requests/legacy.json", in: id), json)
    }

    func testAFinderCopyNeverDerivesAnIDAnEarlierCopyAlreadySaved() throws {
        let id = try fixture.library.createProject(named: "Copies")
        let original = RequestItem.http("Original")
        try fixture.library.mutate(id) { try $0.insert(.request(original), into: nil) }
        let originalJSON = try fixture.contents("requests/original.json", in: id)
        try fixture.write(originalJSON, to: "requests/original copy.json", in: id)
        fixture.library.reload(id)
        // Renames the first copy to `original-2.json` and writes its derived ID into it.
        try fixture.library.mutate(id) { $0.name = "Saved" }
        XCTAssertTrue(fixture.exists("requests/original-2.json", in: id))
        try fixture.write(originalJSON, to: "requests/original copy.json", in: id)
        fixture.library.reload(id)

        let document = try XCTUnwrap(fixture.library.document(id))
        XCTAssertEqual(Set(document.items.map(\.id)).count, 3)
        XCTAssertEqual(document.items.first?.id, original.id)
        let secondCopy = try XCTUnwrap(document.items.last?.id)
        try fixture.library.mutate(id) { try $0.removeNode(secondCopy) }
        XCTAssertFalse(fixture.exists("requests/original copy.json", in: id))
        XCTAssertTrue(fixture.exists("requests/original-2.json", in: id))
        XCTAssertEqual(fixture.relaunched().document(id)?.items.count, 2)
    }

    func testACopiedEnvironmentFileNeverTakesTheOriginalsIDOrSecrets() throws {
        let id = try fixture.library.createProject(named: "Environment copies")
        let staging = RequestEnvironment(name: "Staging", variables: [Variable(key: "token", value: "s3cr3t", isSecret: true)])
        try fixture.library.mutate(id) { $0.environments.append(staging) }
        // Sorts before `staging.json`; renamed so the test can tell the two apart.
        let copy = try fixture.contents("environments/staging.json", in: id)
            .replacingOccurrences(of: #""name" : "Staging""#, with: #""name" : "Staging Copy""#)
        try fixture.write(copy, to: "environments/staging copy.json", in: id)

        fixture.library.reload(id)
        XCTAssertEqual(fixture.library.document(id)?.environment(staging.id)?.name, "Staging")
        XCTAssertEqual(fixture.relaunched().document(id)?.environment(staging.id)?.name, "Staging")

        let copyID = try XCTUnwrap(fixture.library.document(id)?.environments.first { $0.name == "Staging Copy" }?.id)
        try fixture.library.mutate(id) { $0.environments.removeAll { $0.id == copyID } }
        XCTAssertEqual(try fixture.secrets.secrets(for: id).values.sorted(), ["s3cr3t"])
        XCTAssertEqual(fixture.relaunched().document(id)?.environment(staging.id)?.variables.first?.value, "s3cr3t")
    }

    func testANumberedCopyNeverTakesTheOriginalsIDAcrossRelaunchesAndReloads() throws {
        let id = try fixture.library.createProject(named: "Numbered copies")
        let staging = RequestEnvironment(name: "Staging", variables: [Variable(key: "token", value: "s3cr3t", isSecret: true)])
        let original = RequestItem.http("Original")
        try fixture.library.mutate(id) { $0.environments.append(staging) }
        // An adopted folder lists nothing, so only the file names can tell the request copies apart.
        let requestJSON = try XCTUnwrap(String(bytes: try JSONEncoder().encode(original), encoding: .utf8))
        try fixture.write(requestJSON, to: "requests/adopted/original.json", in: id)
        // Each copy keeps a name that still slugs to the same base, as `cp` leaves it, but marked for the asserts.
        let renamedRequest = requestJSON.replacingOccurrences(of: #""Original""#, with: #""ORIGINAL""#)
        try fixture.write(renamedRequest, to: "requests/adopted/original-2.json", in: id)
        let environmentCopy = try fixture.contents("environments/staging.json", in: id)
            .replacingOccurrences(of: #""name" : "Staging""#, with: #""name" : "STAGING""#)
        try fixture.write(environmentCopy, to: "environments/staging-2.json", in: id)

        let relaunched = fixture.relaunched()
        for library in [relaunched, fixture.relaunched()] {
            XCTAssertEqual(library.document(id)?.environment(staging.id)?.name, "Staging")
            XCTAssertEqual(library.document(id)?.request(original.id)?.name, "Original")
        }
        relaunched.reload(id)
        XCTAssertEqual(relaunched.document(id)?.environment(staging.id)?.name, "Staging")
        XCTAssertEqual(relaunched.document(id)?.environment(staging.id)?.variables.first?.value, "s3cr3t")
        XCTAssertEqual(relaunched.document(id)?.request(original.id)?.name, "Original")
    }

    func testChildrenOfACopiedFolderNeverTakeTheOriginalsIDs() throws {
        let id = try fixture.library.createProject(named: "Folder copies")
        let early = RequestFolder(name: "A")
        let late = RequestFolder(name: "Z")
        let auth = RequestFolder(name: "Auth")
        let login = RequestItem.http("Login")
        try fixture.library.mutate(id) { document in
            try document.insert(.folder(early), into: nil)
            try document.insert(.folder(late), into: nil)
            try document.insert(.folder(auth), into: late.id)
            try document.insert(.request(login), into: auth.id)
        }
        let root = fixture.projectURL(id)
        try FileManager.default.copyItem(at: root.appendingPathComponent("requests/z/auth"), to: root.appendingPathComponent("requests/a/auth"))

        let relaunched = fixture.relaunched()
        for library in [relaunched, fixture.relaunched()] {
            XCTAssertEqual(library.document(id)?.ancestors(of: login.id).map(\.id), [late.id, auth.id])
            XCTAssertEqual(library.document(id)?.folder(early.id)?.children.count, 1)
        }
        relaunched.reload(id)
        XCTAssertEqual(relaunched.document(id)?.ancestors(of: login.id).map(\.id), [late.id, auth.id])
    }

    func testAnUndecodableRegistryIsBackedUpBeforeBeingReplaced() throws {
        try FileManager.default.createDirectory(at: fixture.registryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "not json".write(to: fixture.registryURL, atomically: true, encoding: .utf8)

        let relaunched = fixture.relaunched()
        try relaunched.createProject(named: "After")

        let directory = fixture.registryURL.deletingLastPathComponent()
        let backups = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasPrefix("library.corrupt-") }
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent(backups[0]), encoding: .utf8), "not json")
        XCTAssertEqual(fixture.relaunched().projects.map(\.name), ["After"])
    }
}
