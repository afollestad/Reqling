import ReqlingKit
import XCTest

final class AppInfoTests: XCTestCase {
    func testReadsBundleMetadataPreferringTheDisplayName() {
        let info = AppInfo(infoDictionary: [
            "CFBundleDisplayName": "Reqling Dev",
            "CFBundleName": "Reqling",
            "CFBundleIdentifier": "com.afollestad.reqling.debug",
            "CFBundleShortVersionString": "1.2.3",
            "CFBundleVersion": "45"
        ])

        XCTAssertEqual(
            info,
            AppInfo(name: "Reqling Dev", bundleIdentifier: "com.afollestad.reqling.debug", version: "1.2.3", build: "45")
        )
    }

    func testFallsBackToTheBundleNameAndPackagedDefaults() {
        let info = AppInfo(infoDictionary: ["CFBundleName": "Reqling"])

        XCTAssertEqual(
            info,
            AppInfo(name: "Reqling", bundleIdentifier: "com.afollestad.reqling", version: "0.0.0", build: "0")
        )
    }

    func testUserAgentCarriesTheMarketingVersion() {
        let info = AppInfo(name: "Reqling", bundleIdentifier: "com.afollestad.reqling", version: "2.0.1", build: "9")

        XCTAssertEqual(info.userAgent, "Reqling/2.0.1")
    }
}
