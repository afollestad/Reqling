import CloudKit
import Foundation

/// How a `SyncRecord` maps onto a `CKRecord`: every field an encrypted value under a fixed name, so CloudKit's plaintext
/// schema holds only these names, record types, and IDs, and Apple sees no project content or secret.
///
/// The names are permanent once deployed to Production, which can never lose a field; add new ones rather than
/// renaming these.
enum CloudKitRecords {
    static let payloadField = "payload"
    static let secretsField = "secrets"
    static let formatVersionField = "formatVersion"
    static let schemaVersionField = "syncSchemaVersion"
    static let editedAtField = "editedAt"

    /// The largest record the server takes.
    static let recordByteLimit = 1_000_000
    /// What a batch may carry: under the server's limits of 250 records and 2 MB a request, since an estimate is all a
    /// batch can go by before the fields are encrypted.
    static let batchItemLimit = 200
    static let batchByteLimit = 1_500_000
    /// What a deletion counts for in a batch: its record's ID alone.
    static let deletionSize = 256

    /// About how many bytes `record` sends: its fields' text, and room for its ID, system fields, and encryption.
    static func estimatedSize(_ record: CKRecord) -> Int {
        let values = record.encryptedValues
        let text = [payloadField, secretsField].compactMap { values[$0] as? String }.reduce(0) { $0 + $1.utf8.count }
        return text + 1_024
    }

    /// `zone` as this account's own, or, with `owner`, as the shared database names another person's.
    static func zoneID(_ zone: SyncZone, owner: String = CKCurrentUserDefaultName) -> CKRecordZone.ID {
        CKRecordZone.ID(zoneName: zone.name, ownerName: owner)
    }

    static func recordID(_ id: SyncRecordID, owner: String = CKCurrentUserDefaultName) -> CKRecord.ID {
        CKRecord.ID(recordName: id.name, zoneID: zoneID(id.zone, owner: owner))
    }

    /// `nil` for a zone Reqling never writes, which is ignored rather than acted on.
    static func syncID(_ id: CKRecord.ID) -> SyncRecordID? {
        SyncZone(name: id.zoneID.zoneName).map { SyncRecordID(zone: $0, name: id.recordName) }
    }

    /// The record to save: the server's last version when this Mac knows it (`systemFields`), so the save is checked
    /// against it, with this Mac's fields set over it. `secrets` is set only when present, so a save without it leaves the
    /// server's in place.
    static func ckRecord(_ record: SyncRecord, owner: String = CKCurrentUserDefaultName) -> CKRecord {
        let ckRecord = record.systemFields.flatMap(unarchive)
            ?? CKRecord(recordType: record.type.rawValue, recordID: recordID(record.id, owner: owner))
        let values = ckRecord.encryptedValues
        values[payloadField] = record.payload.compactText()
        if let secrets = record.secrets {
            values[secretsField] = OrderedJSON.object(secrets.sorted { $0.key < $1.key }.map {
                OrderedJSONMember(key: $0.key, value: .string($0.value))
            }).compactText()
        }
        values[formatVersionField] = record.formatVersion
        values[schemaVersionField] = record.schemaVersion
        values[editedAtField] = record.editedAt
        return ckRecord
    }

    /// `share` as sync reads it, for `zone`.
    static func shareInfo(_ share: CKShare, zone: SyncZone) -> SyncShareInfo {
        let current = share.currentUserParticipant
        let isOwner = current?.role == .owner
        return SyncShareInfo(
            zone: zone,
            owner: share.recordID.zoneID.ownerName,
            isOwner: isOwner,
            permission: isOwner || current?.permission == .readWrite ? .readWrite : .readOnly,
            canInvite: isOwner || current?.role == .administrator,
            participantCount: share.participants.filter { $0.role != .owner }.count,
            byLink: share.publicPermission != .none,
            title: share[CKShare.SystemFieldKey.title] as? String,
            ownerName: ownerName(of: share)
        )
    }

    /// The owner's name as their Apple Account gives it, or `nil` when CloudKit gives none: a participant's copy of a
    /// share can carry empty name parts, which would read as a blank name.
    private static func ownerName(of share: CKShare) -> String? {
        let name = share.owner.userIdentity.nameComponents.map { PersonNameComponentsFormatter().string(from: $0) }
        return name?.isEmpty == false ? name : nil
    }

    /// Whether `recordType` is CloudKit's share record, which a shared zone holds beside Reqling's own. It says who the
    /// zone is shared with, not what the project holds; read as one of its records, its unknown type would hold the
    /// project back on every Mac, as from a newer version, and an update would never bring it in.
    static func isShare(_ recordType: CKRecord.RecordType) -> Bool {
        recordType == CKRecord.SystemType.share
    }

    /// The record as sync reads it, or `nil` for one in a zone Reqling never writes, or a share (`isShare`). One whose
    /// type or versions this version can't read arrives as from a newer version, so its project is held back rather
    /// than half understood; a payload that won't parse arrives as one that won't decode, which holds it back until the
    /// next launch.
    static func syncRecord(_ ckRecord: CKRecord) -> SyncRecord? {
        guard !isShare(ckRecord.recordType), let id = syncID(ckRecord.recordID) else {
            return nil
        }
        let values = ckRecord.encryptedValues
        let type = SyncRecordType(rawValue: ckRecord.recordType)
        let payload = (values[payloadField] as? String).flatMap { try? OrderedJSONParser.parse($0) } ?? .null
        return SyncRecord(
            id: id,
            // A type this version doesn't know is only ever held back, by its versions, so this one stands in.
            type: type ?? .currentValues,
            payload: payload,
            secrets: (values[secretsField] as? String).flatMap(secrets),
            formatVersion: type == nil ? .max : (values[formatVersionField] as? Int) ?? .max,
            schemaVersion: type == nil ? .max : (values[schemaVersionField] as? Int) ?? .max,
            editedAt: (values[editedAtField] as? Date) ?? ckRecord.modificationDate ?? .distantPast,
            systemFields: archive(ckRecord),
            serverModifiedAt: ckRecord.modificationDate
        )
    }

    /// A secrets field that won't parse reads as absent, which leaves this Mac's values as they are.
    private static func secrets(_ text: String) -> [String: String]? {
        guard case .object(let members) = try? OrderedJSONParser.parse(text) else {
            return nil
        }
        var secrets: [String: String] = [:]
        for member in members {
            guard case .string(let value) = member.value else {
                return nil
            }
            secrets[member.key] = value
        }
        return secrets
    }

    static func archive(_ record: CKRecord) -> Data {
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: archiver)
        archiver.finishEncoding()
        return archiver.encodedData
    }

    private static func unarchive(_ data: Data) -> CKRecord? {
        guard let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: data) else {
            return nil
        }
        unarchiver.requiresSecureCoding = true
        defer { unarchiver.finishDecoding() }
        return CKRecord(coder: unarchiver)
    }

    /// Fixed words for each error, never its `userInfo`, which can carry server records.
    static func describe(_ error: any Error) -> String {
        guard let error = error as? CKError else {
            return "Reqling couldn't sync with iCloud."
        }
        switch error.code {
        case .networkUnavailable, .networkFailure:
            return "Reqling couldn't reach iCloud. It tries again when it's back online."
        case .serviceUnavailable, .requestRateLimited, .zoneBusy:
            return "iCloud is busy. Reqling tries again shortly."
        case .quotaExceeded:
            return "Your iCloud storage is full, so some changes stay on this Mac. Make room, then choose Sync Now."
        case .notAuthenticated:
            return "Sign in to iCloud in System Settings to sync."
        case .accountTemporarilyUnavailable:
            return "Your iCloud account is unavailable for now. Reqling tries again later."
        default:
            return "iCloud refused a change (error \(error.code.rawValue)). Sync Now tries again."
        }
    }
}

/// What the engine reports sending, as sync reads it. The engine drops a failed change from its queue unless the error
/// was a passing one, so each failure says what sync must do instead (`LibrarySync.handleSent`), which sends anything
/// merely failed again on its next sync.
enum CloudKitSendResults {
    /// `alone` when one record was all that was sent, so a refusal as too large is its own.
    static func results(_ sent: CKSyncEngine.Event.SentRecordZoneChanges, alone: Bool = false) -> [SyncSendResult] {
        var results = sent.savedRecords.compactMap { CloudKitRecords.syncRecord($0).map(SyncSendResult.saved) }
        for failure in sent.failedRecordSaves {
            if let id = CloudKitRecords.syncID(failure.record.recordID) {
                results.append(saveFailure(of: id, failure.record, failure.error, alone: alone))
            }
        }
        results += sent.deletedRecordIDs.compactMap { CloudKitRecords.syncID($0).map(SyncSendResult.deleted) }
        for (recordID, error) in sent.failedRecordDeletes {
            guard let id = CloudKitRecords.syncID(recordID) else {
                continue
            }
            // Already gone, with its zone or alone, is as good as deleted.
            let isGone = [.unknownItem, .zoneNotFound, .userDeletedZone].contains(error.code)
            if isGone {
                results.append(.deleted(id))
            } else {
                results.append(error.code == .permissionFailure ? .permissionDenied(id) : .failed(id, CloudKitRecords.describe(error)))
            }
        }
        return results
    }

    static func results(_ sent: CKSyncEngine.Event.SentDatabaseChanges) -> [SyncSendResult] {
        var results = sent.savedZones.compactMap { SyncZone(name: $0.zoneID.zoneName).map(SyncSendResult.zoneSaved) }
        results += sent.failedZoneSaves.compactMap { failure in
            SyncZone(name: failure.zone.zoneID.zoneName).map { .zoneSaveFailed($0, CloudKitRecords.describe(failure.error)) }
        }
        results += sent.deletedZoneIDs.compactMap { SyncZone(name: $0.zoneName).map(SyncSendResult.zoneDeleted) }
        for (zoneID, error) in sent.failedZoneDeletes {
            guard let zone = SyncZone(name: zoneID.zoneName) else {
                continue
            }
            let isGone = [.zoneNotFound, .userDeletedZone].contains(error.code)
            results.append(isGone ? .zoneDeleted(zone) : .failed(nil, CloudKitRecords.describe(error)))
        }
        return results
    }

    /// What a save that failed asks of sync. Only a record too large on its own is kept here for good; one that merely
    /// overflowed its batch, as another in it can make it, is sent again (`CloudKitSyncTransport` shrinks the next).
    static func saveFailure(of id: SyncRecordID, _ record: CKRecord, _ error: CKError, alone: Bool = false) -> SyncSendResult {
        switch error.code {
        case .serverRecordChanged:
            guard let server = error.serverRecord.flatMap(CloudKitRecords.syncRecord) else {
                return .failed(id, CloudKitRecords.describe(error))
            }
            return .conflict(id, server: server)
        case .zoneNotFound:
            return .zoneMissing(id)
        case .userDeletedZone:
            // Deleted in System Settings, which the next fetch reports as purged: never made again from here.
            return .failed(id, CloudKitRecords.describe(error))
        case .unknownItem:
            return .missingOnServer(id)
        case .limitExceeded where alone || CloudKitRecords.estimatedSize(record) > CloudKitRecords.recordByteLimit:
            return .tooLarge(id)
        case .permissionFailure:
            return .permissionDenied(id)
        default:
            return .failed(id, CloudKitRecords.describe(error))
        }
    }

    static func reason(_ reason: CKDatabase.DatabaseChange.Deletion.Reason) -> SyncZoneDeletionReason {
        switch reason {
        case .deleted: .deleted
        case .purged: .purged
        case .encryptedDataReset: .encryptedDataReset
        @unknown default: .deleted
        }
    }
}
