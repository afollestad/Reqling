import Foundation
@testable import ReqlingKit
import ReqlingTemplating
import XCTest

/// The library's sync seams: every change made on this Mac reaches the observer, and nothing a sync applies does, so
/// applying a change never sends it back.
extension ProjectLibraryTests {
    func testEveryChangeMadeOnThisMacReachesTheObserver() throws {
        var changes: [LibraryChange] = []
        fixture.library.changeObserver = { changes.append($0) }

        let id = try fixture.library.createProject(named: "API")
        try fixture.library.mutate(id) { $0.name = "Renamed" }
        try fixture.library.mutateGlobalEnvironment { $0.variables = [Variable(key: "host", value: "a")] }
        fixture.library.currentValues.apply(["token": .value(TemplateVariable(value: "t"))], in: .global)
        try fixture.write(#"{"id": "\#(id)", "name": "Edited outside", "formatVersion": 1}"#, to: "project.json", in: id)
        fixture.library.reload(id)
        fixture.library.reload(id)
        let other = try fixture.library.createProject(named: "Other")
        fixture.library.removeProject(other)
        try fixture.library.deleteProject(id)

        XCTAssertEqual(changes, [
            .project(id), .project(id), .global, .currentValues, .project(id),
            .project(other), .removed(other), .deleted(id)
        ], "A reload that changes nothing reports nothing")
    }

    /// Another Mac's change is written with exactly the secrets that came with it; secrets it removed stay in the
    /// Keychain for Put Back, current values stay, and the observer hears nothing.
    func testApplyingASyncedChangeKeepsSecretsAndCurrentValuesAndTellsNoOne() throws {
        let id = try fixture.library.createProject(named: "API")
        let token = Variable(key: "token", value: "old", isSecret: true)
        let defaultID = try XCTUnwrap(fixture.library.document(id)).defaultEnvironment.id
        try fixture.library.mutate(id) { $0.defaultEnvironment.variables = [token] }
        fixture.library.currentValues.apply(["token": .value(TemplateVariable(value: "current"))], in: .environment(id, defaultID))
        var changes: [LibraryChange] = []
        fixture.library.changeObserver = { changes.append($0) }

        var synced = try XCTUnwrap(fixture.library.document(id))
        synced.name = "From another Mac"
        synced.defaultEnvironment.variables = [Variable(key: "key", value: "new", isSecret: true)]
        try fixture.library.applySynced(synced, storingSecrets: [
            SecretKey.variable(synced.defaultEnvironment.variables[0].id, in: defaultID): "new"
        ])

        XCTAssertEqual(fixture.library.document(id)?.name, "From another Mac")
        XCTAssertEqual(fixture.relaunched().document(id)?.defaultEnvironment.variables.first?.value, "new")
        let stored = try fixture.secrets.secrets(for: .project(id))
        XCTAssertEqual(stored[SecretKey.variable(token.id, in: defaultID)], "old", "A removed secret stays for Put Back")
        XCTAssertEqual(fixture.library.currentValues.values(in: .environment(id, defaultID))["token"], .value(TemplateVariable(value: "current")))
        XCTAssertEqual(changes, [])
    }

    func testAdoptingASyncedProjectWritesItsFolderOrReusesAnUnlistedOne() throws {
        var document = ProjectDocument(name: "Shared")
        let secret = Variable(key: "token", value: "s3cret", isSecret: true)
        document.defaultEnvironment.variables = [secret]
        let key = SecretKey.variable(secret.id, in: document.defaultEnvironment.id)
        var changes: [LibraryChange] = []
        fixture.library.changeObserver = { changes.append($0) }

        try fixture.library.adoptSyncedProject(document, storingSecrets: [key: "s3cret"])

        XCTAssertEqual(fixture.projectURL(document.id).lastPathComponent, "Shared.reqling")
        XCTAssertEqual(fixture.relaunched().document(document.id)?.defaultEnvironment.variables.first?.value, "s3cret")
        XCTAssertFalse(try fixture.contents("environments/default.json", in: document.id).contains("s3cret"))
        XCTAssertEqual(changes, [])

        // A library list that loses the project leaves its folder unlisted; adopting it again finds that folder.
        fixture.library.removeProject(document.id)
        document.name = "Shared, renamed"
        try fixture.library.adoptSyncedProject(document, storingSecrets: [:])

        XCTAssertEqual(fixture.projectURL(document.id).lastPathComponent, "Shared.reqling")
        XCTAssertEqual(fixture.library.document(document.id)?.name, "Shared, renamed")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.file("Projects").path), ["Shared.reqling"])
    }

    /// A Keychain that refuses the secrets leaves no folder behind, so the next attempt starts clean.
    func testAdoptingWithoutAWritableKeychainLeavesNoFolder() throws {
        var document = ProjectDocument(name: "Shared")
        document.defaultEnvironment.variables = [Variable(key: "token", value: "s3cret", isSecret: true)]
        fixture.secrets.isFailingWrites = true

        XCTAssertThrowsError(try fixture.library.adoptSyncedProject(document, storingSecrets: ["k": "s3cret"]))

        XCTAssertNil(fixture.library.project(document.id))
        XCTAssertEqual(fixture.trashedNames(), ["Shared.reqling"])
    }

    func testAProjectAnotherMacDeletedGoesToTheTrashWithItsSecretsKept() throws {
        let id = try fixture.library.createProject(named: "API")
        try fixture.library.mutate(id) { $0.defaultEnvironment.variables = [Variable(key: "token", value: "s3cret", isSecret: true)] }

        try fixture.library.deleteSyncedProject(id)

        XCTAssertNil(fixture.library.project(id))
        XCTAssertEqual(fixture.trashedNames(), ["API.reqling"])
        XCTAssertEqual(try fixture.secrets.secrets(for: .project(id)).values.sorted(), ["s3cret"])
    }

    func testApplyingASyncedGlobalKeepsItsRemovedSecretsAndTellsNoOne() throws {
        let old = Variable(key: "old", value: "gone", isSecret: true)
        try fixture.library.mutateGlobalEnvironment { $0.variables = [old] }
        var changes: [LibraryChange] = []
        fixture.library.changeObserver = { changes.append($0) }
        let new = Variable(key: "new", value: "fresh", isSecret: true)

        try fixture.library.applySyncedGlobalEnvironment(
            [new],
            storingSecrets: [SecretKey.variable(new.id, in: RequestEnvironment.globalID): "fresh"]
        )

        XCTAssertEqual(fixture.relaunched().globalEnvironment.variables.map(\.value), ["fresh"])
        XCTAssertEqual(try fixture.secrets.secrets(for: .global).count, 2)
        XCTAssertEqual(changes, [])
    }

    /// The reader derives an ID for a file that states none; stating it keeps it stable through a rename on another Mac.
    func testPersistingSettledIDsWritesTheIDsTheReaderDerived() throws {
        let id = try fixture.library.createProject(named: "API")
        try fixture.write(#"{"name": "Hand made", "http": {"method": "GET", "url": "https://api"}}"#, to: "requests/hand-made.json", in: id)
        fixture.library.reload(id)
        let derived = try XCTUnwrap(fixture.library.document(id)?.items.first?.id)

        try fixture.library.persistSettledIDs(id)

        XCTAssertTrue(try fixture.contents("requests/hand-made.json", in: id).contains(derived.description))
    }
}
