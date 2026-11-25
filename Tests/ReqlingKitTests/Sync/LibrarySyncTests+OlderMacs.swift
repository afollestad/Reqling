import Foundation
@testable import ReqlingKit
import ReqlingTemplating
import XCTest

/// Values a Mac before `personal` left in a project's zone, or writes there still, coming over to `personal` without
/// losing any or taking back a newer one (`LibrarySync+PersonalData.swift`).
extension LibrarySyncTests {
    /// Values a Mac before `personal` left in the project's zone come over to it, and are cleared there only after the
    /// project's header goes up at the new schema, the fence that holds an older Mac back before it sees them go.
    func testValuesLeftInTheProjectsZoneMoveToPersonalBehindTheFence() async throws {
        let legacy = try seedLegacyProject()
        let seeded = cloud.sequence

        await macB.sync.syncNow()
        await macB.sync.syncNow()

        XCTAssertEqual(try macB.storage.secrets.secrets(for: .project(legacy.id))[legacy.secretKey], "old-s3cret")
        XCTAssertEqual(macB.library.currentValues.values(in: legacy.scope)["session"], .value(TemplateVariable(value: "abc")))
        XCTAssertEqual(cloud.record(legacy.environment)?.secrets, [:])
        XCTAssertNil(cloud.record(legacy.values))
        XCTAssertEqual(cloud.record(legacy.header)?.schemaVersion, LibrarySync.personalSchemaVersion)
        XCTAssertEqual(cloud.record(legacy.personalSecrets)?.secrets?.values.sorted(), ["old-s3cret"])
        let personalValues = try XCTUnwrap(cloud.record(LibraryRecordCoder.currentValuesRecordID(legacy.scope)))
        XCTAssertTrue(personalValues.payload.prettyPrinted().contains("abc"))
        let changes = cloud.recordLog.filter { $0.sequence > seeded && [legacy.header, legacy.environment, legacy.values].contains($0.id) }
        XCTAssertEqual(changes.first?.id, legacy.header, "The fence goes up before anything of the older layout is cleared")
        XCTAssertEqual(Set(changes.map(\.id)), [legacy.header, legacy.environment, legacy.values])
    }

    /// An older Mac that writes values into the project's zone again, before it saw the fence, loses none: they come
    /// over as before.
    func testValuesAnOlderMacWritesAgainMoveOverAgain() async throws {
        let legacy = try seedLegacyProject()
        await macB.sync.syncNow()
        await macB.sync.syncNow()

        var environment = try XCTUnwrap(cloud.record(legacy.environment))
        environment.secrets = [legacy.token.description: "new-s3cret"]
        environment.schemaVersion = 1
        _ = cloud.save(environment)
        _ = cloud.save(try legacyValues(legacy.values, session: "def"))
        await macB.sync.syncNow()
        await macB.sync.syncNow()

        XCTAssertEqual(try macB.storage.secrets.secrets(for: .project(legacy.id))[legacy.secretKey], "new-s3cret")
        XCTAssertEqual(macB.library.document(legacy.id)?.defaultEnvironment.variables.last?.value, "new-s3cret")
        XCTAssertEqual(macB.library.currentValues.values(in: legacy.scope)["session"], .value(TemplateVariable(value: "def")))
        XCTAssertEqual(cloud.record(legacy.environment)?.secrets, [:])
        XCTAssertNil(cloud.record(legacy.values))
        XCTAssertEqual(cloud.record(legacy.personalSecrets)?.secrets?.values.sorted(), ["new-s3cret"])
    }

    /// The values a Mac lacks stay where they are until one that has them brings them over.
    func testASecretThisMacCantStoreStaysInTheProjectsZone() async throws {
        let legacy = try seedLegacyProject()
        macB.storage.secrets.isFailingWrites = true

        await macB.sync.syncNow()
        await macB.sync.syncNow()

        XCTAssertEqual(cloud.record(legacy.environment)?.secrets, [legacy.token.description: "old-s3cret"])

        macB.storage.secrets.isFailingWrites = false
        macB.sync.stop()
        await macB.sync.start()
        await macB.sync.syncNow()

        XCTAssertEqual(cloud.record(legacy.environment)?.secrets, [:])
        XCTAssertEqual(cloud.record(legacy.personalSecrets)?.secrets?.values.sorted(), ["old-s3cret"])
    }

    /// A secret value edited here outlives an older Mac's later save of the environment, which carries the value that
    /// Mac still holds: it merges as a change to the personal record, over its base.
    func testAnOlderMacsEnvironmentSaveKeepsANewerSecretValue() async throws {
        let legacy = try seedLegacyProject()
        cloud.saveFailure = "offline"
        await macB.sync.syncNow()
        macB.tick()
        try macB.library.mutate(legacy.id) { $0.defaultEnvironment.variables[1].value = "b2" }
        cloud.saveFailure = nil
        macB.tick()
        var document = try XCTUnwrap(macB.library.document(legacy.id))
        document.defaultEnvironment.variables[0].value = "https://api2"
        var environment = try XCTUnwrap(ProjectRecordCoder.records(for: document)[legacy.environment])
        environment.schemaVersion = 1
        environment.secrets = [legacy.token.description: "old-s3cret"]
        environment.systemFields = cloud.record(legacy.environment)?.systemFields
        environment.editedAt = cloud.clock
        guard case .saved = cloud.save(environment) else {
            return XCTFail("The older Mac's save was refused")
        }

        await macB.sync.syncNow(retryingFailures: true)
        await macB.sync.syncNow()

        XCTAssertEqual(macB.library.document(legacy.id)?.defaultEnvironment.variables[0].value, "https://api2")
        XCTAssertEqual(try macB.storage.secrets.secrets(for: .project(legacy.id))[legacy.secretKey], "b2")
        XCTAssertEqual(cloud.record(legacy.personalSecrets)?.secrets?.values.sorted(), ["b2"])
    }

    /// An older Mac that saves its current values into the project's zone again, after they moved, takes back none newer
    /// here: they merge over the personal record's base.
    func testAnOlderMacsValuesSaveKeepsNewerValues() async throws {
        let legacy = try seedLegacyProject()
        await macB.sync.syncNow()
        await macB.sync.syncNow()
        XCTAssertNil(cloud.record(legacy.values))
        macB.tick()
        macB.library.currentValues.apply(["session": .value(TemplateVariable(value: "newer"))], in: legacy.scope)
        await macB.sync.syncNow()
        macB.tick()
        let built = try LibraryRecordCoder.currentValuesRecord(legacy.scope, values: ["session": .plain("abc"), "page": .plain("3")], secrets: [:])
        let saved = SyncRecord(
            id: legacy.values,
            type: .currentValues,
            payload: built.payload,
            secrets: built.secrets,
            schemaVersion: 1,
            editedAt: cloud.clock
        )
        guard case .saved = cloud.save(saved) else {
            return XCTFail("The older Mac's save was refused")
        }

        await macB.sync.syncNow()
        await macB.sync.syncNow()

        XCTAssertEqual(macB.library.currentValues.values(in: legacy.scope)["page"], .value(TemplateVariable(value: "3")))
        XCTAssertEqual(macB.library.currentValues.values(in: legacy.scope)["session"], .value(TemplateVariable(value: "newer")))
        XCTAssertNil(cloud.record(legacy.values))
    }

    /// A value this Mac's Keychain lost, which the environment's record still holds, is fetched again before the record
    /// is cleared.
    func testALostValueComesBackFromTheEnvironmentRecord() async throws {
        let legacy = try seedLegacyProject()
        cloud.saveFailure = "offline"
        await macB.sync.syncNow()
        cloud.saveFailure = nil
        try macB.storage.secrets.setSecrets([:], for: .project(legacy.id))
        macB.library.reload(legacy.id)

        await macB.sync.syncNow(retryingFailures: true)
        await macB.sync.syncNow()
        await macB.sync.syncNow()

        XCTAssertEqual(try macB.storage.secrets.secrets(for: .project(legacy.id))[legacy.secretKey], "old-s3cret")
        XCTAssertEqual(cloud.record(legacy.environment)?.secrets, [:])
    }

    /// A project a Mac before `personal` deleted leaves its personal zone behind, which the Mac that trashes it deletes;
    /// a Mac new to the account stores none of its values.
    func testAPersonalZoneGoesWithItsProject() async throws {
        let id = try await shareProject()
        XCTAssertTrue(cloud.zones.contains(.personal(id)))
        macA.tick()
        _ = cloud.save(try LibraryRecordCoder.tombstoneRecord(id))
        _ = cloud.deleteZone(.project(id))
        let macC = try SyncTestMac(cloud: cloud)
        defer { macC.cleanUp() }
        await macC.sync.start()
        await macC.sync.syncNow()

        XCTAssertNil(macC.library.project(id))
        XCTAssertEqual(try macC.storage.secrets.secrets(for: .project(id)), [:])

        await macB.sync.syncNow()

        XCTAssertNil(macB.library.project(id))
        XCTAssertFalse(cloud.zones.contains(.personal(id)))
    }

    /// A conflict on a personal record whose merge the Keychain refuses isn't sent again and again while values move.
    func testAPersonalConflictTheKeychainRefusesIsntResentEndlessly() async throws {
        let legacy = try seedLegacyProject()
        cloud.saveFailure = "offline"
        await macB.sync.syncNow()
        cloud.saveFailure = nil
        _ = cloud.saveZone(.personal(legacy.id))
        var other = LibraryRecordCoder.secretsRecord(legacy.id, legacy.scope.environmentID, keychain: [legacy.secretKey: "other"])
        other.editedAt = cloud.clock
        guard case .saved = cloud.save(other) else {
            return XCTFail("The other Mac's save was refused")
        }
        macB.storage.secrets.isFailingWrites = true
        let before = cloud.saveAttempts[legacy.personalSecrets] ?? 0

        await macB.sync.syncNow(retryingFailures: true)
        await macB.sync.syncNow()

        // Once as the failed save goes again, and at most once more as the fence's save, beside it, reconciles.
        XCTAssertLessThanOrEqual((cloud.saveAttempts[legacy.personalSecrets] ?? 0) - before, 2)
    }

    /// A Mac that never saw an older Mac's record leaves it, once values have moved, to the Macs that saw the version
    /// before it: read without that, every value would look changed, and the stale ones would win everywhere.
    func testAMacNewToAnOlderMacsRecordKeepsTheMovedValues() async throws {
        let legacy = try seedLegacyProject()
        await macB.sync.syncNow()
        await macB.sync.syncNow()
        macB.tick()
        macB.library.currentValues.apply(["session": .value(TemplateVariable(value: "newer"))], in: legacy.scope)
        await macB.sync.syncNow()
        macB.tick()
        guard case .saved = cloud.save(try legacyValues(legacy.values, session: "abc")) else {
            return XCTFail("The older Mac's save was refused")
        }
        let macC = try SyncTestMac(cloud: cloud)
        defer { macC.cleanUp() }
        await macC.sync.start()

        await macC.sync.syncNow()
        await macC.sync.syncNow()
        macB.tick()
        await macB.sync.syncNow()
        await macB.sync.syncNow()

        XCTAssertEqual(macC.library.currentValues.values(in: legacy.scope)["session"], .value(TemplateVariable(value: "newer")))
        XCTAssertEqual(macB.library.currentValues.values(in: legacy.scope)["session"], .value(TemplateVariable(value: "newer")))
    }

    /// An environment an older Mac deletes takes its personal values with it, once a Mac that synced them reconciles.
    func testValuesOfAnEnvironmentDeletedElsewhereGo() async throws {
        let id = try await shareProject()
        let staging = RequestEnvironment(name: "Staging", variables: [Variable(key: "baseUrl", value: "https://staging")])
        try macA.library.mutate(id) { $0.environments.append(staging) }
        let scope = CurrentValueScope.environment(id, staging.id)
        macA.library.currentValues.apply(["page": .value(TemplateVariable(value: "7"))], in: scope)
        await macA.sync.syncNow()
        await macB.sync.syncNow()
        XCTAssertNotNil(cloud.record(LibraryRecordCoder.currentValuesRecordID(scope)))
        macA.tick()
        _ = cloud.delete(SyncRecordID(zone: .project(id), name: staging.id.description))

        await macA.sync.syncNow()
        await macB.sync.syncNow()
        macA.tick()
        try macA.library.mutate(id) { $0.name = "Renamed" }
        await macA.sync.syncNow()
        await macB.sync.syncNow()

        XCTAssertNil(macA.library.document(id)?.environment(staging.id))
        XCTAssertNil(cloud.record(LibraryRecordCoder.currentValuesRecordID(scope)))
    }

    /// An older Mac's first values for an environment, saved in the project's zone after the fence and before it saw
    /// it, reach this Mac, which no Mac had told of the record, rather than being cleared unmerged.
    func testAnOlderMacsFirstValuesAfterTheFenceArrive() async throws {
        let legacy = try seedLegacyProject()
        await macB.sync.syncNow()
        await macB.sync.syncNow()
        XCTAssertEqual(cloud.record(legacy.header)?.schemaVersion, LibrarySync.personalSchemaVersion)
        let staging = RequestEnvironment(name: "Staging", variables: [Variable(key: "baseUrl", value: "https://staging")])
        try macB.library.mutate(legacy.id) { $0.environments.append(staging) }
        await macB.sync.syncNow()
        macB.tick()
        let scope = CurrentValueScope.environment(legacy.id, staging.id)
        let olderID = SyncRecordID(zone: .project(legacy.id), name: SyncRecordID.currentValuesPrefix + staging.id.description)
        let built = try LibraryRecordCoder.currentValuesRecord(scope, values: ["page": .plain("9")], secrets: [:])
        let written = SyncRecord(id: olderID, type: .currentValues, payload: built.payload, secrets: built.secrets, schemaVersion: 1)
        guard case .saved = cloud.save(written) else {
            return XCTFail("The older Mac's save was refused")
        }

        for _ in 0..<3 {
            macB.tick()
            await macB.sync.syncNow()
        }

        XCTAssertEqual(macB.library.currentValues.values(in: scope)["page"], .value(TemplateVariable(value: "9")))
        XCTAssertNil(cloud.record(olderID))
        XCTAssertNotNil(cloud.record(LibraryRecordCoder.currentValuesRecordID(scope)))
    }

    /// An older Mac's record that no Mac here saw the version before of changes nothing `personal` already holds for
    /// it: with no base, its stale values and its additions look alike.
    func testAnOlderMacsRecordLeavesWhatPersonalHolds() async throws {
        let legacy = try seedLegacyProject()
        await macB.sync.syncNow()
        await macB.sync.syncNow()
        let staging = RequestEnvironment(name: "Staging", variables: [Variable(key: "baseUrl", value: "https://staging")])
        try macB.library.mutate(legacy.id) { $0.environments.append(staging) }
        let scope = CurrentValueScope.environment(legacy.id, staging.id)
        macB.tick()
        macB.library.currentValues.apply(["session": .value(TemplateVariable(value: "s1", isSecret: true))], in: scope)
        await macB.sync.syncNow()
        macB.tick()
        let olderID = SyncRecordID(zone: .project(legacy.id), name: SyncRecordID.currentValuesPrefix + staging.id.description)
        let built = try LibraryRecordCoder.currentValuesRecord(scope, values: ["session": .plain("p0"), "page": .plain("9")], secrets: [:])
        let written = SyncRecord(id: olderID, type: .currentValues, payload: built.payload, secrets: built.secrets, schemaVersion: 1)
        guard case .saved = cloud.save(written) else {
            return XCTFail("The older Mac's save was refused")
        }

        await macB.sync.syncNow()
        macB.tick()
        await macB.sync.syncNow()

        XCTAssertEqual(macB.library.currentValues.values(in: scope), ["session": .value(TemplateVariable(value: "s1", isSecret: true))])
        XCTAssertNil(cloud.record(olderID))
    }

    /// A value removed after values moved doesn't come back from an older Mac's stale record, by way of a Mac that never
    /// saw the version before it.
    func testAnOlderMacsStaleRecordBringsNoRemovedValueBack() async throws {
        let legacy = try seedLegacyProject()
        await macB.sync.syncNow()
        await macB.sync.syncNow()
        macB.tick()
        macB.library.currentValues.apply(["page": .value(TemplateVariable(value: "2"))], in: legacy.scope)
        await macB.sync.syncNow()
        macB.tick()
        macB.library.currentValues.apply(["session": nil], in: legacy.scope)
        await macB.sync.syncNow()
        macB.tick()
        guard case .saved = cloud.save(try legacyValues(legacy.values, session: "abc")) else {
            return XCTFail("The older Mac's save was refused")
        }
        let macC = try SyncTestMac(cloud: cloud)
        defer { macC.cleanUp() }
        await macC.sync.start()
        macC.tick()

        await macC.sync.syncNow()
        macB.tick()
        await macB.sync.syncNow()
        await macB.sync.syncNow()

        XCTAssertNil(macC.library.currentValues.values(in: legacy.scope)["session"])
        XCTAssertNil(macB.library.currentValues.values(in: legacy.scope)["session"])
        XCTAssertEqual(macC.library.currentValues.values(in: legacy.scope)["page"], .value(TemplateVariable(value: "2")))
    }

    /// An older Mac's first values for an environment still arrive should Reqling quit between its project's zone
    /// arriving and the fetch's end, where they fill in: nothing of them was taken as agreed before.
    func testAnOlderMacsFirstValuesSurviveAQuitMidFetch() async throws {
        let legacy = try seedLegacyProject()
        await macB.sync.syncNow()
        await macB.sync.syncNow()
        let staging = RequestEnvironment(name: "Staging", variables: [Variable(key: "baseUrl", value: "https://staging")])
        try macB.library.mutate(legacy.id) { $0.environments.append(staging) }
        await macB.sync.syncNow()
        macB.tick()
        let scope = CurrentValueScope.environment(legacy.id, staging.id)
        let olderID = SyncRecordID(zone: .project(legacy.id), name: SyncRecordID.currentValuesPrefix + staging.id.description)
        let built = try LibraryRecordCoder.currentValuesRecord(scope, values: ["page": .plain("9")], secrets: [:])
        guard case .saved(let saved) = cloud.save(SyncRecord(id: olderID, type: .currentValues, payload: built.payload, schemaVersion: 1)) else {
            return XCTFail("The older Mac's save was refused")
        }

        macB.sync.transport(didFetch: SyncFetchedZone(zone: .project(legacy.id), changed: [saved], deleted: []))
        await macB.restart()
        macB.tick()
        await macB.sync.syncNow()
        macB.tick()
        await macB.sync.syncNow()

        XCTAssertEqual(macB.library.currentValues.values(in: scope)["page"], .value(TemplateVariable(value: "9")))
        XCTAssertNotNil(cloud.record(LibraryRecordCoder.currentValuesRecordID(scope)))
    }

    /// A Mac new to the account, finding an environment's record still holding the value it moved, keeps the newer one
    /// `personal` holds rather than sending the old one back as its own edit.
    func testAMacNewToTheAccountKeepsTheMovedSecretValue() async throws {
        let legacy = try seedLegacyProject()
        await macB.sync.syncNow()
        await macB.sync.syncNow()
        macB.tick()
        try macB.library.mutate(legacy.id) { $0.defaultEnvironment.variables[1].value = "b2" }
        await macB.sync.syncNow()
        XCTAssertEqual(cloud.record(legacy.personalSecrets)?.secrets?.values.sorted(), ["b2"])
        // As the server stands before B's clear goes out: the environment's record still holds what it moved.
        var environment = try XCTUnwrap(cloud.record(legacy.environment))
        environment.secrets = [legacy.token.description: "old-s3cret"]
        environment.schemaVersion = 1
        guard case .saved = cloud.save(environment) else {
            return XCTFail("The seed was refused")
        }
        macB.tick()
        let macC = try SyncTestMac(cloud: cloud)
        defer { macC.cleanUp() }
        await macC.sync.start()
        macC.tick()

        await macC.sync.syncNow()

        XCTAssertEqual(try macC.storage.secrets.secrets(for: .project(legacy.id))[legacy.secretKey], "b2")
        XCTAssertEqual(cloud.record(legacy.personalSecrets)?.secrets?.values.sorted(), ["b2"])
    }

    // MARK: - Helpers

    struct LegacyProject {
        let id: ProjectID
        let token: VariableID
        let scope: CurrentValueScope

        var header: SyncRecordID {
            SyncRecordID(zone: .project(id), name: SyncRecordID.projectName)
        }

        var environment: SyncRecordID {
            SyncRecordID(zone: .project(id), name: scope.environmentID.description)
        }

        var values: SyncRecordID {
            SyncRecordID(zone: .project(id), name: SyncRecordID.currentValuesPrefix + scope.environmentID.description)
        }

        var secretKey: String {
            SecretKey.variable(token, in: scope.environmentID)
        }

        var personalSecrets: SyncRecordID {
            LibraryRecordCoder.secretsRecordID(id, scope.environmentID)
        }
    }

    /// A project as a Mac before `personal` left it on the server: its environment's record holding its secret value,
    /// its current values in its own zone, and every record at schema 1.
    func seedLegacyProject() throws -> LegacyProject {
        let token = Variable(key: "token", value: "", isSecret: true)
        let document = ProjectDocument(
            name: "Legacy",
            defaultEnvironment: RequestEnvironment(
                name: RequestEnvironment.defaultName,
                variables: [Variable(key: "baseUrl", value: "https://api"), token]
            )
        )
        let legacy = LegacyProject(id: document.id, token: token.id, scope: .environment(document.id, document.defaultEnvironment.id))
        _ = cloud.saveZone(.project(document.id))
        for var record in try ProjectRecordCoder.records(for: document).values {
            record.schemaVersion = 1
            record.secrets = record.type == .environment ? [token.id.description: "old-s3cret"] : nil
            _ = cloud.save(record)
        }
        _ = cloud.save(try legacyValues(legacy.values, session: "abc"))
        return legacy
    }

    /// Current values as a Mac before `personal` saved them in a project's zone, over the server's version if any.
    func legacyValues(_ id: SyncRecordID, session: String) throws -> SyncRecord {
        let scope = try XCTUnwrap(LibraryRecordCoder.scope(of: id))
        let built = try LibraryRecordCoder.currentValuesRecord(scope, values: ["session": .plain(session)], secrets: [:])
        return SyncRecord(
            id: id,
            type: .currentValues,
            payload: built.payload,
            secrets: built.secrets,
            schemaVersion: 1,
            systemFields: cloud.record(id)?.systemFields
        )
    }
}
