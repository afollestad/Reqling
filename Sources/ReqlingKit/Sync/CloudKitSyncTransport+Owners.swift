import CloudKit
import Foundation

/// Whose database each zone is in: this account's own, or, in the shared database, the person who shared it.
extension CloudKitSyncTransport {
    /// `zone` as this transport's database names it: this account's own, or its owner's in the shared database.
    func zoneID(_ zone: SyncZone) -> CKRecordZone.ID {
        CloudKitRecords.zoneID(zone, owner: owner(of: zone))
    }

    func recordID(_ id: SyncRecordID) -> CKRecord.ID {
        CloudKitRecords.recordID(id, owner: owner(of: id.zone))
    }

    func owner(of zone: SyncZone) -> String {
        guard scope == .shared else {
            return CKCurrentUserDefaultName
        }
        return owners[zone] ?? knownOwner(zone) ?? CKCurrentUserDefaultName
    }

    /// The zone `zoneID` stands for, or `nil` for one this transport ignores: one Reqling never writes, or, in the
    /// shared database, anything but a project's zone, so no one can share a zone that would land as this account's
    /// Global or personal values; nor a second person's zone for a project ID another's already stands for, as when two
    /// people share copies of one project, so the two never merge.
    func acceptedZone(_ zoneID: CKRecordZone.ID) -> SyncZone? {
        guard let zone = SyncZone(name: zoneID.zoneName) else {
            return nil
        }
        guard scope == .shared else {
            return zone
        }
        guard case .project = zone else {
            return nil
        }
        let known = owners[zone] ?? knownOwner(zone)
        guard known == nil || known == zoneID.ownerName else {
            return nil
        }
        owners[zone] = zoneID.ownerName
        return zone
    }
}
