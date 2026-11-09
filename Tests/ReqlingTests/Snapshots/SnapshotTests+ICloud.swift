import Foundation
@testable import ReqlingKit
import SwiftUI
import XCTest

@testable import Reqling

/// Settings ▸ iCloud: up to date, and in a build without iCloud. The account choice is mostly prose, which reflows
/// across macOS versions, so `ICloudSyncModelTests` checks its wording instead.
extension SnapshotTests {
    private static let iCloudSize = CGSize(width: 900, height: 640)

    /// Replaces the fixture with one syncing over a stub, through its first sync, and opens iCloud.
    private func showICloud() async {
        fixture.tearDown()
        let synced = Date(timeIntervalSince1970: 1_800_000_000)
        fixture = AppFixture.syncing(over: StubSyncTransport(), now: { synced })
        let model = fixture.model.iCloud
        model.start()
        await waitUntil("the first sync") { model.status == .upToDate(synced) }
        model.showsFirstSyncNotice = false
        fixture.model.showSettings(.iCloud)
    }

    func testSettingsICloudUpToDate() async {
        await showICloud()

        assertBothAppearances(SettingsScreen(model: fixture.model), size: Self.iCloudSize)
    }

    /// A build without the iCloud entitlement, as a test graph is: the switch is off and can't turn on.
    func testSettingsICloudUnavailable() {
        fixture.model.showSettings(.iCloud)

        assertBothAppearances(SettingsScreen(model: fixture.model), size: Self.iCloudSize)
    }
}
