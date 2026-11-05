import Foundation
import ReqlingKit
import XCTest

final class PEMIdentityImporterTests: XCTestCase {
    func testImportsAnECPKCS8PairAndAnRSAPKCS1Pair() throws {
        let elliptic = try PEMIdentityImporter.importIdentity(
            certificate: try TLSFixtures.data("client.pem"),
            key: try TLSFixtures.data("client-key.pem"),
            passphrase: ""
        )
        let rsaPEM = try TLSFixtures.rsaClientPEM
        let rsa = try PEMIdentityImporter.importIdentity(certificate: rsaPEM.certificate, key: rsaPEM.key, passphrase: "")

        XCTAssertEqual(elliptic.certificate.map { CertificateSummary($0).subject }, "Reqling Test Client")
        XCTAssertEqual(rsa.certificate.map { CertificateSummary($0).subject }, "Reqling Test RSA Client")
    }

    func testTheLeafIsTheCertificateTheKeyBelongsToAndTheRestAreIntermediates() throws {
        let identity = try PEMIdentityImporter.importIdentity(
            certificate: try TLSFixtures.data("ca.pem") + Data("\n".utf8) + TLSFixtures.data("client.pem"),
            key: try TLSFixtures.data("client-key.pem"),
            passphrase: ""
        )

        XCTAssertEqual(identity.certificate.map { CertificateSummary($0).subject }, "Reqling Test Client")
        XCTAssertEqual(identity.intermediates.map { CertificateSummary($0).subject }, ["Reqling Test CA"])
    }

    func testOneFileCanHoldTheKeyAndCertificateInEitherOrder() throws {
        let certificate = try TLSFixtures.data("client.pem")
        let key = try TLSFixtures.data("client-key.pem")

        // The fixtures' PEM has no trailing newline, which a combined file needs between its blocks.
        for combined in [certificate + Data("\n".utf8) + key, key + Data("\n".utf8) + certificate] {
            XCTAssertTrue(PEMIdentityImporter.containsPrivateKey(combined))
            let identity = try PEMIdentityImporter.importIdentity(certificate: combined, key: combined, passphrase: "")
            XCTAssertEqual(identity.certificate.map { CertificateSummary($0).subject }, "Reqling Test Client")
        }
        XCTAssertFalse(PEMIdentityImporter.containsPrivateKey(certificate))
        XCTAssertTrue(PEMIdentityImporter.containsPrivateKey(try TLSFixtures.encryptedClientKey))
        XCTAssertTrue(PEMIdentityImporter.containsPrivateKey(try TLSFixtures.legacyEncryptedRSAClientKey))
    }

    func testEncryptedKeysOpenOnlyWithTheirPassphrase() throws {
        let passphrase = try TLSFixtures.clientPassphrase
        let pairs = [
            (try TLSFixtures.data("client.pem"), try TLSFixtures.encryptedClientKey),
            (try TLSFixtures.rsaClientPEM.certificate, try TLSFixtures.legacyEncryptedRSAClientKey)
        ]

        for (certificate, key) in pairs {
            XCTAssertNotNil(try PEMIdentityImporter.importIdentity(certificate: certificate, key: key, passphrase: passphrase).certificate)
            for wrong in ["wrong", ""] {
                XCTAssertThrowsError(try PEMIdentityImporter.importIdentity(certificate: certificate, key: key, passphrase: wrong)) { error in
                    XCTAssertEqual(error as? TLSError, .wrongPassphrase)
                }
            }
        }
    }

    func testAKeyThatIsNotTheCertificatesIsRefused() throws {
        let other = try TLSFixtures.mint()

        XCTAssertThrowsError(try PEMIdentityImporter.importIdentity(
            certificate: try TLSFixtures.data("client.pem"),
            key: Data(other.privateKeyPEM.utf8),
            passphrase: ""
        )) { error in
            XCTAssertEqual(error as? TLSError, .unreadableIdentity("The private key does not match the certificate."))
        }
        XCTAssertThrowsError(try PEMIdentityImporter.importIdentity(
            certificate: try TLSFixtures.data("client.pem"),
            key: try TLSFixtures.rsaClientPEM.key,
            passphrase: ""
        )) { error in
            XCTAssertEqual(error as? TLSError, .unreadableIdentity("The private key does not match the certificate."))
        }
    }

    func testUnreadableFilesFailClearly() throws {
        let certificate = try TLSFixtures.data("client.pem")

        for key in [Data(), Data("not a key".utf8), certificate] {
            XCTAssertThrowsError(try PEMIdentityImporter.importIdentity(certificate: certificate, key: key, passphrase: "")) { error in
                XCTAssertEqual(error as? TLSError, .unreadableIdentity("The private key could not be read."))
            }
        }
        XCTAssertThrowsError(try PEMIdentityImporter.importIdentity(
            certificate: try TLSFixtures.data("client-key.pem"),
            key: try TLSFixtures.data("client-key.pem"),
            passphrase: ""
        )) { error in
            guard case .unreadableCertificate = error as? TLSError else {
                return XCTFail("Expected an unreadable certificate, got \(error)")
            }
        }
    }
}
