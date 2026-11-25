import Foundation
import ReqlingKit

/// iCloud sync. An ephemeral (test) graph gets none, so no test can reach iCloud; neither does a build without the
/// iCloud entitlement, where CloudKit would trap (`SyncAvailability`).
@MainActor
extension AppComponent {
    var librarySync: LibrarySync? {
        shared {
            guard !storageProfile.isEphemeral else {
                return nil
            }
            let lifecycle = ProjectLifecycle(
                library: projectLibrary,
                runner: requestRunner,
                workspace: workspaceState,
                protoWorkspaces: protoWorkspaces
            )
            return LibrarySync.iCloud(
                library: projectLibrary,
                lifecycle: lifecycle,
                secretStore: secretStore,
                directory: storageProfile.syncDirectory
            )
        }
    }

    var iCloudSync: ICloudSyncModel {
        shared {
            ICloudSyncModel(
                sync: librarySync,
                // Only where sync runs: `CKContainer` traps in a build that can't use iCloud.
                shareService: librarySync == nil ? nil : CloudKitShareService(),
                library: projectLibrary,
                settings: settingsStore,
                system: systemIntegration,
                profileExpiry: storageProfile.isEphemeral ? nil : ProvisioningProfile.expirationDate(of: ProvisioningProfile.embeddedURL)
            )
        }
    }
}
