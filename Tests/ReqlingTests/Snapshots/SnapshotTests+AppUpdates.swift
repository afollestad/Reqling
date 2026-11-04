import Foundation
import ReqlingKit
import SwiftUI
import XCTest

@testable import Reqling

/// Settings ▸ App Updates in each state, and the toolbar gear's badges.
extension SnapshotTests {
    private static let updatesSize = CGSize(width: 900, height: 640)

    /// Replaces the fixture with one whose updater answers `lookup`, and opens App Updates.
    private func showUpdates(_ lookup: AppUpdateReleaseLookupResult = .unavailable(.noRelease), holdsDownload: Bool = false) -> AppUpdateManager {
        fixture.tearDown()
        let updates = AppUpdateStubs.manager(lookup, holdsDownload: holdsDownload)
        fixture = AppFixture(updates: updates)
        fixture.model.showSettings(.updates)
        return updates
    }

    func testSettingsAppUpdatesNotChecked() {
        _ = showUpdates()

        assertBothAppearances(SettingsScreen(model: fixture.model), size: Self.updatesSize)
    }

    /// The newest release is the running one.
    func testSettingsAppUpdatesUpToDate() async {
        let running = AppUpdateRelease(
            tagName: "v1.0.0",
            version: AppUpdateVersion(string: "1.0.0")!,
            changelogMarkdown: "",
            htmlURL: AppUpdateStubs.release.htmlURL,
            asset: AppUpdateStubs.release.asset
        )
        let updates = showUpdates(.installable(AppUpdateReleaseFeed(latestRelease: running, releaseNotes: [])))
        await updates.forceCheck()

        assertBothAppearances(SettingsScreen(model: fixture.model), size: Self.updatesSize)
    }

    func testSettingsAppUpdatesAvailable() async {
        let updates = showUpdates(AppUpdateStubs.newer)
        await updates.forceCheck()

        assertBothAppearances(SettingsScreen(model: fixture.model), size: Self.updatesSize)
    }

    func testSettingsAppUpdatesDownloading() async {
        let updates = showUpdates(AppUpdateStubs.newer, holdsDownload: true)
        let download = Task { await updates.downloadLatestUpdate() }
        await waitUntil("the download to report progress") { updates.downloadState == .downloading(AppUpdateStubs.release, progress: 0.4) }

        assertBothAppearances(SettingsScreen(model: fixture.model), size: Self.updatesSize)
        updates.cancelDownload()
        _ = await download.value
    }

    func testSettingsAppUpdatesReadyToInstall() async {
        let updates = showUpdates(AppUpdateStubs.newer)
        await updates.downloadLatestUpdate()

        assertBothAppearances(SettingsScreen(model: fixture.model), size: Self.updatesSize)
    }

    func testSettingsAppUpdatesCheckFailed() async {
        let updates = showUpdates(.unavailable(.rateLimited(resetDate: nil)))
        await updates.forceCheck()

        assertBothAppearances(SettingsScreen(model: fixture.model), size: Self.updatesSize)
    }

    func testSettingsToolbarButtonBadges() {
        for badge in [AppUpdateBadgeState.none, .updateAvailable, .readyToInstall] {
            for colorScheme in [ColorScheme.light, .dark] {
                assertMacSnapshot(
                    SettingsToolbarButton(badge: badge) {}.padding(8),
                    size: CGSize(width: 48, height: 40),
                    named: "\(badge)-\(colorScheme == .dark ? "dark" : "light")",
                    colorScheme: colorScheme
                )
            }
        }
    }
}
