import Foundation
@testable import ReqlingKit
import ReqlingTemplating
import XCTest

/// Each project's `personal` zone: this person's secret values and current values, kept out of the project's own zone
/// so it can be shared, whichever of the two zones a Mac fetches first.
extension LibrarySyncTests {
    func testSecretAndCurrentValuesStayOutOfTheProjectsZone() async throws {
        let id = try await shareProject()
        let defaultID = try XCTUnwrap(macA.library.document(id)).defaultEnvironment.id
        let scope = CurrentValueScope.environment(id, defaultID)
        macA.library.currentValues.apply([
            "session": .value(TemplateVariable(value: "abc", isSecret: true)),
            "page": .value(TemplateVariable(value: "2"))
        ], in: scope)
        await macA.sync.syncNow()
        await macB.sync.syncNow()

        let projectRecords = cloud.records.values.filter { $0.id.zone == .project(id) }
        XCTAssertFalse(projectRecords.isEmpty)
        for record in projectRecords {
            XCTAssertNotEqual(record.type, .currentValues, record.id.description)
            XCTAssertEqual(record.secrets ?? [:], [:], record.id.description)
        }
        XCTAssertEqual(cloud.record(LibraryRecordCoder.secretsRecordID(id, defaultID))?.secrets?.values.sorted(), ["s3cret"])
        XCTAssertEqual(cloud.record(LibraryRecordCoder.currentValuesRecordID(scope))?.secrets?.values.sorted(), ["abc"])
        XCTAssertEqual(macB.library.currentValues.values(in: scope)["session"], .value(TemplateVariable(value: "abc", isSecret: true)))
        XCTAssertEqual(macB.library.currentValues.values(in: scope)["page"], .value(TemplateVariable(value: "2")))
    }

    /// Values for a project not listed here yet are kept for it, and fill it in as it arrives, since the test cloud,
    /// by name, delivers a `personal-` zone before its `project-` one; values that arrive later fill in the listed one.
    func testPersonalValuesFillTheProjectInWhicheverArrivesFirst() async throws {
        let id = try await shareProject()
        let defaultID = try XCTUnwrap(macA.library.document(id)).defaultEnvironment.id
        let macC = try SyncTestMac(cloud: cloud)
        defer { macC.cleanUp() }
        await macC.sync.start()

        await macC.sync.syncNow()

        XCTAssertEqual(macC.library.document(id)?.environment(defaultID)?.variables.last?.value, "s3cret")

        try macA.library.mutate(id) { $0.defaultEnvironment.variables[1].value = "rotated" }
        await macA.sync.syncNow()
        await macC.sync.syncNow()

        XCTAssertEqual(macC.library.document(id)?.environment(defaultID)?.variables.last?.value, "rotated")
        XCTAssertEqual(try macC.storage.secrets.secrets(for: .project(id)).values.sorted(), ["rotated"])
        XCTAssertFalse(try macC.storage.contents("environments/default.json", in: id).contains("rotated"))
    }

    /// Values for an environment a Mac doesn't have yet, arriving before the environment does, are kept: dropped, the
    /// next reconcile would delete them everywhere.
    func testValuesForANewEnvironmentSurviveArrivingFirst() async throws {
        let id = try await shareProject()
        let staging = RequestEnvironment(name: "Staging", variables: [Variable(key: "baseUrl", value: "https://staging")])
        try macA.library.mutate(id) { $0.environments.append(staging) }
        let scope = CurrentValueScope.environment(id, staging.id)
        macA.library.currentValues.apply(["page": .value(TemplateVariable(value: "7"))], in: scope)
        await macA.sync.syncNow()
        await macB.sync.syncNow()

        XCTAssertEqual(macB.library.currentValues.values(in: scope)["page"], .value(TemplateVariable(value: "7")))

        macB.tick()
        try macB.library.mutate(id) { $0.name = "Renamed" }
        await macB.sync.syncNow()
        macA.tick()
        await macA.sync.syncNow()

        XCTAssertNotNil(cloud.record(LibraryRecordCoder.currentValuesRecordID(scope)))
        XCTAssertEqual(macA.library.currentValues.values(in: scope)["page"], .value(TemplateVariable(value: "7")))
    }

    /// Values for an environment that hasn't arrived here yet, as when its project's zone failed to fetch, survive a
    /// reconcile meanwhile, which would otherwise read them as gone and delete them everywhere.
    func testValuesForAnEnvironmentNotHereYetSurviveAReconcile() async throws {
        let id = try await shareProject()
        let staging = RequestEnvironment(name: "Staging", variables: [Variable(key: "token", value: "staging-s3cret", isSecret: true)])
        try macA.library.mutate(id) { $0.environments.append(staging) }
        let scope = CurrentValueScope.environment(id, staging.id)
        macA.library.currentValues.apply(["page": .value(TemplateVariable(value: "7"))], in: scope)
        await macA.sync.syncNow()
        macB.transport.dropsZoneOnce = .project(id)
        macB.transport.fallsShort = true
        await macB.sync.syncNow()
        XCTAssertNil(macB.library.document(id)?.environment(staging.id))

        macB.tick()
        try macB.library.mutate(id) { $0.name = "Renamed" }
        await macB.sync.syncNow()

        XCTAssertEqual(cloud.record(LibraryRecordCoder.secretsRecordID(id, staging.id))?.secrets?.values.sorted(), ["staging-s3cret"])
        XCTAssertNotNil(cloud.record(LibraryRecordCoder.currentValuesRecordID(scope)))

        macB.transport.fallsShort = false
        await macB.sync.syncNow(retryingFailures: true)

        XCTAssertEqual(macB.library.document(id)?.environment(staging.id)?.variables.first?.value, "staging-s3cret")
        XCTAssertEqual(macB.library.currentValues.values(in: scope)["page"], .value(TemplateVariable(value: "7")))
    }

    /// A variable made secret elsewhere, whose value arrives in `personal` before the project's change does, loads with
    /// its value rather than blank.
    func testANewSecretVariableArrivesWithItsValue() async throws {
        let id = try await shareProject()
        try macA.library.mutate(id) { $0.defaultEnvironment.variables.append(Variable(key: "apiKey", value: "k3y", isSecret: true)) }
        await macA.sync.syncNow()
        await macB.sync.syncNow()

        XCTAssertTrue(try macB.storage.secrets.secrets(for: .project(id)).values.contains("k3y"))
        XCTAssertEqual(macB.library.document(id)?.defaultEnvironment.variables.last?.value, "k3y")
    }

    /// Secret values that land before the change making their variable secret do are kept through a reconcile here
    /// meanwhile, which sees no secret variable in the environment yet.
    func testAVariableMadeSecretKeepsItsPersonalRecord() async throws {
        let id = try await shareProject()
        let staging = RequestEnvironment(name: "Staging", variables: [Variable(key: "key", value: "plain")])
        try macA.library.mutate(id) { $0.environments.append(staging) }
        await macA.sync.syncNow()
        await macB.sync.syncNow()
        macA.tick()
        try macA.library.mutate(id) { document in
            document.updateEnvironment(staging.id) { environment in
                environment.variables[0].isSecret = true
                environment.variables[0].value = "k3y"
            }
        }
        let personal = LibraryRecordCoder.secretsRecordID(id, staging.id)
        macA.transport.sendBatch(limit: 1)
        XCTAssertNotNil(cloud.record(personal), "The personal record goes first")

        await macB.sync.syncNow()
        macB.tick()
        try macB.library.mutate(id) { $0.name = "Renamed on B" }
        await macA.sync.syncNow()
        macB.tick()
        await macB.sync.syncNow()

        XCTAssertNotNil(cloud.record(personal))
        XCTAssertEqual(macB.library.document(id)?.environment(staging.id)?.variables.first?.value, "k3y")
    }
}
