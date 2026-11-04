import Foundation
import ReqlingKit

/// An `AppUpdateManager` for view and view-model tests: running 1.0.0, answering every check with `lookup`, and staging
/// without touching disk. `holdsDownload` parks a download at 40% so a test can show it mid-flight, and `installer`
/// stands in for the helper that would quit Reqling.
@MainActor
enum AppUpdateStubs {
    static let release = AppUpdateRelease(
        tagName: "v1.1.0",
        version: AppUpdateVersion(string: "1.1.0")!,
        changelogMarkdown: "- **gRPC**: reflection falls back to `v1alpha`.\n- Faster response rendering.",
        htmlURL: URL(string: "https://github.com/afollestad/reqling/releases/tag/v1.1.0")!,
        asset: AppUpdateReleaseAsset(
            name: "Reqling.app.zip",
            downloadURL: URL(string: "https://example.test/Reqling.app.zip")!,
            size: 10,
            digest: AppUpdateReleaseAssetDigest(sha256HexDigest: String(repeating: "ab", count: 32))!
        )
    )

    static var newer: AppUpdateReleaseLookupResult {
        .installable(AppUpdateReleaseFeed(
            latestRelease: release,
            releaseNotes: [
                AppUpdateReleaseNote(tagName: "v1.1.0", version: release.version, changelogMarkdown: release.changelogMarkdown),
                AppUpdateReleaseNote(
                    tagName: "v1.0.1",
                    version: AppUpdateVersion(string: "1.0.1")!,
                    changelogMarkdown: "Fixes a crash when a project folder moves."
                )
            ]
        ))
    }

    static func manager(
        _ lookup: AppUpdateReleaseLookupResult = .unavailable(.noRelease),
        holdsDownload: Bool = false,
        installer: StubUpdateInstaller? = nil
    ) -> AppUpdateManager {
        AppUpdateManager(
            releaseClient: FixedReleaseClient(lookup: lookup),
            currentVersion: "1.0.0",
            downloader: StubUpdateDownloader(holds: holdsDownload),
            stager: StubUpdateStager(),
            installer: installer,
            scheduleTiming: AppUpdateScheduleTiming(automaticCheckInterval: .seconds(21_600), now: { Date(timeIntervalSince1970: 0) }, sleep: { _ in
                try await Task.sleep(for: .seconds(86_400 * 365))
            })
        )
    }
}

/// Counts installs instead of launching a helper and quitting.
final class StubUpdateInstaller: AppUpdateInstalling, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var installs: Int {
        lock.withLock { count }
    }

    func installAndRelaunch(stagedUpdate: StagedAppUpdate) async throws {
        lock.withLock { count += 1 }
    }
}

private struct FixedReleaseClient: AppUpdateReleaseClient {
    let lookup: AppUpdateReleaseLookupResult

    func latestRelease() async -> AppUpdateReleaseLookupResult {
        lookup
    }
}

private struct StubUpdateDownloader: AppUpdateDownloading {
    let holds: Bool

    func download(release: AppUpdateRelease, progress: @escaping @Sendable (Double) async -> Void) async throws -> URL {
        await progress(0.4)
        if holds {
            // Parks until the test's manager is released; cancelling the download ends it.
            try await Task.sleep(for: .seconds(86_400 * 365))
        }
        return URL(fileURLWithPath: "/dev/null")
    }
}

private struct StubUpdateStager: AppUpdateStaging {
    func stageDownloadedUpdate(release: AppUpdateRelease, downloadedZIPURL: URL) async throws -> StagedAppUpdate {
        StagedAppUpdate(
            release: release,
            appBundleURL: URL(fileURLWithPath: "/Staged/\(release.tagName)/Reqling.app"),
            stagedAt: Date(timeIntervalSince1970: 0)
        )
    }

    func loadValidatedStagedUpdate() async throws -> StagedAppUpdate? {
        nil
    }
}
