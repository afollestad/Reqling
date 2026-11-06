import Foundation
@testable import ReqlingKit
import XCTest

/// `wss` connections reuse the project's TLS through `NIOClientTLS`: its CAs on top of the system roots, its client
/// identities, and Verify TLS off.
extension WebSocketExecutorTests {
    private func context(identity: TLSClientIdentity? = nil, anchors: Bool = true, verifiesServer: Bool = true) throws -> TLSContext {
        TLSContext(
            verifiesServer: verifiesServer,
            anchors: anchors ? try CertificateLoader.certificates(from: try TLSFixtures.data("ca.pem")) : [],
            clientIdentity: { _, _ in identity }
        )
    }

    private func opened(_ server: TestWebSocketServer, tls: TLSContext) async throws -> HTTPResponseRecord? {
        var connection = try connect(server.url, tls: tls)
        guard case .opened(let head, _, _) = await connection.next() else {
            XCTFail("Expected the connection to open: \(await connection.outcome)")
            return nil
        }
        connection.task.cancel()
        _ = await connection.outcome
        return head
    }

    func testAProjectCAIsTrustedOnTopOfTheSystemRoots() async throws {
        let server = try await start(tls: true)

        let head = try await opened(server, tls: try context())

        XCTAssertNotNil(head?.tlsVersion)
        XCTAssertNotNil(head?.timing?.tlsHandshake)
        XCTAssertEqual(head?.presentedClientCertificate, false, "No server asked for a certificate")
    }

    func testAnUnknownCAIsRefusedUnlessVerificationIsOff() async throws {
        let server = try await start(tls: true)

        let refused = try connect(server.url, tls: try context(anchors: false))
        guard case .failed(.untrustedServer(let reason)) = await refused.outcome else {
            return XCTFail("A certificate from an unknown CA isn't trusted")
        }
        XCTAssertTrue(reason.contains("127.0.0.1"), reason)
        let head = try await opened(server, tls: try context(anchors: false, verifiesServer: false))
        XCTAssertEqual(head?.statusCode, 101)
    }

    func testMutualTLSPresentsAPKCS12OrPEMIdentity() async throws {
        let server = try await start(tls: true, requireClientCertificate: true)
        let pkcs12 = try PKCS12Importer.importIdentity(
            try TLSFixtures.data("client.p12"),
            passphrase: TLSFixtures.clientPassphrase,
            probe: TLSFixtures.probe
        )
        let pem = try PEMIdentityImporter.importIdentity(
            certificate: try TLSFixtures.data("client.pem"),
            key: try TLSFixtures.encryptedClientKey,
            passphrase: TLSFixtures.clientPassphrase
        )

        for identity in [pkcs12, pem] {
            let head = try await opened(server, tls: try context(identity: identity))
            XCTAssertEqual(head?.presentedClientCertificate, true)
        }
    }

    func testAServerThatRequiresACertificateRefusesAClientWithout() async throws {
        let server = try await start(tls: true, requireClientCertificate: true)

        let connection = try connect(server.url, tls: try context())

        guard case .failed(.tlsFailed(let message)) = await connection.outcome else {
            return XCTFail("A required certificate that never comes fails TLS")
        }
        XCTAssertTrue(message.contains("client certificate"), message)
    }
}
