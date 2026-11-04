import Foundation
import ReqlingKit
import XCTest

/// Saves that must refuse, roll back, or leave files alone rather than lose data.
@MainActor
extension ProjectLibraryTests {
    func testAnUnreadableDefaultEnvironmentBlocksSavesInsteadOfBeingReplaced() throws {
        let id = try fixture.library.createProject(named: "Conflicted")
        try fixture.library.mutate(id) { $0.defaultEnvironment.variables.append(Variable(key: "base", value: "https://api")) }
        let conflicted = "<<<<<<< HEAD\n{}\n=======\n{}\n>>>>>>> theirs\n"
        try fixture.write(conflicted, to: "environments/default.json", in: id)
        fixture.library.reload(id)

        XCTAssertThrowsError(try fixture.library.mutate(id) { $0.name = "Renamed" }) { error in
            XCTAssertEqual(error as? ProjectStorageError, .unreadableFileInTheWay("environments/default.json"))
        }
        XCTAssertEqual(try fixture.contents("environments/default.json", in: id), conflicted)
    }

    func testSecretsOfADeletedEnvironmentSurviveASaveThatFails() throws {
        let id = try fixture.library.createProject(named: "Vault")
        let staging = RequestEnvironment(name: "Staging", variables: [Variable(key: "token", value: "s3cr3t", isSecret: true)])
        try fixture.library.mutate(id) { $0.environments.append(staging) }
        fixture.trash.isFailing = true

        XCTAssertThrowsError(try fixture.library.mutate(id) { $0.environments.removeAll() })
        XCTAssertEqual(try fixture.secrets.secrets(for: id).values.sorted(), ["s3cr3t"])
        XCTAssertEqual(fixture.library.document(id)?.environments.first?.variables.first?.value, "s3cr3t")

        fixture.trash.isFailing = false
        try fixture.library.mutate(id) { $0.environments.removeAll() }
        XCTAssertTrue(try fixture.secrets.secrets(for: id).isEmpty)
    }

    func testAFailedSaveMovesLiftedItemsBackWhereTheyCameFrom() throws {
        let id = try fixture.library.createProject(named: "Rollback")
        let folder = RequestFolder(name: "Accounts")
        let child = RequestItem.http("List")
        let doomed = RequestItem.http("Doomed")
        try fixture.library.mutate(id) { document in
            try document.insert(.folder(folder), into: nil)
            try document.insert(.request(child), into: folder.id)
            try document.insert(.request(doomed), into: nil)
        }
        fixture.trash.isFailing = true

        XCTAssertThrowsError(try fixture.library.mutate(id) { document in
            try document.updateFolder(folder.id) { $0.name = "Billing" }
            try document.updateRequest(child.id) { $0.name = "Listing" }
            try document.removeNode(doomed.id)
        })

        XCTAssertTrue(fixture.exists("requests/accounts/list.json", in: id))
        XCTAssertTrue(fixture.exists("requests/doomed.json", in: id))
        XCTAssertFalse(fixture.exists(".reqling-sync", in: id))
        XCTAssertEqual(fixture.library.document(id)?.folder(folder.id)?.children.map(\.name), ["List"])
    }

    func testUnreadableEntriesMoveWithTheirFolderAndKeepTheirNames() throws {
        let id = try fixture.library.createProject(named: "Travel")
        let accounts = RequestFolder(name: "Accounts")
        let users = RequestFolder(name: "Users")
        try fixture.library.mutate(id) { document in
            try document.insert(.folder(accounts), into: nil)
            try document.insert(.folder(users), into: nil)
        }
        try fixture.write("{ broken", to: "requests/accounts/health.json", in: id)
        try fixture.write("{ broken", to: "requests/users/ping.json", in: id)
        fixture.library.reload(id)

        // Across two saves with no reload between them, as when the change monitor has not caught up yet.
        try fixture.library.mutate(id) { try $0.updateFolder(accounts.id) { $0.name = "Billing" } }
        try fixture.library.mutate(id) { try $0.insert(.request(.http("Health")), into: accounts.id) }
        // Within one save.
        try fixture.library.mutate(id) { document in
            try document.updateFolder(users.id) { $0.name = "People" }
            try document.insert(.request(.http("Ping")), into: users.id)
        }

        XCTAssertEqual(try fixture.contents("requests/billing/health.json", in: id), "{ broken")
        XCTAssertTrue(fixture.exists("requests/billing/health-2.json", in: id))
        XCTAssertEqual(try fixture.contents("requests/people/ping.json", in: id), "{ broken")
        XCTAssertTrue(fixture.exists("requests/people/ping-2.json", in: id))
    }

    func testUnreadableItemsKeepTheirPlaceSoTheParentFileIsNotRewritten() throws {
        let id = try fixture.library.createProject(named: "Places")
        let first = RequestItem.http("Alpha")
        try fixture.library.mutate(id) { document in
            for request in [first, .http("Health"), .http("Omega")] {
                try document.insert(.request(request), into: nil)
            }
        }
        try fixture.write("{ broken", to: "requests/health.json", in: id)
        fixture.library.reload(id)
        let projectFile = try fixture.contents("project.json", in: id)

        try fixture.library.mutate(id) { try $0.updateRequest(first.id) { $0.kind = .http(HTTPRequestSpec(url: "https://changed")) } }

        XCTAssertEqual(try fixture.contents("project.json", in: id), projectFile)
    }

    func testANewFilesTakenPathRefusesTheSaveBeforeAnythingMoves() throws {
        let id = try fixture.library.createProject(named: "Taken")
        let old = RequestItem.http("Old")
        let health = RequestItem.http("Health")
        try fixture.library.mutate(id) { document in
            try document.insert(.request(old), into: nil)
            try document.insert(.request(health), into: nil)
        }
        // Another tool adds a file the change monitor has not reported yet.
        try fixture.write("{}", to: "requests/new.json", in: id)

        XCTAssertThrowsError(try fixture.library.mutate(id) { document in
            try document.updateRequest(old.id) { $0.name = "Older" }
            try document.insert(.request(.http("New")), into: nil)
        }) { error in
            XCTAssertEqual(error as? ProjectStorageError, .changedOnDisk("requests/new.json"))
        }
        XCTAssertTrue(fixture.exists("requests/old.json", in: id))
        XCTAssertEqual(try fixture.contents("requests/new.json", in: id), "{}")

        // A path this save vacates is free for a new file.
        try fixture.library.mutate(id) { document in
            try document.removeNode(health.id)
            try document.insert(.request(.http("Health")), into: nil)
        }
        XCTAssertTrue(fixture.exists("requests/health.json", in: id))
    }

    func testUnreadableFilesReserveTheirNamesCaseInsensitively() throws {
        let id = try fixture.library.createProject(named: "Case")
        try fixture.write("{ broken", to: "requests/Health.JSON", in: id)
        fixture.library.reload(id)

        try fixture.library.mutate(id) { try $0.insert(.request(.http("Health")), into: nil) }

        XCTAssertEqual(try fixture.contents("requests/Health.JSON", in: id), "{ broken")
        XCTAssertTrue(fixture.exists("requests/health-2.json", in: id))
    }

    func testUntouchedHandFormattedFilesKeepTheirBytes() throws {
        let id = try fixture.library.createProject(named: "Formatting")
        let request = RequestItem.http("Compact")
        try fixture.library.mutate(id) { try $0.insert(.request(request), into: nil) }
        let compact = #"{"id":"\#(request.id)","name":"Compact","kind":"http","http":{"method":"GET","url":"https://example.com"},"note":"x"}"#
        try fixture.write(compact, to: "requests/compact.json", in: id)
        fixture.library.reload(id)

        try fixture.library.mutate(id) { try $0.insert(.request(.http("Other")), into: nil) }

        XCTAssertEqual(try fixture.contents("requests/compact.json", in: id), compact)
    }

    func testAnExternalEditTheReloadHasNotSeenAbortsTheSave() throws {
        let id = try fixture.library.createProject(named: "Race")
        let request = RequestItem.http("Ping", url: "https://before")
        try fixture.library.mutate(id) { try $0.insert(.request(request), into: nil) }
        let edited = try fixture.contents("requests/ping.json", in: id).replacingOccurrences(of: "https://before", with: "https://external")
        try fixture.write(edited, to: "requests/ping.json", in: id)

        XCTAssertThrowsError(try fixture.library.mutate(id) { try $0.updateRequest(request.id) { $0.name = "Pong" } }) { error in
            XCTAssertEqual(error as? ProjectStorageError, .changedOnDisk("requests/ping.json"))
        }

        XCTAssertEqual(try fixture.contents("requests/ping.json", in: id), edited)
        XCTAssertEqual(fixture.library.document(id)?.request(request.id)?.kind.httpSpec?.url, "https://external")
    }

    func testAPassphraseReadFailureIsReportedAndNeverClearsTheStoredValue() throws {
        let id = try fixture.library.createProject(named: "Certificates")
        let entry = CertificateEntryID()
        try fixture.library.setCertificatePassphrase("hunter2", for: entry, in: id)
        let lockedStore = LockableSecretStore(wrapping: fixture.secrets)
        let locked = fixture.relaunched(secretStore: lockedStore)

        XCTAssertThrowsError(try locked.loadCertificatePassphrase(for: entry, in: id))
        XCTAssertNil(locked.certificatePassphrase(for: entry, in: id))

        lockedStore.isLocked = false
        try locked.updateCertificatePassphrases([CertificateEntryID(): "other"], in: id)
        XCTAssertEqual(try locked.loadCertificatePassphrase(for: entry, in: id), "hunter2")
        try locked.updateCertificatePassphrases([entry: nil], in: id)
        XCTAssertNil(try locked.loadCertificatePassphrase(for: entry, in: id))
    }
}
