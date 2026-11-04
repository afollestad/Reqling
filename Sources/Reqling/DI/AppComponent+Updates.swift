import AppKit
import ReqlingKit

/// The integrated updater. An ephemeral (test) profile gets a release client that never reaches GitHub and no
/// downloader, stager, or installer, so a test graph can neither use the network nor touch an app bundle.
@MainActor
extension AppComponent {
    var appUpdates: AppUpdateManager {
        shared {
            guard !storageProfile.isEphemeral else {
                return AppUpdateManager(releaseClient: OfflineAppUpdateReleaseClient(), currentVersion: appInfo.version)
            }
            let target = AppUpdateTarget.running
            return AppUpdateManager(
                releaseClient: GitHubAppUpdateReleaseClient(userAgent: appInfo.userAgent),
                currentVersion: appInfo.version,
                downloader: URLSessionAppUpdateDownloader(userAgent: appInfo.userAgent),
                stager: DefaultAppUpdateStager(updatesDirectory: storageProfile.updatesDirectory, target: target),
                installer: DefaultAppUpdateInstaller(
                    updatesDirectory: storageProfile.updatesDirectory,
                    target: target,
                    terminate: { Task { @MainActor in NSApplication.shared.terminate(nil) } }
                )
            )
        }
    }
}

/// Reports no release, for graphs that must stay offline.
struct OfflineAppUpdateReleaseClient: AppUpdateReleaseClient {
    func latestRelease() async -> AppUpdateReleaseLookupResult {
        .unavailable(.noRelease)
    }
}
