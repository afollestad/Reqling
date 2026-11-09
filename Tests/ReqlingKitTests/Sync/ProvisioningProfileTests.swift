import Foundation
@testable import ReqlingKit
import XCTest

/// The embedded profile's expiry, read from the property list its signature wraps.
final class ProvisioningProfileTests: XCTestCase {
    func testTheExpiryIsReadFromTheSignedPropertyList() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let expiry = Date(timeIntervalSince1970: 1_900_000_000)
        let plist = try PropertyListSerialization.data(fromPropertyList: ["Name": "Reqling", "ExpirationDate": expiry], format: .xml, options: 0)
        let profile = directory.file("embedded.provisionprofile")
        try (Data([0x30, 0x80, 0x06, 0x09]) + plist + Data([0xA0, 0x82, 0x00, 0x00])).write(to: profile)
        let garbage = directory.file("garbage.provisionprofile")
        try Data("no property list here".utf8).write(to: garbage)

        XCTAssertEqual(ProvisioningProfile.expirationDate(of: profile), expiry)
        XCTAssertNil(ProvisioningProfile.expirationDate(of: garbage))
        XCTAssertNil(ProvisioningProfile.expirationDate(of: directory.file("missing.provisionprofile")))
    }
}
