import Foundation
@testable import ReqlingKit
import Security
import XCTest

final class SecretStoreErrorTests: XCTestCase {
    /// macOS words a refused Keychain request as a wrong password; the message says what actually helps instead.
    func testARefusedRequestIsntDescribedAsAWrongPassword() {
        for status in [errSecAuthFailed, errSecInteractionNotAllowed, errSecUserCanceled] {
            let message = SecretStoreError.keychain(status).localizedDescription

            XCTAssertFalse(message.contains("passphrase"), message)
            // The test process is unchanged on disk, so this is the plain refusal, not the reopen advice.
            XCTAssertTrue(message.contains("didn't allow Reqling"), message)
        }
        XCTAssertTrue(SecretStoreError.keychain(errSecItemNotFound).localizedDescription.hasPrefix("The Keychain refused the request:"))
    }
}
