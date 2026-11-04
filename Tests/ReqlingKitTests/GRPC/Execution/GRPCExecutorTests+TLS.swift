import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
@testable import ReqlingKit
import Security
import Synchronization
import XCTest

extension GRPCExecutorTests {
    func testMutualTLSWithTheMatchingClientCertificateSucceeds() async throws {
        let server = try await startMutualTLS()
        let lookups = Mutex<[String]>([])
        let identity = try clientIdentity()
        let context = TLSContext(anchors: try fixtureCA()) { host, port in
            lookups.withLock { $0.append("\(host):\(port.map(String.init) ?? "-")") }
            return identity
        }

        let (events, outcome) = await run(call(server, "Unary", .unary, body: .message(try encode("secure")), security: .tls(context)))

        XCTAssertEqual(outcome.status?.isOK, true, "\(outcome)")
        XCTAssertEqual(try decode(events.received), ["secure"])
        XCTAssertEqual(lookups.withLock { $0 }, [server.target.description], "The identity is looked up by the target's host and port")
    }

    /// A TLS 1.3 handshake, both sides' default, signs with an RSA key through RSA-PSS, which `SecKeyPrivateKey`
    /// must offer and produce for the server to accept it.
    func testMutualTLSWithAnRSAClientCertificateSucceeds() async throws {
        let server = try await startMutualTLS()
        let identity = try PKCS12Importer.importIdentity(try TLSFixtures.rsaClientPKCS12, passphrase: try TLSFixtures.clientPassphrase)
        let context = TLSContext(anchors: try fixtureCA()) { _, _ in identity }

        let (events, outcome) = await run(call(server, "Unary", .unary, body: .message(try encode("rsa")), security: .tls(context)))

        XCTAssertEqual(outcome.status?.isOK, true, "\(outcome)")
        XCTAssertEqual(try decode(events.received), ["rsa"])
    }

    func testMutualTLSWithoutAClientCertificateFailsTheHandshake() async throws {
        let server = try await startMutualTLS()

        let context = TLSContext(anchors: try fixtureCA())

        let (_, outcome) = await run(call(server, "Unary", .unary, body: .message(try encode("x")), security: .tls(context)))

        guard case .failed(.tlsFailed(let message)) = outcome else {
            return XCTFail("Expected a TLS failure, got \(outcome)")
        }
        XCTAssertTrue(message.contains("requires a client certificate"), message)
    }

    func testAServerSignedByAnUntrustedCAIsRejected() async throws {
        let server = try await startMutualTLS()
        let identity = try clientIdentity()
        let context = TLSContext { _, _ in identity }

        let (_, outcome) = await run(call(server, "Unary", .unary, body: .message(try encode("x")), security: .tls(context)))

        guard case .failed(.untrustedServer(let reason)) = outcome else {
            return XCTFail("Expected an untrusted server, got \(outcome)")
        }
        XCTAssertTrue(reason.contains("127.0.0.1"), reason)
    }

    func testTurningVerificationOffSkipsServerTrust() async throws {
        let server = try await startMutualTLS()
        let identity = try clientIdentity()
        let context = TLSContext(verifiesServer: false) { _, _ in identity }

        let (_, outcome) = await run(call(server, "Unary", .unary, body: .message(try encode("x")), security: .tls(context)))

        XCTAssertEqual(outcome.status?.isOK, true, "\(outcome)")
    }

    /// Over a Unix socket, SNI and `:authority` name `localhost`, the name the certificate is verified against.
    func testTLSOverAUnixSocketNamesLocalhost() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rq-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = MetadataLog()
        let server = try await startMutualTLS(address: .unixDomainSocket(path: directory.appendingPathComponent("tls.sock").path), log: log)
        let identity = try clientIdentity()
        let context = TLSContext(anchors: try fixtureCA()) { _, _ in identity }

        let (_, outcome) = await run(call(server, "Unary", .unary, body: .message(try encode("x")), security: .tls(context)))

        XCTAssertEqual(outcome.status?.isOK, true, "\(outcome)")
        XCTAssertEqual(log.received.last?[":authority"], "localhost")
    }

    func testTLSAgainstAPlaintextServerFailsTheHandshake() async throws {
        let server = try await start()

        let (_, outcome) = await run(call(server, "Unary", .unary, body: .message(try encode("x")), security: .tls(TLSContext())))

        guard case .failed(.tlsFailed(let message)) = outcome else {
            return XCTFail("Expected a TLS failure, got \(outcome)")
        }
        XCTAssertTrue(message.contains("plaintext"), message)
    }

    /// The handshake tests cover P-256 and RSA-PSS; this also checks P-384 and every algorithm each key offers, signing
    /// and verifying its first choice in memory.
    func testSecKeyPrivateKeyOffersAndProducesSignaturesTLSAccepts() throws {
        let cases = [
            KeyCase(type: kSecAttrKeyTypeRSA, bits: 2048, offered: [0x0804, 0x0805, 0x0806, 0x0401, 0x0501, 0x0601, 0x0201]),
            KeyCase(type: kSecAttrKeyTypeECSECPrimeRandom, bits: 256, offered: [0x0403]),
            KeyCase(type: kSecAttrKeyTypeECSECPrimeRandom, bits: 384, offered: [0x0503])
        ]
        let data = Data("handshake transcript".utf8)
        for testCase in cases {
            let attributes: [String: Any] = [kSecAttrKeyType as String: testCase.type, kSecAttrKeySizeInBits as String: testCase.bits]
            var error: Unmanaged<CFError>?
            let key = try XCTUnwrap(SecKeyCreateRandomKey(attributes as CFDictionary, &error), "\(String(describing: error))")
            let publicKey = try XCTUnwrap(SecKeyCopyPublicKey(key))
            let wrapped = try SecKeyPrivateKey(key: key)

            XCTAssertEqual(wrapped.signatureAlgorithms.map(\.rawValue), testCase.offered)
            let algorithm = try XCTUnwrap(wrapped.signatureAlgorithms.first)
            let signature = try wrapped.signature(for: algorithm, data: data)
            XCTAssertTrue(SecKeyVerifySignature(publicKey, testCase.verifier, data as CFData, signature as CFData, &error))
        }
    }
}

/// A key to generate in memory, the TLS signature algorithms it should offer, and how to verify its first choice.
private struct KeyCase {
    let type: CFString
    let bits: Int
    let offered: [UInt16]

    var verifier: SecKeyAlgorithm {
        if type == kSecAttrKeyTypeRSA {
            return .rsaSignatureMessagePSSSHA256
        }
        return bits == 384 ? .ecdsaSignatureMessageX962SHA384 : .ecdsaSignatureMessageX962SHA256
    }
}

extension GRPCExecutorTests {
    /// Requires a client certificate from the fixture CA, as `TLSFixtures.serverContext` does for HTTP.
    func startMutualTLS(
        address: GRPCNIOTransportCore.SocketAddress = .ipv4(host: "127.0.0.1", port: 0),
        log: MetadataLog? = nil
    ) async throws -> GRPCTestServer {
        let leaf = try TLSFixtures.mint()
        let authority = [UInt8](try TLSFixtures.data("ca.pem"))
        let security = HTTP2ServerTransport.Posix.TransportSecurity.mTLS(
            certificateChain: [.bytes(Array(leaf.certificatePEM.utf8), format: .pem)],
            privateKey: .bytes(Array(leaf.privateKeyPEM.utf8), format: .pem)
        ) { config in
            config.trustRoots = .certificates([.bytes(authority, format: .pem)])
        }
        let server = try await GRPCTestServer.start([EchoService(log: log)], address: address, security: security)
        addTeardownBlock { await server.stop() }
        return server
    }

    func clientIdentity() throws -> TLSClientIdentity {
        try PKCS12Importer.importIdentity(try TLSFixtures.data("client.p12"), passphrase: try TLSFixtures.clientPassphrase)
    }

    func fixtureCA() throws -> [SecCertificate] {
        try CertificateLoader.certificates(from: try TLSFixtures.data("ca.pem"))
    }
}
