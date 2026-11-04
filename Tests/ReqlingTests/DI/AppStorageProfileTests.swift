import XCTest

@testable import Reqling

final class AppStorageProfileTests: XCTestCase {
    func testTestProfilesAreIsolatedFromEachOther() {
        let first = AppStorageProfile.test()
        let second = AppStorageProfile.test()
        defer {
            first.cleanUp()
            second.cleanUp()
        }

        XCTAssertNotEqual(first.applicationSupportDirectory, second.applicationSupportDirectory)
        XCTAssertNotEqual(first.settingsDefaultsSuiteName, second.settingsDefaultsSuiteName)
        XCTAssertTrue(first.applicationSupportDirectory.path.hasPrefix(FileManager.default.temporaryDirectory.path))
    }

    func testCleanUpRemovesTheDirectoryAndDefaultsSuite() throws {
        let profile = AppStorageProfile.test()
        try FileManager.default.createDirectory(at: profile.applicationSupportDirectory, withIntermediateDirectories: true)
        profile.settingsDefaults.set("value", forKey: "key")

        profile.cleanUp()

        XCTAssertFalse(FileManager.default.fileExists(atPath: profile.applicationSupportDirectory.path))
        XCTAssertNil(profile.settingsDefaults.string(forKey: "key"))
    }

    func testProductionStorageIsScopedByBundleIdentifierAndNeverEphemeral() {
        let profile = AppStorageProfile.production

        XCTAssertFalse(profile.isEphemeral)
        XCTAssertEqual(profile.applicationSupportDirectory.lastPathComponent, Bundle.main.bundleIdentifier)
    }
}
