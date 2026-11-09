import Foundation
@testable import ReqlingKit
import ReqlingTemplating
import XCTest

/// Two Macs syncing through one in-memory iCloud database.
@MainActor
final class LibrarySyncTests: XCTestCase {
    var cloud: SyncTestCloud!
    var macA: SyncTestMac!
    var macB: SyncTestMac!

    override func setUp() async throws {
        cloud = SyncTestCloud()
        macA = try SyncTestMac(cloud: cloud)
        macB = try SyncTestMac(cloud: cloud)
        await macA.sync.start()
        await macB.sync.start()
    }

    override func tearDown() async throws {
        macA.cleanUp()
        macB.cleanUp()
    }

    /// A project on Mac A with a secret variable and a request inside a folder, synced to Mac B.
    @discardableResult
    func shareProject(_ name: String = "API") async throws -> ProjectID {
        let id = try macA.lifecycle.createProject(named: name)
        try macA.library.mutate(id) { document in
            document.defaultEnvironment.variables = [
                Variable(key: "baseUrl", value: "https://api"),
                Variable(key: "token", value: "s3cret", isSecret: true)
            ]
            let request = RequestItem(name: "List users", kind: .http(HTTPRequestSpec(url: "{{baseUrl}}/users")))
            document.items = [.folder(RequestFolder(name: "Users", children: [.request(request)]))]
        }
        await macA.sync.syncNow()
        await macB.sync.syncNow()
        return id
    }

    func request(in mac: SyncTestMac, _ project: ProjectID) -> RequestItem? {
        mac.library.document(project)?.allRequests.first?.0
    }

    // MARK: - Arriving

    func testAProjectArrivesOnTheOtherMacWithItsSecretsInItsKeychain() async throws {
        let id = try await shareProject()

        let arrived = try XCTUnwrap(macB.library.project(id))
        XCTAssertEqual(arrived.url.lastPathComponent, "API.reqling")
        XCTAssertEqual(arrived.document, macA.library.document(id))
        XCTAssertEqual(try macB.storage.secrets.secrets(for: .project(id)).values.sorted(), ["s3cret"])
        XCTAssertFalse(try macB.storage.contents("environments/default.json", in: id).contains("s3cret"))
        XCTAssertEqual(macB.workspace.projectState(id).scriptTrust, .unknown, "Another Mac's project asks before its scripts run")
        XCTAssertEqual(macB.sync.status, .upToDate(macB.clock))
    }

    /// A Keychain that refuses the secrets leaves no project behind; the next start fetches it all again.
    func testAProjectThatCantStoreItsSecretsArrivesOnlyOnceTheKeychainWorks() async throws {
        macB.storage.secrets.isFailingWrites = true
        let id = try await shareProject()

        XCTAssertNil(macB.library.project(id))
        XCTAssertFalse(macB.sync.issues.isEmpty)

        macB.storage.secrets.isFailingWrites = false
        macB.sync.stop()
        await macB.sync.start()

        XCTAssertEqual(macB.library.document(id), macA.library.document(id))
    }

    // MARK: - Merging

    func testEditsToDifferentFieldsOnTwoMacsBothSurvive() async throws {
        let id = try await shareProject()
        let requestID = try XCTUnwrap(request(in: macA, id)).id

        macA.tick()
        try macA.library.mutate(id) { try $0.updateNode(requestID) { node in
            if case .request(var request) = node, case .http(var spec) = request.kind {
                spec.url = "{{baseUrl}}/people"
                request.kind = .http(spec)
                node = .request(request)
            }
        } }
        macB.tick(2)
        try macB.library.mutate(id) { try $0.updateNode(requestID) { $0.name = "List people" } }
        await macA.sync.syncNow()
        await macB.sync.syncNow()
        await macA.sync.syncNow()

        for mac in [macA!, macB!] {
            XCTAssertEqual(request(in: mac, id)?.name, "List people")
            XCTAssertEqual(request(in: mac, id)?.kind.httpSpec?.url, "{{baseUrl}}/people")
        }
    }

    func testTheLaterEditWinsAFieldBothMacsChanged() async throws {
        let id = try await shareProject()

        macA.tick()
        try macA.library.mutate(id) { $0.name = "From A" }
        macB.tick(5)
        try macB.library.mutate(id) { $0.name = "From B" }
        await macA.sync.syncNow()
        await macB.sync.syncNow()
        await macA.sync.syncNow()

        XCTAssertEqual(macA.library.document(id)?.name, "From B")
        XCTAssertEqual(macB.library.document(id)?.name, "From B")
    }

    func testTheEarlierEditLosesEvenWhenItSyncsLast() async throws {
        let id = try await shareProject()

        macB.tick()
        try macB.library.mutate(id) { $0.name = "From B, earlier" }
        macA.tick(5)
        try macA.library.mutate(id) { $0.name = "From A, later" }
        await macA.sync.syncNow()
        await macB.sync.syncNow()
        await macA.sync.syncNow()

        XCTAssertEqual(macA.library.document(id)?.name, "From A, later")
        XCTAssertEqual(macB.library.document(id)?.name, "From A, later")
    }

    /// Mac B deleted a request without syncing while Mac A edited it: the edit beats the deletion on both Macs.
    func testAnEditElsewhereBeatsADeletionNotYetSent() async throws {
        let id = try await shareProject()
        let requestID = try XCTUnwrap(request(in: macA, id)).id

        try macB.library.mutate(id) { _ = try $0.removeNode(requestID) }
        try macA.library.mutate(id) { try $0.updateNode(requestID) { $0.name = "Kept" } }
        await macA.sync.syncNow()
        await macB.sync.syncNow()
        await macA.sync.syncNow()

        XCTAssertEqual(macB.library.document(id)?.request(requestID)?.name, "Kept")
        XCTAssertEqual(macA.library.document(id)?.request(requestID)?.name, "Kept")
        XCTAssertNotNil(cloud.record(SyncRecordID(zone: .project(id), name: requestID.description)))
    }

    /// Without its digest key, Mac B's bases match nothing; it starts over rather than letting its stale copy win.
    func testALostDigestKeyStartsOverWithoutOverwritingNewerChanges() async throws {
        let id = try await shareProject()

        macB.sync.stop()
        macA.tick()
        try macA.library.mutate(id) { $0.name = "Newer, from A" }
        await macA.sync.syncNow()
        try macB.storage.secrets.setSecrets([:], for: .sync)
        macB.tick(10)
        await macB.sync.start()
        await macA.sync.syncNow()

        XCTAssertEqual(macB.library.document(id)?.name, "Newer, from A")
        XCTAssertEqual(macA.library.document(id)?.name, "Newer, from A")
    }

    func testAnEditMadeWhileReqlingWasClosedSyncsOnTheNextStart() async throws {
        let id = try await shareProject()

        macA.sync.stop()
        try macA.library.mutate(id) { $0.name = "Edited offline" }
        await macA.sync.start()
        await macB.sync.syncNow()

        XCTAssertEqual(macB.library.document(id)?.name, "Edited offline")
    }

    /// The same project on both Macs before either synced, as a copied folder: what only one has is kept on both.
    func testAProjectBothMacsHadBeforeSyncingMergesAsAUnion() async throws {
        let id = try macA.lifecycle.createProject(named: "Copied")
        macA.sync.stop()
        macB.sync.stop()
        let folder = try XCTUnwrap(macA.library.project(id)).url
        try FileManager.default.createDirectory(at: macB.storage.directory.file("Projects"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: folder, to: macB.storage.directory.file("Projects/Copied.reqling"))
        try macB.lifecycle.addProjectFolder(macB.storage.directory.file("Projects/Copied.reqling"))
        try macA.library.mutate(id) { $0.environments = [RequestEnvironment(name: "Staging")] }
        try macB.library.mutate(id) { $0.environments = [RequestEnvironment(name: "Production")] }

        await macA.sync.start()
        await macB.sync.start()
        await macA.sync.syncNow()

        for mac in [macA!, macB!] {
            XCTAssertEqual(Set(mac.library.document(id)?.environments.map(\.name) ?? []), ["Staging", "Production"])
        }
    }

    // MARK: - Guards

    /// Mac B lost its value for a secret Mac A synced; editing the environment there must not erase Mac A's.
    func testAMacMissingASecretNeverBlanksItElsewhere() async throws {
        let id = try await shareProject()
        let defaultID = try XCTUnwrap(macB.library.document(id)).defaultEnvironment.id
        try macB.storage.secrets.setSecrets([:], for: .project(id))

        try macB.library.mutate(id) { $0.defaultEnvironment.variables[0].value = "https://staging" }
        await macB.sync.syncNow()
        await macA.sync.syncNow()

        let record = try XCTUnwrap(cloud.record(SyncRecordID(zone: .project(id), name: defaultID.description)))
        XCTAssertEqual(record.secrets?.values.sorted(), ["s3cret"])
        XCTAssertEqual(try macA.storage.secrets.secrets(for: .project(id)).values.sorted(), ["s3cret"])
        XCTAssertEqual(macA.library.document(id)?.defaultEnvironment.variables[0].value, "https://staging")
    }

    /// A Keychain that can't be read sends no secret values, rather than blanks over Mac A's.
    func testAnUnreadableKeychainSendsNoSecrets() async throws {
        let id = try await shareProject()
        let defaultID = try XCTUnwrap(macB.library.document(id)).defaultEnvironment.id

        macB.storage.secrets.isFailingReads = true
        try macB.library.mutate(id) { $0.defaultEnvironment.variables[0].value = "https://staging" }
        await macB.sync.syncNow()
        macB.storage.secrets.isFailingReads = false

        let record = try XCTUnwrap(cloud.record(SyncRecordID(zone: .project(id), name: defaultID.description)))
        XCTAssertEqual(record.secrets?.values.sorted(), ["s3cret"])
        XCTAssertTrue(record.payload.prettyPrinted().contains("https://staging"))
    }

    /// A file that can't be read drops out of the document, which mustn't reach Mac A as a deletion.
    func testAFileThatCantBeReadIsNeverSentAsDeleted() async throws {
        let id = try await shareProject()
        let requestID = try XCTUnwrap(request(in: macB, id)).id

        try macB.storage.write("{ not json", to: "requests/users/list-users.json", in: id)
        macB.library.reload(id)
        await macB.sync.syncNow()

        XCTAssertNotNil(cloud.record(SyncRecordID(zone: .project(id), name: requestID.description)))
        XCTAssertNotNil(request(in: macA, id))
    }

    /// Records from a newer Reqling hold the project back, untouched, rather than being half understood.
    func testARecordFromANewerVersionHoldsItsProjectBack() async throws {
        let id = try await shareProject()
        let projectRecord = SyncRecordID(zone: .project(id), name: SyncRecordID.projectName)
        var newer = try XCTUnwrap(cloud.record(projectRecord))
        newer.schemaVersion = ProjectRecordCoder.schemaVersion + 1
        newer.payload = try ProjectRecordCoder.json(["name": "From the future"])
        _ = cloud.save(newer)

        let before = macB.library.document(id)
        await macB.sync.syncNow()

        XCTAssertEqual(macB.sync.deferredProjects, [id])
        XCTAssertEqual(macB.library.document(id), before)
    }

    /// Mac A moves the reference to Mac B's client key into a request body: Mac B won't read the key for it.
    func testAClientKeyMovedIntoABodyByAnotherMacStaysUnreadable() async throws {
        let id = try await shareProject()
        let requestID = try XCTUnwrap(request(in: macA, id)).id
        let key = macB.storage.directory.file("client.p12")
        try Data("private key".utf8).write(to: key)
        let reference = macB.workspace.addLocalPath(key.path, in: id)
        try macB.library.mutate(id) { document in
            document.tls.clientCertificates = [ClientCertificateEntry(hostPattern: "api.example.com", source: .pkcs12(reference))]
        }
        await macB.sync.syncNow()
        await macA.sync.syncNow()

        try macA.library.mutate(id) { try $0.updateNode(requestID) { node in
            if case .request(var request) = node, case .http(var spec) = request.kind {
                spec.method = .post
                spec.body.mode = .binary
                spec.body.binary.file = reference
                request.kind = .http(spec)
                node = .request(request)
            }
        } }
        await macA.sync.syncNow()
        await macB.sync.syncNow()

        XCTAssertEqual(request(in: macB, id)?.kind.httpSpec?.body.binary.file, reference)
        let paths = try XCTUnwrap(macB.lifecycle.pathResolver(for: id))
        XCTAssertNil(paths.url(for: reference))
        XCTAssertEqual(try paths.identityData(for: reference), Data("private key".utf8), "TLS still reads it")
    }

    func testScriptsChangedOnAnotherMacAskForTrustAgain() async throws {
        let id = try await shareProject()
        macB.workspace.updateProject(id) { $0.scriptTrust = .trusted }

        try macA.library.mutate(id) { $0.scripts.preRequest = "steal();" }
        await macA.sync.syncNow()
        await macB.sync.syncNow()

        XCTAssertEqual(macB.library.document(id)?.scripts.preRequest, "steal();")
        XCTAssertEqual(macB.workspace.projectState(id).scriptTrust, .unknown)
    }

    // MARK: - Deleting

    func testAProjectDeletedOnOneMacGoesToTheOthersTrashWithItsSecretsKept() async throws {
        let id = try await shareProject()

        try macA.lifecycle.deleteProject(id)
        await macA.sync.syncNow()
        await macB.sync.syncNow()

        XCTAssertNil(macB.library.project(id))
        XCTAssertEqual(macB.storage.trashedNames(), ["API.reqling"])
        XCTAssertEqual(try macB.storage.secrets.secrets(for: .project(id)).values.sorted(), ["s3cret"], "Put Back restores it all")
        XCTAssertFalse(cloud.zones.contains(.project(id)))
    }

    func testRemovingAProjectStopsSyncingItOnThatMacOnly() async throws {
        let id = try await shareProject()

        macB.lifecycle.removeProject(id)
        try macA.library.mutate(id) { $0.name = "Renamed" }
        await macA.sync.syncNow()
        await macB.sync.syncNow()

        XCTAssertNil(macB.library.project(id))
        XCTAssertEqual(macB.storage.trashedNames(), [])
        XCTAssertEqual(macA.library.document(id)?.name, "Renamed")
        XCTAssertTrue(cloud.zones.contains(.project(id)))
    }

    /// A zone that disappears without a tombstone wasn't deleted by anyone here: Mac B keeps its copy.
    func testAZoneThatVanishesWithoutATombstoneStaysOnTheMac() async throws {
        let id = try await shareProject()

        _ = cloud.deleteZone(.project(id))
        await macB.sync.syncNow()

        XCTAssertNotNil(macB.library.project(id))
        XCTAssertEqual(macB.storage.trashedNames(), [])
        XCTAssertFalse(macB.sync.issues.isEmpty)
    }

    func testSeveralProjectsDeletedAtOnceWaitForAConfirmation() async throws {
        let first = try await shareProject("One")
        let second = try await shareProject("Two")

        try macA.lifecycle.deleteProject(first)
        try macA.lifecycle.deleteProject(second)
        await macA.sync.syncNow()
        await macB.sync.syncNow()

        XCTAssertEqual(Set(caseValues(macB.sync.status)), [first, second])
        XCTAssertNotNil(macB.library.project(first))

        await macB.sync.confirmDeletions(true)

        XCTAssertNil(macB.library.project(first))
        XCTAssertNil(macB.library.project(second))
    }

    private func caseValues(_ status: SyncStatus) -> [ProjectID] {
        if case .confirmingDeletions(let projects) = status {
            return projects
        }
        return []
    }

    /// Deleting Reqling's data in System Settings turns sync off and leaves the files, which are the person's.
    func testDataDeletedFromICloudTurnsSyncOffAndKeepsTheFiles() async throws {
        let id = try await shareProject()
        var stopped: SyncStopReason?
        macB.sync.onStop = { stopped = $0 }

        cloud.wipe(reason: .purged)
        await macB.sync.syncNow()

        XCTAssertEqual(macB.sync.status, .stopped(.dataDeleted))
        XCTAssertEqual(stopped, .dataDeleted)
        XCTAssertNotNil(macB.library.project(id))
        XCTAssertEqual(macB.storage.trashedNames(), [])
    }

    // MARK: - Global and current values

    func testGlobalAndCurrentValuesSyncAndASecretNeverTurnsPlain() async throws {
        let id = try await shareProject()
        let defaultID = try XCTUnwrap(macA.library.document(id)).defaultEnvironment.id
        try macA.library.mutateGlobalEnvironment {
            $0.variables = [Variable(key: "region", value: "eu"), Variable(key: "apiKey", value: "global-s3cret", isSecret: true)]
        }
        macA.library.currentValues.apply(["session": .value(TemplateVariable(value: "abc", isSecret: true))], in: .environment(id, defaultID))

        await macA.sync.syncNow()
        await macB.sync.syncNow()

        XCTAssertEqual(macB.library.globalEnvironment.variables.map(\.value), ["eu", "global-s3cret"])
        XCTAssertEqual(try macB.storage.secrets.secrets(for: .global).values.sorted(), ["global-s3cret"])
        XCTAssertEqual(
            macB.library.currentValues.values(in: .environment(id, defaultID))["session"],
            .value(TemplateVariable(value: "abc", isSecret: true))
        )

        // An older Mac writing the same key plainly can't make it plain here.
        macA.library.currentValues.apply(["token": .value(TemplateVariable(value: "s3cret-current"))], in: .environment(id, defaultID))
        await macA.sync.syncNow()
        await macB.sync.syncNow()

        XCTAssertEqual(
            macB.library.currentValues.values(in: .environment(id, defaultID))["token"],
            .value(TemplateVariable(value: "s3cret-current", isSecret: true)),
            "`token` is a secret variable on Mac B"
        )
    }

    // MARK: - Accounts

    func testADifferentAccountPausesUntilThePersonChooses() async throws {
        let id = try await shareProject()

        cloud.account = "account-b"
        macB.sync.stop()
        await macB.sync.start()

        XCTAssertEqual(macB.sync.status, .accountChanged)

        try macB.library.mutate(id) { $0.name = "Only on B" }
        await macB.sync.resolveAccountChange(merging: [])

        XCTAssertEqual(macB.sync.status, .upToDate(macB.clock))
        XCTAssertEqual(macA.library.document(id)?.name, "API")
        await macA.sync.syncNow()
        XCTAssertEqual(macA.library.document(id)?.name, "API", "A project kept out of the new account never uploads")
    }

    // MARK: - What stays on disk

    /// What sync keeps on this Mac holds digests only: no secret value, and no content.
    func testSyncKeepsNoSecretOrContentOnDisk() async throws {
        try await shareProject()
        macB.sync.flush()

        let folder = macB.storage.directory.file("Support/Sync")
        let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? []
        XCTAssertFalse(files.isEmpty)
        for file in files where !file.hasDirectoryPath {
            let text = try String(contentsOf: file, encoding: .utf8)
            for content in ["s3cret", "List users", "baseUrl", "https://api"] {
                XCTAssertFalse(text.contains(content), "\(file.lastPathComponent) holds \(content)")
            }
        }
    }
}
