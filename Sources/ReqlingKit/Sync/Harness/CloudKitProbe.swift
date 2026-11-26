#if DEBUG
import CloudKit
import Foundation

/// Raw CloudKit sharing, for the end-to-end harness to learn what the server does (`scripts/sharing-e2e.sh`): who may
/// write, what a zone's deletion reports to each side, what a share record looks like as a fetch delivers it. It works
/// only in zones named `probe-…`, which sync never reads (`SyncZone(name:)`), so it can't touch a project.
///
/// Debug builds only, and only in the harness's own container, never the app's.
@MainActor
public final class CloudKitProbe {
    public static let zonePrefix = "probe-"
    static let recordType = "ProbeRecord"
    static let payloadField = "payload"

    private let containerIdentifier: String
    /// Made on first use, so building the harness's tools doesn't need the iCloud entitlement, as in tests.
    private lazy var container = CKContainer(identifier: containerIdentifier)
    private var shares: HarnessShares {
        HarnessShares(container: container)
    }
    /// Where each database's changes were last read, so `changes` reports only what's new.
    private var tokens: [CKDatabase.Scope: CKServerChangeToken] = [:]
    private var zoneTokens: [CKRecordZone.ID: CKServerChangeToken] = [:]

    public init(containerIdentifier: String) {
        self.containerIdentifier = containerIdentifier
    }

    /// Whose account this is.
    func identity() async throws -> [String: String] {
        let status = try await container.accountStatus()
        let user = status == .available ? try await container.userRecordID().recordName : ""
        return ["accountStatus": "\(status.rawValue)", "user": user]
    }

    // MARK: - Owning

    /// A new zone holding one record with an encrypted field, shared zone-wide with `publicPermission`, and with `invite`
    /// as a participant when given. Returns the zone and the share's URL.
    func share(publicPermission: CKShare.ParticipantPermission, invite: Invitation?) async throws -> [String: String] {
        let zoneID = CKRecordZone.ID(zoneName: Self.zonePrefix + UUID().uuidString.lowercased(), ownerName: CKCurrentUserDefaultName)
        let database = container.privateCloudDatabase
        _ = try await database.modifyRecordZones(saving: [CKRecordZone(zoneID: zoneID)], deleting: [])
        let record = CKRecord(recordType: Self.recordType, recordID: CKRecord.ID(recordName: "first", zoneID: zoneID))
        record.encryptedValues[Self.payloadField] = "written by the owner"
        let share = CKShare(recordZoneID: zoneID)
        share[CKShare.SystemFieldKey.title] = "Probe"
        share.publicPermission = publicPermission
        if let invite {
            share.addParticipant(try await shares.participant(invite))
        }
        let results = try await database.modifyRecords(saving: [record, share], deleting: [])
        let saved = try results.saveResults[share.recordID]?.get() as? CKShare
        return ["zone": zoneID.zoneName, "url": saved?.url?.absoluteString ?? ""]
    }

    /// Changes the share of `zone`, owned by `owner` (`nil` for this account's own): its public permission, and a
    /// participant to add or change. As an administrator, this is how a participant invites.
    func updateShare(zone: String, owner: String?, publicPermission: CKShare.ParticipantPermission?, invite: Invitation?) async throws {
        let (database, zoneID) = place(zone, owner: owner)
        try await shares.update(zoneID, in: database, publicPermission: publicPermission, invite: invite)
    }

    func removeParticipant(zone: String, email: String) async throws {
        try await shares.removeParticipant(email, from: CKRecordZone.ID(zoneName: zone, ownerName: CKCurrentUserDefaultName))
    }

    /// Deletes `zone`'s share, as the owner: sharing stops for everyone.
    func stopSharing(zone: String) async throws {
        try await shares.stopSharing(CKRecordZone.ID(zoneName: zone, ownerName: CKCurrentUserDefaultName))
    }

    func deleteZone(_ zone: String) async throws {
        let zoneID = CKRecordZone.ID(zoneName: zone, ownerName: CKCurrentUserDefaultName)
        _ = try await container.privateCloudDatabase.modifyRecordZones(saving: [], deleting: [zoneID]).deleteResults[zoneID]?.get()
    }

    /// Deletes every probe zone this account owns.
    func reset() async throws -> Int {
        let database = container.privateCloudDatabase
        let zones = try await database.allRecordZones().map(\.zoneID).filter { $0.zoneName.hasPrefix(Self.zonePrefix) }
        if !zones.isEmpty {
            _ = try await database.modifyRecordZones(saving: [], deleting: zones)
        }
        tokens = [:]
        zoneTokens = [:]
        return zones.count
    }

    // MARK: - Participating

    /// The share of `zone`, a probe's or a project's, as the server holds it now, owned by `owner` (`nil` for this
    /// account's own): the link's permission, and each participant's role, permission, and acceptance, but not who
    /// they are.
    func participants(zone: String, owner: String?) async throws -> (publicPermission: String, participants: [[String: String]]) {
        let (database, zoneID) = place(zone, owner: owner)
        let share = try await shares.share(in: zoneID, of: database)
        let participants = share.participants.map { participant in
            [
                "role": Self.describe(participant.role),
                "permission": Self.describe(participant.permission),
                "acceptance": Self.describe(participant.acceptanceStatus)
            ]
        }
        return (Self.describe(share.publicPermission), participants)
    }

    /// Accepts the share at `url`, and says how this account takes part.
    func accept(_ url: URL) async throws -> [String: String] {
        let metadata = try await container.shareMetadata(for: url)
        let share = try await container.accept(metadata)
        let current = share.currentUserParticipant
        return [
            "zone": share.recordID.zoneID.zoneName,
            "owner": share.recordID.zoneID.ownerName,
            "role": current.map { Self.describe($0.role) } ?? "none",
            "permission": current.map { Self.describe($0.permission) } ?? "none",
            "publicPermission": Self.describe(share.publicPermission)
        ]
    }

    /// Deletes this account's place in `zone`'s share, as a participant: leaving it.
    func leave(zone: String, owner: String) async throws {
        try await shares.leave(CKRecordZone.ID(zoneName: zone, ownerName: owner))
    }

    // MARK: - Either side

    /// Saves a record into `zone`; the error code when the server refuses, as for a read-only participant.
    func write(zone: String, owner: String?) async -> String {
        let (database, zoneID) = place(zone, owner: owner)
        let record = CKRecord(recordType: Self.recordType, recordID: CKRecord.ID(recordName: UUID().uuidString, zoneID: zoneID))
        record.encryptedValues[Self.payloadField] = "written by \(owner == nil ? "the owner" : "a participant")"
        do {
            _ = try await database.modifyRecords(saving: [record], deleting: []).saveResults[record.recordID]?.get()
            return "saved"
        } catch {
            return Self.describe(error)
        }
    }

    /// Each record in `zone`, and whether its encrypted field could be read.
    func read(zone: String, owner: String?) async throws -> [[String: String]] {
        let (database, zoneID) = place(zone, owner: owner)
        let changes = try await database.recordZoneChanges(inZoneWith: zoneID, since: nil)
        return changes.modificationResultsByID.map { id, result in
            switch result {
            case .success(let modification):
                let record = modification.record
                return [
                    "name": id.recordName,
                    "type": record.recordType,
                    "payload": (record.encryptedValues[Self.payloadField] as? String) ?? "(unreadable)"
                ]
            case .failure(let error):
                return ["name": id.recordName, "error": Self.describe(error)]
            }
        }
    }

    /// What changed in `scope`'s database since the last call: zones changed and deleted, with each deletion's reason,
    /// and each changed zone's records, share records included, as a fetch delivers them.
    func changes(in scope: CKDatabase.Scope) async throws -> [String: [[String: String]]] {
        let database = scope == .shared ? container.sharedCloudDatabase : container.privateCloudDatabase
        var zones: [[String: String]] = []
        var deletions: [[String: String]] = []
        var records: [[String: String]] = []
        var moreComing = true
        while moreComing {
            let changes = try await database.databaseChanges(since: tokens[scope])
            tokens[scope] = changes.changeToken
            moreComing = changes.moreComing
            for deletion in changes.deletions where deletion.zoneID.zoneName.hasPrefix(Self.zonePrefix) {
                deletions.append(["zone": deletion.zoneID.zoneName, "owner": deletion.zoneID.ownerName, "reason": Self.describe(deletion.reason)])
            }
            for modification in changes.modifications where modification.zoneID.zoneName.hasPrefix(Self.zonePrefix) {
                let zoneID = modification.zoneID
                zones.append(["zone": zoneID.zoneName, "owner": zoneID.ownerName])
                let zoneChanges = try await database.recordZoneChanges(inZoneWith: zoneID, since: zoneTokens[zoneID])
                zoneTokens[zoneID] = zoneChanges.changeToken
                for (id, result) in zoneChanges.modificationResultsByID {
                    let type = (try? result.get().record.recordType) ?? "(failed)"
                    records.append(["zone": zoneID.zoneName, "name": id.recordName, "type": type, "change": "modified"])
                }
                for deletion in zoneChanges.deletions {
                    records.append(["zone": zoneID.zoneName, "name": deletion.recordID.recordName, "type": deletion.recordType, "change": "deleted"])
                }
            }
        }
        return ["zones": zones, "zoneDeletions": deletions, "records": records]
    }

    // MARK: - Helpers

    typealias Invitation = HarnessShares.Invitation

    /// The database and zone ID for `zone`: this account's own, or, with `owner`, one shared with it.
    private func place(_ zone: String, owner: String?) -> (CKDatabase, CKRecordZone.ID) {
        guard let owner else {
            return (container.privateCloudDatabase, CKRecordZone.ID(zoneName: zone, ownerName: CKCurrentUserDefaultName))
        }
        return (container.sharedCloudDatabase, CKRecordZone.ID(zoneName: zone, ownerName: owner))
    }

    static func describe(_ error: any Error) -> String {
        guard let error = error as? CKError else {
            return "error: \(type(of: error))"
        }
        return "CKError \(error.code.rawValue) (\(error.code))"
    }

    static func describe(_ permission: CKShare.ParticipantPermission) -> String {
        switch permission {
        case .none: "none"
        case .readOnly: "readOnly"
        case .readWrite: "readWrite"
        case .unknown: "unknown"
        @unknown default: "\(permission.rawValue)"
        }
    }

    static func describe(_ role: CKShare.ParticipantRole) -> String {
        switch role {
        case .owner: "owner"
        case .privateUser: "privateUser"
        case .publicUser: "publicUser"
        case .administrator: "administrator"
        case .unknown: "unknown"
        @unknown default: "\(role.rawValue)"
        }
    }

    static func describe(_ acceptance: CKShare.ParticipantAcceptanceStatus) -> String {
        switch acceptance {
        case .pending: "pending"
        case .accepted: "accepted"
        case .removed: "removed"
        case .unknown: "unknown"
        @unknown default: "\(acceptance.rawValue)"
        }
    }

    static func describe(_ reason: CKDatabase.DatabaseChange.Deletion.Reason) -> String {
        switch reason {
        case .deleted: "deleted"
        case .purged: "purged"
        case .encryptedDataReset: "encryptedDataReset"
        @unknown default: "unknown"
        }
    }
}
#endif
