#if DEBUG
import CloudKit
import Foundation

/// A zone-wide share edited outside sync, as the end-to-end harness's probes and scenarios do what the share sheet does:
/// someone invited, their permission and role, the link's permission, someone removed, or sharing stopped.
///
/// Debug builds only, and only in the harness's own container (`SharingHarnessMode`).
@MainActor
struct HarnessShares {
    /// Someone to invite, by the email address their Apple Account uses.
    struct Invitation {
        let email: String
        let permission: CKShare.ParticipantPermission
        let role: CKShare.ParticipantRole
    }

    let container: CKContainer

    func participant(_ invite: Invitation) async throws -> CKShare.Participant {
        let participant = try await container.shareParticipant(forEmailAddress: invite.email)
        participant.permission = invite.permission
        participant.role = invite.role
        return participant
    }

    func share(in zoneID: CKRecordZone.ID, of database: CKDatabase) async throws -> CKShare {
        let record = try await database.record(for: CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: zoneID))
        guard let share = record as? CKShare else {
            throw CKError(.unknownItem)
        }
        return share
    }

    /// Changes the share of `zoneID`: the link's permission, and `invite` added, or changed when they take part already.
    /// As an administrator in the shared database, this is how a participant invites. Returns the share as saved.
    @discardableResult
    func update(
        _ zoneID: CKRecordZone.ID,
        in database: CKDatabase,
        publicPermission: CKShare.ParticipantPermission?,
        invite: Invitation?
    ) async throws -> CKShare {
        let share = try await share(in: zoneID, of: database)
        if let publicPermission {
            share.publicPermission = publicPermission
        }
        if let invite {
            if let existing = share.participants.first(where: { $0.userIdentity.lookupInfo?.emailAddress == invite.email }) {
                existing.permission = invite.permission
                existing.role = invite.role
            } else {
                share.addParticipant(try await participant(invite))
            }
        }
        return try await save(share, in: database)
    }

    /// Removes everyone `email` names from the share of `zoneID`, one this account owns.
    func removeParticipant(_ email: String, from zoneID: CKRecordZone.ID) async throws {
        let database = container.privateCloudDatabase
        let share = try await share(in: zoneID, of: database)
        for participant in share.participants where participant.userIdentity.lookupInfo?.emailAddress == email {
            share.removeParticipant(participant)
        }
        try await save(share, in: database)
    }

    /// Deletes the share of `zoneID`, as its owner: sharing stops for everyone.
    func stopSharing(_ zoneID: CKRecordZone.ID) async throws {
        let id = CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: zoneID)
        _ = try await container.privateCloudDatabase.modifyRecords(saving: [], deleting: [id]).deleteResults[id]?.get()
    }

    /// Deletes this account's place in the share of `zoneID`, someone else's, as a participant: leaving it.
    func leave(_ zoneID: CKRecordZone.ID) async throws {
        let id = CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: zoneID)
        _ = try await container.sharedCloudDatabase.modifyRecords(saving: [], deleting: [id]).deleteResults[id]?.get()
    }

    @discardableResult
    private func save(_ share: CKShare, in database: CKDatabase) async throws -> CKShare {
        let saved = try await database.modifyRecords(saving: [share], deleting: []).saveResults[share.recordID]?.get()
        return saved as? CKShare ?? share
    }
}
#endif
