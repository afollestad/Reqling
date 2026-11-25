import Foundation
@testable import ReqlingKit
import ReqlingTemplating
import XCTest

/// Projects shared between people: Mac A's person shares one with another, on a Mac of their own, with their own iCloud
/// database and a shared one over Mac A's (`SyncTestSharedTransport`).
extension LibrarySyncTests {
    static let participantAccount = "account-p"

    /// Another person's Mac, signed in to their own account, sharing with Mac A's.
    func makeParticipant() async throws -> (mac: SyncTestMac, home: SyncTestCloud) {
        let home = SyncTestCloud()
        home.account = Self.participantAccount
        let mac = try SyncTestMac(cloud: home, sharingFrom: cloud)
        await mac.sync.start()
        return (mac, home)
    }

    /// `shareProject`'s project, shared with `participant` as `permission`, accepted, and synced there.
    func share(with participant: SyncTestMac, permission: ProjectSharing.Permission = .readWrite) async throws -> ProjectID {
        let id = try await shareProject()
        cloud.share(.project(id), with: Self.participantAccount, permission: permission)
        await participant.sync.syncNow()
        return id
    }

    // MARK: - Arriving

    /// The project arrives with how it's shared, and with none of its owner's own values: secret values and current
    /// values are each person's, so its secret variables arrive empty, for the participant to fill.
    func testASharedProjectArrivesWithoutItsOwnersValues() async throws {
        let (participant, home) = try await makeParticipant()
        defer { participant.cleanUp() }
        let id = try await shareProject()
        let defaultID = try XCTUnwrap(macA.library.document(id)).defaultEnvironment.id
        let ownerValues: [String: CurrentVariable?] = ["session": .value(TemplateVariable(value: "owner-session", isSecret: true))]
        macA.library.currentValues.apply(ownerValues, in: .environment(id, defaultID))
        await macA.sync.syncNow()
        cloud.share(.project(id), with: Self.participantAccount)

        await participant.sync.syncNow()

        let arrived = try XCTUnwrap(participant.library.project(id))
        XCTAssertEqual(arrived.sharing, ProjectSharing(owner: cloud.ownerName, permission: .readWrite, canInvite: false, ownerName: "Owner A"))
        XCTAssertEqual(arrived.document?.allRequests.map(\.0.name), ["List users"])
        let token = try XCTUnwrap(arrived.document?.defaultEnvironment.variables.last)
        XCTAssertTrue(token.isSecret)
        XCTAssertEqual(token.value, "")
        XCTAssertEqual(try participant.storage.secrets.secrets(for: .project(id)), [:])
        XCTAssertTrue(participant.library.currentValues.values(in: .environment(id, defaultID)).isEmpty)
        XCTAssertFalse(home.zones.contains(.project(id)), "Never uploaded into the participant's own database")
        XCTAssertEqual(participant.sharedTransport?.zoneWrites, 0)
    }

    // MARK: - Editing

    /// The shared database's engine announces the account it found as it starts fresh, which its transport takes for the
    /// start it is only knowing the account sync connected as (`CloudKitSyncTransport.account`).
    func testTheSharedDatabaseStartsForTheAccountSyncConnectedAs() async throws {
        let (participant, home) = try await makeParticipant()
        defer { participant.cleanUp() }

        await participant.sync.syncNow()

        XCTAssertNotNil(home.account)
        XCTAssertEqual(participant.sharedTransport?.startedAccount, home.account)
    }

    func testEditsGoBothWaysInAProjectSharedToEdit() async throws {
        let (participant, _) = try await makeParticipant()
        defer { participant.cleanUp() }
        let id = try await share(with: participant)
        let requestID = try XCTUnwrap(request(in: participant, id)).id

        participant.tick()
        try participant.library.mutate(id) { try $0.updateRequest(requestID) { $0.name = "From the participant" } }
        await participant.sync.syncNow()
        await macA.sync.syncNow()

        XCTAssertEqual(request(in: macA, id)?.name, "From the participant")

        macA.tick()
        try macA.library.mutate(id) { $0.name = "Renamed by its owner" }
        await macA.sync.syncNow()
        await participant.sync.syncNow()

        XCTAssertEqual(participant.library.document(id)?.name, "Renamed by its owner")
        XCTAssertEqual(participant.sharedTransport?.zoneWrites, 0)
    }

    /// The owner's edit of a saved value drops the participant's current value for that key, and only that one.
    func testAnOwnersEditOfASavedValueDropsTheParticipantsCurrentValue() async throws {
        let (participant, _) = try await makeParticipant()
        defer { participant.cleanUp() }
        let id = try await share(with: participant)
        let defaultID = try XCTUnwrap(macA.library.document(id)).defaultEnvironment.id
        let scope = CurrentValueScope.environment(id, defaultID)
        try participant.library.mutate(id) { $0.defaultEnvironment.variables[1].value = "participant-s3cret" }
        participant.library.currentValues.apply([
            "baseUrl": .value(TemplateVariable(value: "https://participant")),
            "token": .value(TemplateVariable(value: "session-token", isSecret: true))
        ], in: scope)
        await participant.sync.syncNow()

        macA.tick()
        try macA.library.mutate(id) { $0.defaultEnvironment.variables[0].value = "https://api.v2" }
        await macA.sync.syncNow()
        await participant.sync.syncNow()

        XCTAssertEqual(participant.library.document(id)?.defaultEnvironment.variables.first?.value, "https://api.v2")
        XCTAssertEqual(Set(participant.library.currentValues.values(in: scope).keys), ["token"])
        XCTAssertEqual(participant.library.document(id)?.defaultEnvironment.variables.last?.value, "participant-s3cret")
    }

    /// Each person's secret values and current values for a shared project go to their own database, never its owner's.
    func testEachPersonsValuesStayTheirOwn() async throws {
        let (participant, home) = try await makeParticipant()
        defer { participant.cleanUp() }
        let id = try await share(with: participant)
        let defaultID = try XCTUnwrap(macA.library.document(id)).defaultEnvironment.id
        let scope = CurrentValueScope.environment(id, defaultID)

        try participant.library.mutate(id) { $0.defaultEnvironment.variables[1].value = "participant-s3cret" }
        participant.library.currentValues.apply(["session": .value(TemplateVariable(value: "participant-session"))], in: scope)
        await participant.sync.syncNow()
        await macA.sync.syncNow()

        XCTAssertEqual(home.record(LibraryRecordCoder.secretsRecordID(id, defaultID))?.secrets?.values.sorted(), ["participant-s3cret"])
        XCTAssertNotNil(home.record(LibraryRecordCoder.currentValuesRecordID(scope)))
        XCTAssertEqual(cloud.record(LibraryRecordCoder.secretsRecordID(id, defaultID))?.secrets?.values.sorted(), ["s3cret"])
        XCTAssertEqual(macA.library.document(id)?.defaultEnvironment.variables.last?.value, "s3cret")
        XCTAssertTrue(macA.library.currentValues.values(in: scope).isEmpty)
        for record in cloud.records.values where record.id.zone == .project(id) {
            XCTAssertEqual(record.secrets ?? [:], [:], record.id.description)
            XCTAssertNotEqual(record.type, .currentValues, record.id.description)
        }
    }

    // MARK: - Read-only

    func testAProjectSharedToViewOnlyTakesItsOwnersEditsAndSendsNone() async throws {
        let (participant, home) = try await makeParticipant()
        defer { participant.cleanUp() }
        let id = try await share(with: participant, permission: .readOnly)
        let defaultID = try XCTUnwrap(macA.library.document(id)).defaultEnvironment.id

        XCTAssertEqual(participant.library.project(id)?.readOnlyReason, .sharedReadOnly)
        XCTAssertThrowsError(try participant.library.mutate(id) { $0.name = "Not allowed" }) { error in
            XCTAssertEqual(error as? ProjectStorageError, .readOnly(.sharedReadOnly))
        }

        macA.tick()
        try macA.library.mutate(id) { $0.name = "Renamed by its owner" }
        await macA.sync.syncNow()
        participant.library.currentValues.apply(["page": .value(TemplateVariable(value: "3"))], in: .environment(id, defaultID))
        await participant.sync.syncNow()

        XCTAssertEqual(participant.library.document(id)?.name, "Renamed by its owner")
        XCTAssertNotNil(home.record(LibraryRecordCoder.currentValuesRecordID(.environment(id, defaultID))), "Its own values still sync")
        XCTAssertEqual(participant.sharedTransport?.zoneWrites, 0)
    }

    /// Someone who may only view a project still sets their own secret values, which sync to their own database alone.
    func testAViewOnlyParticipantSetsTheirOwnSecretValues() async throws {
        let (participant, home) = try await makeParticipant()
        defer { participant.cleanUp() }
        let id = try await share(with: participant, permission: .readOnly)
        let environment = try XCTUnwrap(participant.library.document(id)).defaultEnvironment
        let token = try XCTUnwrap(environment.variables.last)

        try participant.library.setSecretValues([SecretKey.variable(token.id, in: environment.id): "viewer-s3cret"], in: id)
        await participant.sync.syncNow()
        await macA.sync.syncNow()

        XCTAssertEqual(home.record(LibraryRecordCoder.secretsRecordID(id, environment.id))?.secrets?.values.sorted(), ["viewer-s3cret"])
        XCTAssertEqual(macA.library.document(id)?.defaultEnvironment.variables.last?.value, "s3cret")
        XCTAssertEqual(participant.sharedTransport?.zoneWrites, 0)
    }

    /// An edit the share no longer allows by the time it goes out is undone: the copy gives way to the server's.
    func testAnEditRefusedAfterTheShareBecameReadOnlyIsUndone() async throws {
        let (participant, _) = try await makeParticipant()
        defer { participant.cleanUp() }
        let id = try await share(with: participant)
        let requestID = try XCTUnwrap(request(in: participant, id)).id

        participant.tick()
        try participant.library.mutate(id) { try $0.updateRequest(requestID) { $0.name = "Too late" } }
        cloud.setPermission(.readOnly, for: Self.participantAccount, in: .project(id))
        await participant.sync.syncNow()
        await participant.sync.syncNow(retryingFailures: true)

        XCTAssertEqual(request(in: macA, id)?.name, "List users")
        XCTAssertEqual(request(in: participant, id)?.name, "List users")
        XCTAssertEqual(participant.library.project(id)?.readOnlyReason, .sharedReadOnly)
        XCTAssertTrue(participant.sync.issues.contains { $0.contains("can no longer change") }, participant.sync.issues.description)
    }

    // MARK: - Losing access

    func testLosingAccessMovesTheCopyToTheTrash() async throws {
        for end in ["removed", "stopped", "deleted"] {
            let (participant, _) = try await makeParticipant()
            defer { participant.cleanUp() }
            let id = try await share(with: participant)
            XCTAssertNotNil(participant.library.project(id), end)

            switch end {
            case "removed":
                cloud.removeParticipant(Self.participantAccount, from: .project(id))
            case "stopped":
                cloud.stopSharing(.project(id))
            default:
                try macA.lifecycle.deleteProject(id)
                await macA.sync.syncNow()
                macA.tick(120)
                await macA.sync.syncNow()
            }
            await participant.sync.syncNow()

            XCTAssertNil(participant.library.project(id), end)
            XCTAssertEqual(participant.storage.trashedNames(), ["API.reqling"], end)
            XCTAssertTrue(participant.sync.issues.contains { $0.contains("no longer shared with you") }, end)
            if end != "deleted" {
                XCTAssertNotNil(macA.library.project(id), "\(end): its owner keeps it")
            }
        }
    }

    /// Deleting a project someone else shares leaves its share; it stays with its owner.
    func testDeletingASharedProjectLeavesItsShare() async throws {
        let (participant, _) = try await makeParticipant()
        defer { participant.cleanUp() }
        let id = try await share(with: participant)

        try participant.lifecycle.deleteProject(id)
        await participant.sync.syncNow()
        participant.tick(120)
        await participant.sync.syncNow()

        XCTAssertNil(cloud.shares[.project(id)]?[Self.participantAccount])
        XCTAssertNil(participant.library.project(id))
        XCTAssertEqual(participant.storage.trashedNames(), ["API.reqling"])
        await macA.sync.syncNow()
        XCTAssertNotNil(macA.library.project(id))
        XCTAssertNotNil(cloud.record(SyncRecordID(zone: .project(id), name: SyncRecordID.projectName)))
        XCTAssertEqual(participant.sharedTransport?.zoneWrites, 0)
    }

    // MARK: - Menus

    /// Share… for a project that syncs, Manage Sharing… once shared, and for someone else's, only with leave to invite.
    func testWhatEachPersonMayDoAboutSharing() async throws {
        let (participant, _) = try await makeParticipant()
        defer { participant.cleanUp() }
        let id = try await shareProject()

        XCTAssertEqual(macA.sync.shareAction(for: id), .share)
        cloud.share(.project(id), with: Self.participantAccount, permission: .readOnly)
        await macA.sync.syncNow()
        await participant.sync.syncNow()
        XCTAssertEqual(macA.sync.shareAction(for: id), .manage(readOnlyInvites: false))
        XCTAssertNil(participant.sync.shareAction(for: id))

        cloud.share(.project(id), with: Self.participantAccount, permission: .readOnly, canInvite: true)
        await participant.sync.syncNow()
        XCTAssertEqual(participant.sync.shareAction(for: id), .manage(readOnlyInvites: true))

        let unsynced = try macA.lifecycle.createProject(named: "Not yet")
        guard case .unavailable? = macA.sync.shareAction(for: unsynced) else {
            return XCTFail("A project that hasn't synced can't be shared")
        }
        macA.sync.stop()
        guard case .unavailable? = macA.sync.shareAction(for: id) else {
            return XCTFail("Sharing needs sync")
        }
    }

    // MARK: - Titles

    /// A share's title, which invitations show, follows the project's name, whoever renamed it.
    func testAShareIsTitledAfterItsProjectThroughRenames() async throws {
        let (participant, _) = try await makeParticipant()
        defer { participant.cleanUp() }
        let id = try await share(with: participant)
        await macA.sync.syncNow()

        XCTAssertEqual(cloud.shareTitles[.project(id)], "API")

        macA.tick()
        try macA.library.mutate(id) { $0.name = "Renamed by its owner" }
        await macA.sync.syncNow()
        XCTAssertEqual(cloud.shareTitles[.project(id)], "Renamed by its owner")

        await participant.sync.syncNow()
        try participant.library.mutate(id) { $0.name = "Renamed by the participant" }
        await participant.sync.syncNow()
        await macA.sync.syncNow()
        XCTAssertEqual(cloud.shareTitles[.project(id)], "Renamed by the participant")

        let writes = cloud.titleWrites
        await macA.sync.syncNow()
        await macB.sync.syncNow()
        XCTAssertEqual(cloud.titleWrites, writes, "Titled once, not on every sync or by every Mac")
    }

    // MARK: - Listing again

    /// A shared project removed from Reqling and added back, while sync runs or while it's off, is still someone else's:
    /// it syncs with its owner again, and never goes up into this person's own database as theirs.
    func testASharedProjectAddedBackStaysShared() async throws {
        for whileOff in [false, true] {
            let label = whileOff ? "while off" : "while on"
            let (participant, home) = try await makeParticipant()
            defer { participant.cleanUp() }
            let id = try await share(with: participant)
            let url = try XCTUnwrap(participant.library.project(id)).url

            participant.lifecycle.removeProject(id)
            await participant.sync.syncNow()
            if whileOff {
                participant.sync.stop()
            }
            _ = try participant.lifecycle.addProjectFolder(url)
            if whileOff {
                await participant.sync.start()
            }
            macA.tick()
            try macA.library.mutate(id) { $0.name = "Renamed by its owner" }
            await macA.sync.syncNow()
            await participant.sync.syncNow()
            participant.tick(120)
            await participant.sync.syncNow()
            await macA.sync.syncNow()

            XCTAssertNotNil(participant.library.project(id)?.sharing, label)
            XCTAssertEqual(participant.library.document(id)?.name, "Renamed by its owner", label)
            XCTAssertFalse(home.zones.contains(.project(id)), label)
            XCTAssertEqual(request(in: macA, id)?.name, "List users", label)
        }
    }

    /// A shared project that fell off a list that couldn't be read is listed again from its folder, as shared.
    func testASharedProjectLostWithTheListIsListedAgainAsShared() async throws {
        let (participant, home) = try await makeParticipant()
        defer { participant.cleanUp() }
        let id = try await share(with: participant)
        let url = try XCTUnwrap(participant.library.project(id)).url

        participant.sync.stop()
        participant.lifecycle.removeProject(id)
        participant.library.registryWasSetAside = true
        await participant.sync.start()
        participant.tick(120)
        await participant.sync.syncNow()

        XCTAssertEqual(participant.library.project(id)?.url.standardizedFileURL, url.standardizedFileURL)
        XCTAssertNotNil(participant.library.project(id)?.sharing)
        XCTAssertFalse(home.zones.contains(.project(id)))
        XCTAssertEqual(participant.storage.trashedNames(), [])
    }

    // MARK: - Guards

    /// Current values an owner's older Mac left in the project's zone are the owner's: a participant who can edit
    /// neither takes them nor, holding no record of them, deletes them.
    func testAParticipantLeavesItsOwnersOldValuesAlone() async throws {
        let (participant, _) = try await makeParticipant()
        defer { participant.cleanUp() }
        let id = try await share(with: participant)
        let defaultID = try XCTUnwrap(macA.library.document(id)).defaultEnvironment.id
        let scope = CurrentValueScope.environment(id, defaultID)
        let legacyID = SyncRecordID(zone: .project(id), name: SyncRecordID.currentValuesPrefix + defaultID.description)
        let built = try LibraryRecordCoder.currentValuesRecord(scope, values: ["owner-page": .plain("4")], secrets: [:])
        let legacy = SyncRecord(id: legacyID, type: .currentValues, payload: built.payload, secrets: built.secrets, schemaVersion: 1)
        guard case .saved = cloud.save(legacy) else {
            return XCTFail("The older Mac's save was refused")
        }

        await participant.sync.syncNow()
        participant.tick()
        try participant.library.mutate(id) { $0.name = "Renamed by the participant" }
        await participant.sync.syncNow()
        participant.tick(120)
        await participant.sync.syncNow()

        XCTAssertNotNil(cloud.record(legacyID))
        XCTAssertTrue(participant.library.currentValues.values(in: scope).isEmpty)
        await macA.sync.syncNow()
        XCTAssertEqual(macA.library.document(id)?.name, "Renamed by the participant")
    }

    /// A project of the participant's own with the shared one's ID keeps it out, rather than merging two people's.
    func testASharedProjectNeverMergesIntoOneOfYourOwn() async throws {
        let (participant, _) = try await makeParticipant()
        defer { participant.cleanUp() }
        let id = try await shareProject()
        let copy = participant.storage.directory.file("Repo/API.reqling")
        try FileManager.default.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: try XCTUnwrap(macA.library.project(id)).url, to: copy)
        try participant.lifecycle.addProjectFolder(copy)
        cloud.share(.project(id), with: Self.participantAccount)

        await participant.sync.syncNow()

        XCTAssertNil(participant.library.project(id)?.sharing)
        XCTAssertEqual(participant.library.project(id)?.url.standardizedFileURL, copy.standardizedFileURL)
        XCTAssertTrue(participant.sync.issues.contains { $0.contains("a project of yours has its ID") }, participant.sync.issues.description)
    }

    /// Scripts someone else wrote ask for trust before they run, and again when they change.
    func testScriptsInASharedProjectAskForTrust() async throws {
        let (participant, _) = try await makeParticipant()
        defer { participant.cleanUp() }
        let id = try await shareProject()
        try macA.library.mutate(id) { $0.scripts = ScriptSet(preRequest: "rq.set('a', 1);") }
        await macA.sync.syncNow()
        cloud.share(.project(id), with: Self.participantAccount)
        await participant.sync.syncNow()

        XCTAssertEqual(participant.workspace.projectState(id).scriptTrust, .unknown)

        participant.workspace.updateProject(id) { $0.scriptTrust = .trusted }
        macA.tick()
        try macA.library.mutate(id) { $0.scripts = ScriptSet(preRequest: "rq.set('a', 2);") }
        await macA.sync.syncNow()
        await participant.sync.syncNow()

        XCTAssertEqual(participant.workspace.projectState(id).scriptTrust, .unknown)
    }

    /// Someone else's project never merges into an account signed in after: it stays here as this person's own.
    func testAnotherAccountNeverMergesSomeoneElsesProject() async throws {
        let (participant, home) = try await makeParticipant()
        defer { participant.cleanUp() }
        let id = try await share(with: participant)

        home.account = "account-q"
        participant.sync.stop()
        await participant.sync.start()

        XCTAssertEqual(participant.sync.status, .accountChanged)
        XCTAssertFalse(participant.sync.accountChangeCandidates.contains { $0.id == id })
    }
}
