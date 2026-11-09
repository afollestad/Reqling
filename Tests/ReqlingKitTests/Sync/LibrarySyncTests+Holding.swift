import Foundation
@testable import ReqlingKit
import ReqlingTemplating
import XCTest

/// When sync holds back: in the background, for a project it can't read fully or that a newer Reqling wrote, for an
/// edit still waiting to go out, and for Global kept out of a new account.
@MainActor
extension LibrarySyncTests {
    func folderID(in mac: SyncTestMac, _ project: ProjectID) throws -> RequestNodeID {
        try XCTUnwrap(mac.library.document(project)?.items.first?.id)
    }

    func testChangesFetchedInTheBackgroundWaitAndNothingIsSentUntilReqlingIsInFront() async throws {
        let id = try await shareProject()
        let folder = try folderID(in: macB, id)

        await macB.sync.setActive(false)
        try macA.library.mutate(id) { $0.name = "From A" }
        await macA.sync.syncNow()
        try macB.library.mutate(id) { try $0.updateNode(folder) { $0.name = "Renamed on B" } }
        await macB.sync.syncNow()
        // As `CKSyncEngine` sends on its own schedule.
        await macB.transport.sendChanges()
        await macA.sync.syncNow()

        XCTAssertEqual(macB.library.document(id)?.name, "API", "Applied only once Reqling is in front")
        XCTAssertEqual(macA.library.document(id)?.items.first?.name, "Users", "Sent only once Reqling is in front")

        await macB.sync.setActive(true)
        await macA.sync.syncNow()

        XCTAssertEqual(macB.library.document(id)?.name, "From A")
        XCTAssertEqual(macA.library.document(id)?.items.first?.name, "Renamed on B")
    }

    /// Comparing a project again, as any later edit to it does, mustn't make an edit still waiting to go out look newer
    /// than one another Mac made since.
    func testAnEditWaitingToSendKeepsItsTimeWhenItsProjectIsComparedAgain() async throws {
        let id = try await shareProject()
        let folder = try folderID(in: macA, id)

        macA.tick()
        try macA.library.mutate(id) { $0.name = "From A, earlier" }
        macB.tick(5)
        try macB.library.mutate(id) { $0.name = "From B, later" }
        await macB.sync.syncNow()
        macA.tick(10)
        try macA.library.mutate(id) { try $0.updateNode(folder) { $0.name = "Folder from A" } }
        await macA.sync.syncNow()
        await macB.sync.syncNow()

        XCTAssertEqual(macA.library.document(id)?.name, "From B, later")
        XCTAssertEqual(macB.library.document(id)?.name, "From B, later")
        XCTAssertEqual(macB.library.document(id)?.items.first?.name, "Folder from A")
    }

    /// What a project lacks while one of its files can't be read would merge as deleted, so another Mac's changes wait
    /// for the file and arrive once it reads again.
    func testChangesWaitWhileAFileOfTheProjectCantBeRead() async throws {
        let id = try await shareProject()
        let file = "requests/users/list-users.json"
        let original = try macB.storage.contents(file, in: id)

        try macB.storage.write("{ not json", to: file, in: id)
        macB.library.reload(id)
        try macA.library.mutate(id) { $0.name = "Renamed on A" }
        await macA.sync.syncNow()
        await macB.sync.syncNow()

        XCTAssertEqual(macB.library.document(id)?.name, "API")
        XCTAssertEqual(try macB.storage.contents(file, in: id), "{ not json", "Left as it was")

        try macB.storage.write(original, to: file, in: id)
        macB.library.reload(id)
        await macB.sync.syncNow()

        XCTAssertEqual(macB.library.document(id)?.name, "Renamed on A")
        XCTAssertEqual(request(in: macB, id)?.name, "List users")
    }

    /// A project a newer Reqling changed stays held back, even when an older Mac changes it again afterwards.
    func testAProjectHeldBackForANewerVersionStaysHeldBack() async throws {
        let id = try await shareProject()
        let requestID = try XCTUnwrap(request(in: macB, id)).id
        var newer = try XCTUnwrap(cloud.record(SyncRecordID(zone: .project(id), name: SyncRecordID.projectName)))
        newer.schemaVersion = ProjectRecordCoder.schemaVersion + 1
        _ = cloud.save(newer)
        await macB.sync.syncNow()

        var edited = try XCTUnwrap(cloud.record(SyncRecordID(zone: .project(id), name: requestID.description)))
        guard case .object(let members) = edited.payload else {
            return XCTFail("A request's payload is an object")
        }
        edited.payload = .object(members.map { $0.key == "name" ? OrderedJSONMember(key: "name", value: .string("From an older Mac")) : $0 })
        _ = cloud.save(edited)
        await macB.sync.syncNow()

        XCTAssertEqual(macB.sync.deferredProjects, [id])
        XCTAssertEqual(request(in: macB, id)?.name, "List users")
    }

    /// A project new to this Mac whose records haven't all arrived waits to be fetched whole, rather than looking as if a
    /// newer Reqling wrote it.
    func testAProjectWhoseRecordsHaventAllArrivedWaitsForThem() async throws {
        let document = ProjectDocument(name: "Arriving")
        let records = try ProjectRecordCoder.records(for: document, secrets: [:])
        let projectRecord = SyncRecordID(zone: .project(document.id), name: SyncRecordID.projectName)
        _ = cloud.saveZone(.project(document.id))
        _ = cloud.save(try XCTUnwrap(records[projectRecord]))
        await macB.sync.syncNow()

        XCTAssertEqual(macB.sync.deferredProjects, [])
        XCTAssertNil(macB.library.project(document.id))

        for (id, record) in records where id != projectRecord {
            _ = cloud.save(record)
        }
        // A whole fetch already fell short, so only Sync Now tries again before a relaunch.
        await macB.sync.syncNow()
        XCTAssertNil(macB.library.project(document.id))
        await macB.sync.syncNow(retryingFailures: true)

        XCTAssertEqual(macB.library.document(document.id)?.name, "Arriving")
    }

    /// Keeping this Mac's data out of a new account keeps Global out too, both ways, until the person attaches it.
    func testKeepingThisMacsDataOutOfANewAccountKeepsGlobalOutToo() async throws {
        try await shareProject()
        cloud.account = "account-b"
        macB.sync.stop()
        await macB.sync.start()
        await macB.sync.resolveAccountChange(merging: [])

        try macB.library.mutateGlobalEnvironment { $0.variables = [Variable(key: "region", value: "only on B")] }
        try macA.library.mutateGlobalEnvironment { $0.variables = [Variable(key: "tier", value: "from A")] }
        await macA.sync.syncNow()
        await macB.sync.syncNow()
        await macA.sync.syncNow()

        XCTAssertTrue(macB.sync.isGlobalDetached)
        XCTAssertEqual(macA.library.globalEnvironment.variables.map(\.key), ["tier"])
        XCTAssertEqual(macB.library.globalEnvironment.variables.map(\.key), ["region"])

        await macB.sync.attachGlobal()
        await macA.sync.syncNow()

        XCTAssertEqual(Set(macA.library.globalEnvironment.variables.map(\.key)), ["region", "tier"])
        XCTAssertEqual(Set(macB.library.globalEnvironment.variables.map(\.key)), ["region", "tier"])
    }

    /// A record iCloud refuses as too large isn't sent again until it changes.
    func testARecordTooLargeForICloudIsntSentAgainUntilItChanges() async throws {
        let id = try await shareProject()
        let requestID = try XCTUnwrap(request(in: macA, id)).id
        let record = SyncRecordID(zone: .project(id), name: requestID.description)
        cloud.payloadLimit = 2_000

        try macA.library.mutate(id) {
            try $0.updateNode(requestID) { node in
                if case .request(var item) = node {
                    item.kind = .http(HTTPRequestSpec(url: "https://api/" + String(repeating: "a", count: 4_000)))
                    node = .request(item)
                }
            }
        }
        await macA.sync.syncNow()
        let attempts = cloud.saveAttempts[record]
        try macA.library.mutate(id) { $0.name = "Renamed" }
        await macA.sync.syncNow()
        await macB.sync.syncNow()

        XCTAssertEqual(cloud.saveAttempts[record], attempts)
        XCTAssertFalse(macA.sync.issues.isEmpty)
        XCTAssertEqual(macB.library.document(id)?.name, "Renamed")
    }

    /// A file the reader couldn't read leaves a stand-in, here a blank script, which mustn't go out as an edit.
    func testAProjectWithAFileThatCantBeReadSendsNothing() async throws {
        let id = try await shareProject()
        try macA.library.mutate(id) { $0.scripts = ScriptSet(preRequest: "sign();") }
        await macA.sync.syncNow()
        await macB.sync.syncNow()

        try Data([0xFF, 0xFE, 0xFD]).write(to: macB.storage.projectURL(id).appendingPathComponent("project.pre.js"))
        macB.library.reload(id)
        try macB.library.mutate(id) { $0.name = "Renamed on B" }
        await macB.sync.syncNow()
        await macA.sync.syncNow()

        XCTAssertEqual(macA.library.document(id)?.scripts.preRequest, "sign();")
        XCTAssertEqual(macA.library.document(id)?.name, "API")
        XCTAssertFalse(macB.sync.issues.isEmpty)
    }

    /// A Mac missing one secret's value gets it back from iCloud, rather than holding back every other secret change.
    func testAMacMissingOneSecretFetchesItAndStillSendsTheOthers() async throws {
        let id = try await shareProject()
        let environment = try XCTUnwrap(macA.library.document(id)).defaultEnvironment.id
        try macA.library.mutate(id) { $0.defaultEnvironment.variables.append(Variable(key: "other", value: "o2", isSecret: true)) }
        await macA.sync.syncNow()
        await macB.sync.syncNow()
        let other = try XCTUnwrap(macB.library.document(id)?.defaultEnvironment.variables.first { $0.key == "other" })
        var keychain = try macB.storage.secrets.secrets(for: .project(id))
        keychain[SecretKey.variable(other.id, in: environment)] = nil
        try macB.storage.secrets.setSecrets(keychain, for: .project(id))
        // As after a relaunch, which loads the missing value blank.
        macB.library.reload(id)

        try macB.library.mutate(id) { document in
            if let index = document.defaultEnvironment.variables.firstIndex(where: { $0.key == "token" }) {
                document.defaultEnvironment.variables[index].value = "n1"
            }
        }
        await macB.sync.syncNow()
        await macA.sync.syncNow()

        XCTAssertEqual(try macA.storage.secrets.secrets(for: .project(id)).values.sorted(), ["n1", "o2"])
        XCTAssertEqual(try macB.storage.secrets.secrets(for: .project(id)).values.sorted(), ["n1", "o2"])
    }

    /// An edit queued before a file turned unreadable isn't sent from the stand-in the reader left.
    func testAnEditQueuedBeforeAFileTurnedUnreadableIsntSent() async throws {
        let id = try await shareProject()
        try macA.library.mutate(id) { $0.scripts = ScriptSet(preRequest: "sign();") }
        await macA.sync.syncNow()
        await macB.sync.syncNow()

        try macB.library.mutate(id) { $0.name = "Renamed on B" }
        try Data([0xFF, 0xFE, 0xFD]).write(to: macB.storage.projectURL(id).appendingPathComponent("project.pre.js"))
        macB.library.reload(id)
        await macB.sync.syncNow()
        await macA.sync.syncNow()

        XCTAssertEqual(macA.library.document(id)?.scripts.preRequest, "sign();")
    }

    /// Global missing one secret's value gets it back from iCloud too, and its other secret changes still go out.
    func testGlobalMissingOneSecretFetchesItAndStillSendsTheOthers() async throws {
        try macA.library.mutateGlobalEnvironment {
            $0.variables = [Variable(key: "one", value: "a1", isSecret: true), Variable(key: "two", value: "a2", isSecret: true)]
        }
        await macA.sync.syncNow()
        await macB.sync.syncNow()
        let one = try XCTUnwrap(macB.library.globalEnvironment.variables.first { $0.key == "one" })
        var keychain = try macB.storage.secrets.secrets(for: .global)
        keychain[SecretKey.variable(one.id, in: RequestEnvironment.globalID)] = nil
        try macB.storage.secrets.setSecrets(keychain, for: .global)
        // As after a relaunch, which loads the missing value blank.
        macB.library.loadGlobalEnvironment()

        try macB.library.mutateGlobalEnvironment { global in
            if let index = global.variables.firstIndex(where: { $0.key == "two" }) {
                global.variables[index].value = "b2"
            }
        }
        await macB.sync.syncNow()
        await macA.sync.syncNow()

        XCTAssertEqual(try macA.storage.secrets.secrets(for: .global).values.sorted(), ["a1", "b2"])
        XCTAssertEqual(try macB.storage.secrets.secrets(for: .global).values.sorted(), ["a1", "b2"])
    }
}
