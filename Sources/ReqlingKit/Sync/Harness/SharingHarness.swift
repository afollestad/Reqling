#if DEBUG
import CloudKit
import Foundation

/// The end-to-end harness's sharing of real projects (`MCPSharingHarnessTools`), by the paths the app takes: a project's
/// share made by `CloudKitShareService`, as Share… makes it, then changed as the share sheet would (`HarnessShares`),
/// and a share's link accepted as `AppDelegate` accepts the metadata macOS hands it. Only the share sheet and opening a
/// link stay by hand, as system UI.
///
/// Debug builds only, and never in the app's own container, since `resetCloud` deletes everything in its own.
@MainActor
public final class SharingHarness {
    private let containerIdentifier: String
    private let sync: LibrarySync
    private let library: ProjectLibrary
    /// Made on first use, so building the harness's tools doesn't need the iCloud entitlement, as in tests.
    private lazy var shareService = CloudKitShareService(containerIdentifier: containerIdentifier)

    public init(containerIdentifier: String, sync: LibrarySync, library: ProjectLibrary) {
        precondition(
            containerIdentifier != SyncAvailability.appContainerIdentifier,
            "The sharing harness runs only in a container of its own, never the app's."
        )
        self.containerIdentifier = containerIdentifier
        self.sync = sync
        self.library = library
    }

    private var shares: HarnessShares {
        HarnessShares(container: shareService.container)
    }

    private var database: CKDatabase {
        shareService.container.privateCloudDatabase
    }

    /// Shares `id`, one of this account's own, as Share… does, then sets who it reaches. Returns its link.
    func share(_ id: ProjectID, invite: HarnessShares.Invitation?, link: CKShare.ParticipantPermission?) async throws -> String {
        guard let project = library.project(id) else {
            throw ProjectStorageError.projectNotFound
        }
        let prepared = try await shareService.prepareShare(of: id, title: project.name)
        let saved = try await shares.update(prepared.recordID.zoneID, in: database, publicPermission: link, invite: invite)
        return saved.url?.absoluteString ?? ""
    }

    func removeParticipant(_ email: String, from id: ProjectID) async throws {
        try await shares.removeParticipant(email, from: zoneID(id))
    }

    func stopSharing(_ id: ProjectID) async throws {
        try await shares.stopSharing(zoneID(id))
    }

    /// Accepts the share `url` links to as `ICloudSyncModel.acceptShare` accepts what macOS hands Reqling: CloudKit
    /// accepts it, then sync brings the project in.
    func accept(_ url: URL) async throws -> AcceptedShare {
        let metadata = try await shareService.container.shareMetadata(for: url)
        let accepted = try await shareService.accept(metadata)
        await sync.syncNow()
        return accepted
    }

    /// Deletes every zone this account owns in the harness's container and leaves every share it takes part in, so a
    /// run starts from nothing. Sync, still running, takes it as everything gone; the runner wipes this copy's files and
    /// starts it again (`scripts/sharing-e2e.sh run`).
    func resetCloud() async throws -> (deleted: Int, left: Int) {
        let owned = try await database.allRecordZones().map(\.zoneID).filter { $0.zoneName != CKRecordZone.ID.defaultZoneName }
        if !owned.isEmpty {
            _ = try await database.modifyRecordZones(saving: [], deleting: owned)
        }
        let joined = try await shareService.container.sharedCloudDatabase.allRecordZones().map(\.zoneID)
        for zoneID in joined {
            try await shares.leave(zoneID)
        }
        return (owned.count, joined.count)
    }

    private func zoneID(_ id: ProjectID) -> CKRecordZone.ID {
        CloudKitRecords.zoneID(.project(id), owner: CKCurrentUserDefaultName)
    }
}
#endif
