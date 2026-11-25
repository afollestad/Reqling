import CloudKit
import Foundation

/// Shares as the share sheet and accepting one need them, outside sync's engine, which learns of each from its next
/// fetch: a project's zone-wide share, made once and found again after, and a share someone accepted. Only a project's
/// zone is ever shared; each person's values for it live in their own `personal` zone, which no share reaches.
@MainActor
public final class CloudKitShareService {
    public let container: CKContainer

    /// Only where sync can run (`SyncAvailability.isEntitled`), since `CKContainer` traps elsewhere.
    public init(containerIdentifier: String = SyncAvailability.containerIdentifier) {
        container = CKContainer(identifier: containerIdentifier)
    }

    /// `project`'s share: this account's own, or, with `sharing`, the one its owner shares with this account; `nil` when
    /// it has none.
    public func existingShare(of project: ProjectID, sharing: ProjectSharing?) async throws -> CKShare? {
        let database = sharing == nil ? container.privateCloudDatabase : container.sharedCloudDatabase
        return try await Self.share(in: Self.zoneID(project, owner: sharing?.owner), of: database)
    }

    /// The share of `project`, one of this account's own, made titled `title` should it have none yet, so sharing twice
    /// never makes a second.
    public func prepareShare(of project: ProjectID, title: String) async throws -> CKShare {
        let zoneID = Self.zoneID(project, owner: nil)
        let database = container.privateCloudDatabase
        if let existing = try await Self.share(in: zoneID, of: database) {
            return existing
        }
        let share = CKShare(recordZoneID: zoneID)
        share[CKShare.SystemFieldKey.title] = title as CKRecordValue
        return try await Self.save(share, in: database)
    }

    /// Accepts `metadata`'s share for this account and returns the project it shares. Its owner opening their own link
    /// accepts nothing. Throws `CloudKitShareError.notAProject` for a share that isn't a Reqling project's.
    public func accept(_ metadata: CKShare.Metadata) async throws -> ProjectID {
        guard metadata.containerIdentifier == container.containerIdentifier, let id = Self.project(sharedBy: metadata) else {
            throw CloudKitShareError.notAProject
        }
        if metadata.participantRole != .owner {
            _ = try await container.accept(metadata)
        }
        return id
    }

    /// The project `metadata` shares: a project's whole zone, the only kind of share Reqling makes.
    static func project(sharedBy metadata: CKShare.Metadata) -> ProjectID? {
        let recordID = metadata.share.recordID
        guard recordID.recordName == CKRecordNameZoneWideShare, case .project(let id)? = SyncZone(name: recordID.zoneID.zoneName) else {
            return nil
        }
        return id
    }

    /// Titles the share in `zoneID`, unless it already has `title` or there's none.
    static func setTitle(_ title: String, ofShareIn zoneID: CKRecordZone.ID, of database: CKDatabase) async throws {
        guard let share = try await share(in: zoneID, of: database), share[CKShare.SystemFieldKey.title] as? String != title else {
            return
        }
        share[CKShare.SystemFieldKey.title] = title as CKRecordValue
        _ = try await save(share, in: database)
    }

    private static func zoneID(_ project: ProjectID, owner: String?) -> CKRecordZone.ID {
        CloudKitRecords.zoneID(.project(project), owner: owner ?? CKCurrentUserDefaultName)
    }

    private static func share(in zoneID: CKRecordZone.ID, of database: CKDatabase) async throws -> CKShare? {
        do {
            return try await database.record(for: CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: zoneID)) as? CKShare
        } catch let error as CKError where error.code == .unknownItem {
            return nil
        }
    }

    /// Saves `share` only over the version it was read as, so two Macs titling it at once can't overwrite each other.
    private static func save(_ share: CKShare, in database: CKDatabase) async throws -> CKShare {
        let results = try await database.modifyRecords(saving: [share], deleting: [], savePolicy: .ifServerRecordUnchanged)
        guard let saved = try results.saveResults[share.recordID]?.get() as? CKShare else {
            throw CloudKitShareError.notSaved
        }
        return saved
    }
}

public enum CloudKitShareError: Error, Equatable, LocalizedError {
    case notAProject
    case notSaved

    public var errorDescription: String? {
        switch self {
        case .notAProject: "This link doesn't share a Reqling project."
        case .notSaved: "iCloud didn't save the share. Try again."
        }
    }
}
