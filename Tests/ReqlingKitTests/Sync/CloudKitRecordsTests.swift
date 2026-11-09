import CloudKit
import Foundation
@testable import ReqlingKit
import XCTest

/// Records as CloudKit holds them: every field an encrypted value under its fixed name, and what each send failure
/// tells sync to do. No container is touched, so these run without iCloud.
final class CloudKitRecordsTests: XCTestCase {
    private let project = ProjectID()

    func testARecordRoundTripsThroughItsEncryptedFields() throws {
        let record = SyncRecord(
            id: SyncRecordID(zone: .project(project), name: RequestNodeID().description),
            type: .request,
            payload: try OrderedJSONParser.parse(#"{"name": "List users", "order": 2, "tags": ["a", "b"]}"#),
            secrets: ["token": "s3cret", "apiKey": "k"],
            formatVersion: 3,
            schemaVersion: 4,
            editedAt: Date(timeIntervalSince1970: 1_000)
        )

        let ckRecord = CloudKitRecords.ckRecord(record)
        let read = try XCTUnwrap(CloudKitRecords.syncRecord(ckRecord))

        XCTAssertEqual(ckRecord.recordType, "Request")
        XCTAssertEqual(ckRecord.recordID.zoneID.zoneName, "project-\(project)")
        XCTAssertEqual(Set(ckRecord.allKeys()), ["payload", "secrets", "formatVersion", "syncSchemaVersion", "editedAt"])
        XCTAssertEqual(Set(ckRecord.encryptedValues.allKeys()), Set(ckRecord.allKeys()), "Every field encrypted")
        XCTAssertTrue(ckRecord.allKeys().allSatisfy { ckRecord[$0] == nil }, "None readable as a plain field")
        XCTAssertEqual(ckRecord.encryptedValues["payload"] as? String, #"{"name":"List users","order":2,"tags":["a","b"]}"#)
        XCTAssertEqual(read.id, record.id)
        XCTAssertEqual(read.type, record.type)
        XCTAssertEqual(read.payload, record.payload)
        XCTAssertEqual(read.secrets, record.secrets)
        XCTAssertEqual(read.formatVersion, 3)
        XCTAssertEqual(read.schemaVersion, 4)
        XCTAssertEqual(read.editedAt, record.editedAt)
        XCTAssertNotNil(read.systemFields)
    }

    /// No secrets sends no field, so the server keeps its values; a Mac that couldn't read its Keychain blanks nothing.
    func testNoSecretsLeavesTheFieldOut() throws {
        let record = SyncRecord(id: SyncRecordID(zone: .library, name: SyncRecordID.globalName), type: .globalEnvironment, payload: .object([]))

        let ckRecord = CloudKitRecords.ckRecord(record)

        XCTAssertNil(ckRecord.encryptedValues["secrets"])
        XCTAssertNil(try XCTUnwrap(CloudKitRecords.syncRecord(ckRecord)).secrets)
    }

    /// A save over a known version starts from it, so the server checks it, and keeps its identity.
    func testASaveStartsFromTheServersVersion() throws {
        let id = SyncRecordID(zone: .project(project), name: SyncRecordID.projectName)
        let server = CKRecord(recordType: "Project", recordID: CloudKitRecords.recordID(id))
        var record = SyncRecord(id: id, type: .project, payload: .object([]))
        record.systemFields = CloudKitRecords.archive(server)

        let ckRecord = CloudKitRecords.ckRecord(record)

        XCTAssertEqual(ckRecord.recordID, server.recordID)
        XCTAssertEqual(ckRecord.recordType, "Project")
    }

    /// What this version can't read arrives as from a newer one, holding its project back, never dropped.
    func testAnUnknownTypeOrMissingVersionReadsAsNewer() throws {
        let zone = CloudKitRecords.zoneID(.project(project))
        let unknown = CKRecord(recordType: "Collection", recordID: CKRecord.ID(recordName: "x", zoneID: zone))
        unknown.encryptedValues["payload"] = "{}"
        unknown.encryptedValues["formatVersion"] = 1
        unknown.encryptedValues["syncSchemaVersion"] = 1
        let unversioned = CKRecord(recordType: "Request", recordID: CKRecord.ID(recordName: RequestNodeID().description, zoneID: zone))
        unversioned.encryptedValues["payload"] = "not json"

        let readUnknown = try XCTUnwrap(CloudKitRecords.syncRecord(unknown))
        let readUnversioned = try XCTUnwrap(CloudKitRecords.syncRecord(unversioned))

        XCTAssertEqual(readUnknown.schemaVersion, .max)
        XCTAssertEqual(readUnversioned.schemaVersion, .max)
        XCTAssertEqual(readUnversioned.payload, .null, "Unreadable, so it fails to decode rather than reading as empty")
    }

    func testARecordInAZoneReqlingNeverWritesIsIgnored() {
        let foreign = CKRecord(recordType: "Request", recordID: CKRecord.ID(recordName: "x", zoneID: CKRecordZone.ID(zoneName: "other")))

        XCTAssertNil(CloudKitRecords.syncRecord(foreign))
    }

    /// Each failure says what sync does instead: merge, create the zone, resend, or keep the item here.
    func testSaveFailuresMapToWhatSyncDoesNext() throws {
        let id = SyncRecordID(zone: .project(project), name: SyncRecordID.projectName)
        let sent = CloudKitRecords.ckRecord(SyncRecord(id: id, type: .project, payload: .object([])))
        let changed = CKError(.serverRecordChanged, userInfo: [CKRecordChangedErrorServerRecordKey: sent])
        func result(_ code: CKError.Code, _ record: CKRecord = sent) -> SyncSendResult {
            CloudKitSendResults.saveFailure(of: id, record, CKError(code))
        }

        guard case .conflict(let conflicted, let serverRecord) = CloudKitSendResults.saveFailure(of: id, sent, changed) else {
            return XCTFail("Expected a conflict")
        }
        XCTAssertEqual(conflicted, id)
        XCTAssertEqual(serverRecord.id, id)
        guard case .zoneMissing = result(.zoneNotFound), case .missingOnServer = result(.unknownItem) else {
            return XCTFail("Expected a missing zone and a record missing on the server")
        }
        guard case .failed = result(.userDeletedZone) else {
            return XCTFail("A zone deleted in System Settings is never made again from here")
        }
        guard case .failed(_, let message) = result(.quotaExceeded), case .failed = result(.batchRequestFailed) else {
            return XCTFail("Expected failures, sent again on the next sync")
        }
        XCTAssertEqual(message, "Your iCloud storage is full, so some changes stay on this Mac. Make room, then choose Sync Now.")
    }

    /// Only a record too large on its own stays here; one whose batch overflowed is sent again.
    func testOnlyARecordTooLargeOnItsOwnStaysHere() {
        let id = SyncRecordID(zone: .project(project), name: SyncRecordID.projectName)
        let small = CloudKitRecords.ckRecord(SyncRecord(id: id, type: .project, payload: .string("small")))
        let large = CloudKitRecords.ckRecord(SyncRecord(id: id, type: .project, payload: .string(String(repeating: "x", count: 1_100_000))))

        guard case .tooLarge = CloudKitSendResults.saveFailure(of: id, large, CKError(.limitExceeded)),
              case .failed = CloudKitSendResults.saveFailure(of: id, small, CKError(.limitExceeded)),
              case .tooLarge = CloudKitSendResults.saveFailure(of: id, small, CKError(.limitExceeded), alone: true) else {
            return XCTFail("Expected the large record, or one refused alone, kept here, and the small one sent again")
        }
    }

    /// Errors read in fixed words, never their `userInfo`, which can carry server records.
    func testAnErrorDescribesItselfWithoutItsDetails() {
        let error = CKError(.internalError, userInfo: [NSLocalizedDescriptionKey: "payload: s3cret"])

        let code = CKError.Code.internalError.rawValue
        XCTAssertEqual(CloudKitRecords.describe(error), "iCloud refused a change (error \(code)). Sync Now tries again.")
    }
}
