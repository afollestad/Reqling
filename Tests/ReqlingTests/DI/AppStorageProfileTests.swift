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
        XCTAssertTrue(first.applicationSupportDirectory.path.hasPrefix(FileManager.default.temporaryDirectory.path))
        first.preferences.set(Data("value".utf8), forKey: "key")
        XCTAssertNil(second.preferences.data(forKey: "key"))
    }

    func testCleanUpRemovesTheDirectory() throws {
        let profile = AppStorageProfile.test()
        try FileManager.default.createDirectory(at: profile.applicationSupportDirectory, withIntermediateDirectories: true)

        profile.cleanUp()

        XCTAssertFalse(FileManager.default.fileExists(atPath: profile.applicationSupportDirectory.path))
    }

    func testProductionStorageIsScopedByBundleIdentifierAndNeverEphemeral() {
        let profile = AppStorageProfile.production

        XCTAssertFalse(profile.isEphemeral)
        XCTAssertEqual(profile.applicationSupportDirectory.lastPathComponent, Bundle.main.bundleIdentifier)
    }
}
