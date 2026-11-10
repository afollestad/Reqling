import Crypto
import CryptoExtras
import Foundation
import NIOSSL
import ReqlingKit
import SwiftASN1
import X509

/// Test-only TLS material, minted once per test process so no key or passphrase is ever committed: a CA, a client
/// identity it signed (`client.pem` with its PKCS#8 key `client-key.pem`, and `client.p12` under a random passphrase),
/// an RSA twin of that identity, and server leaves on demand. Leaves stay short-lived because Apple's SSL policy
/// rejects server certificates valid for more than 825 days.
///
/// The CA and client files live in a per-process temporary `directory`, removed at exit. Packaging the PKCS#12 and
/// encrypting keys shell out to `/usr/bin/openssl`, which ships with macOS; the PKCS#12 fixtures stay independent of
/// the NIOSSL packaging `PEMIdentityImporter` uses.
enum TLSFixtures {
    static var directory: URL {
        get throws { try authority.get().directory }
    }

    static var clientPassphrase: String {
        get throws { try authority.get().passphrase }
    }

    /// A probe that runs the real `ReqlingPKCS12Probe`, which `swift test` builds into this bundle's products
    /// directory. Fresh per use, so no test sees another's kept verdicts.
    static var probe: HelperPKCS12ImportProbe {
        HelperPKCS12ImportProbe(executable: helper)
    }

    static var helper: URL {
        Bundle(for: FixtureBundleToken.self).bundleURL.deletingLastPathComponent().appendingPathComponent("ReqlingPKCS12Probe")
    }

    /// `client-explicit.p12`: a self-signed client identity whose certificate's EC key uses explicit curve parameters,
    /// under `clientPassphrase`. Security reads no key from that certificate, and `SecPKCS12Import` crashes on it.
    /// Minted by `openssl` on first use, since swift-certificates writes only named curves.
    static var explicitCurveClientPKCS12: Data {
        get throws { try Data(contentsOf: explicitCurveDirectory.get().appendingPathComponent("client-explicit.p12")) }
    }

    /// The explicit-curve identity's certificate and its SEC1 key, as PEM.
    static var explicitCurveClientPEM: (certificate: Data, key: Data) {
        get throws {
            let directory = try explicitCurveDirectory.get()
            return (
                try Data(contentsOf: directory.appendingPathComponent("client-explicit.pem")),
                try Data(contentsOf: directory.appendingPathComponent("client-explicit-key.pem"))
            )
        }
    }

    /// One of `ca.pem`, `ca.der`, `client.pem`, `client-key.pem`, or `client.p12`.
    static func url(_ name: String) throws -> URL {
        try directory.appendingPathComponent(name)
    }

    static func data(_ name: String) throws -> Data {
        try Data(contentsOf: url(name))
    }

    /// `client-rsa.p12`: the client identity with an RSA 2048 key instead of P-256, under `clientPassphrase`. Most
    /// client certificates in use are RSA, and a TLS 1.3 handshake signs with one differently (RSA-PSS). Minted on
    /// first use, because RSA key generation is slow.
    static var rsaClientPKCS12: Data {
        get throws { try Data(contentsOf: rsaClient.get().appendingPathComponent("client-rsa.p12")) }
    }

    /// The RSA twin's certificate and its PKCS#1 key (`BEGIN RSA PRIVATE KEY`), as PEM.
    static var rsaClientPEM: (certificate: Data, key: Data) {
        get throws {
            let directory = try rsaClient.get()
            return (
                try Data(contentsOf: directory.appendingPathComponent("client-rsa.pem")),
                try Data(contentsOf: directory.appendingPathComponent("client-rsa-key.pem"))
            )
        }
    }

    /// `client-key.pem` as encrypted PKCS#8 (`BEGIN ENCRYPTED PRIVATE KEY`) under `clientPassphrase`.
    static var encryptedClientKey: Data {
        get throws { try Data(contentsOf: encryptedKeys.get().pkcs8) }
    }

    /// The RSA twin's key in OpenSSL's legacy encrypted PEM (`Proc-Type: 4,ENCRYPTED`) under `clientPassphrase`.
    static var legacyEncryptedRSAClientKey: Data {
        get throws { try Data(contentsOf: encryptedKeys.get().legacyRSA) }
    }

    struct Minted {
        let certificatePEM: String
        let privateKeyPEM: String
        let derBytes: [UInt8]
    }

    /// A leaf signed by the fixture CA. Server leaves carry `localhost` and `127.0.0.1` names.
    static func mint(
        commonName: String = "localhost",
        serverAuth: Bool = true,
        notValidBefore: Date = Date().addingTimeInterval(-3600),
        notValidAfter: Date = Date().addingTimeInterval(30 * 86_400)
    ) throws -> Minted {
        let authority = try authority.get()
        return try sign(
            commonName: commonName,
            serverAuth: serverAuth,
            key: .p256,
            validity: notValidBefore...notValidAfter,
            issuer: authority
        )
    }

    /// A server context for the loopback server; `requireClientCertificate` rejects clients without a certificate
    /// from the fixture CA.
    static func serverContext(requireClientCertificate: Bool) throws -> NIOSSLContext {
        let leaf = try mint()
        var configuration = TLSConfiguration.makeServerConfiguration(
            certificateChain: [.certificate(try NIOSSLCertificate(bytes: Array(leaf.certificatePEM.utf8), format: .pem))],
            privateKey: .privateKey(try NIOSSLPrivateKey(bytes: Array(leaf.privateKeyPEM.utf8), format: .pem))
        )
        if requireClientCertificate {
            configuration.certificateVerification = .noHostnameVerification
            configuration.trustRoots = .certificates([try NIOSSLCertificate(bytes: Array(try data("ca.pem")), format: .pem)])
        }
        return try NIOSSLContext(configuration: configuration)
    }
}

private struct FixtureAuthority: Sendable {
    let directory: URL
    let caKey: P256.Signing.PrivateKey
    let caCertificate: Certificate
    let passphrase: String
}

private struct FixtureError: Error, CustomStringConvertible {
    let description: String
}

private final class FixtureBundleToken {}

private enum LeafKeyType {
    case p256
    case rsa
}

extension TLSFixtures {
    /// Built on first use; a failure (no `openssl`) fails each test that needs it rather than crashing the process.
    private static let authority = Result<FixtureAuthority, any Error> { try makeAuthority() }

    /// The fixture directory, once `client-rsa.*` is in it.
    private static let rsaClient = Result<URL, any Error> { try makeRSAClient() }

    private static let encryptedKeys = Result<(pkcs8: URL, legacyRSA: URL), any Error> { try makeEncryptedKeys() }

    /// The fixture directory, once `client-explicit*` is in it.
    private static let explicitCurveDirectory = Result<URL, any Error> { try makeExplicitCurveClient() }

    private static func makeAuthority() throws -> FixtureAuthority {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReqlingTLSFixtures-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        atexit {
            if case .success(let authority) = TLSFixtures.authority {
                try? FileManager.default.removeItem(at: authority.directory)
            }
        }

        let caKey = P256.Signing.PrivateKey()
        let caName = try DistinguishedName { CommonName("Reqling Test CA") }
        let now = Date()
        let caCertificate = try Certificate(
            version: .v3,
            serialNumber: Certificate.SerialNumber(),
            publicKey: .init(caKey.publicKey),
            notValidBefore: now.addingTimeInterval(-3600),
            notValidAfter: now.addingTimeInterval(365 * 86_400),
            issuer: caName,
            subject: caName,
            signatureAlgorithm: .ecdsaWithSHA256,
            extensions: try Certificate.Extensions {
                Critical(BasicConstraints.isCertificateAuthority(maxPathLength: nil))
                Critical(KeyUsage(keyCertSign: true, cRLSign: true))
            },
            issuerPrivateKey: .init(caKey)
        )
        var serializer = DER.Serializer()
        try serializer.serialize(caCertificate)
        let caPEM = try caCertificate.serializeAsPEM().pemString
        try Data(caPEM.utf8).write(to: directory.appendingPathComponent("ca.pem"))
        try Data(serializer.serializedBytes).write(to: directory.appendingPathComponent("ca.der"))

        let authority = FixtureAuthority(directory: directory, caKey: caKey, caCertificate: caCertificate, passphrase: UUID().uuidString)
        try makeClient(named: "client", commonName: "Reqling Test Client", key: .p256, issuer: authority)
        return authority
    }

    private static func makeRSAClient() throws -> URL {
        let authority = try authority.get()
        try makeClient(named: "client-rsa", commonName: "Reqling Test RSA Client", key: .rsa, issuer: authority)
        return authority.directory
    }

    private static func makeEncryptedKeys() throws -> (pkcs8: URL, legacyRSA: URL) {
        let directory = try rsaClient.get()
        let passphrase = try clientPassphrase
        let pkcs8 = directory.appendingPathComponent("client-key-encrypted.pem")
        let legacyRSA = directory.appendingPathComponent("client-rsa-key-encrypted.pem")
        try openssl([
            "pkcs8", "-topk8", "-v2", "aes-256-cbc", "-in", directory.appendingPathComponent("client-key.pem").path,
            "-passout", "env:REQLING_FIXTURE_PASSPHRASE", "-out", pkcs8.path
        ], passphrase: passphrase)
        try openssl([
            "rsa", "-aes256", "-in", directory.appendingPathComponent("client-rsa-key.pem").path,
            "-passout", "env:REQLING_FIXTURE_PASSPHRASE", "-out", legacyRSA.path
        ], passphrase: passphrase)
        return (pkcs8, legacyRSA)
    }

    private static func makeExplicitCurveClient() throws -> URL {
        let directory = try authority.get().directory
        let passphrase = try clientPassphrase
        let namedKey = directory.appendingPathComponent("client-explicit-named-key.pem")
        let key = directory.appendingPathComponent("client-explicit-key.pem")
        let certificate = directory.appendingPathComponent("client-explicit.pem")
        // A key Security drops would let the importer return instead of crashing.
        let privateKey = securityReadableP256Key()
        try Data(privateKey.pemRepresentation.utf8).write(to: namedKey)
        defer { try? FileManager.default.removeItem(at: namedKey) }
        try openssl(["ec", "-in", namedKey.path, "-param_enc", "explicit", "-out", key.path], passphrase: passphrase)
        try openssl([
            "req", "-new", "-x509", "-key", key.path, "-subj", "/CN=Reqling Test Explicit Curve Client", "-days", "1",
            "-out", certificate.path
        ], passphrase: passphrase)
        try openssl([
            "pkcs12", "-export", "-descert", "-inkey", key.path, "-in", certificate.path, "-name", "client-explicit",
            "-passout", "env:REQLING_FIXTURE_PASSPHRASE", "-out", directory.appendingPathComponent("client-explicit.p12").path
        ], passphrase: passphrase)
        return directory
    }

    /// A client identity valid for a year, packaged by `package(_:as:passphrase:in:)`.
    private static func makeClient(named name: String, commonName: String, key: LeafKeyType, issuer: FixtureAuthority) throws {
        let now = Date()
        let client = try sign(
            commonName: commonName,
            serverAuth: false,
            key: key,
            validity: now.addingTimeInterval(-3600)...now.addingTimeInterval(365 * 86_400),
            issuer: issuer
        )
        try package(client, as: name, passphrase: issuer.passphrase, in: issuer.directory)
    }

    private static func sign(
        commonName: String,
        serverAuth: Bool,
        key keyType: LeafKeyType,
        validity: ClosedRange<Date>,
        issuer: FixtureAuthority
    ) throws -> Minted {
        let publicKey: Certificate.PublicKey
        let privateKeyPEM: String
        switch keyType {
        case .p256:
            let key = securityReadableP256Key()
            publicKey = .init(key.publicKey)
            privateKeyPEM = key.pemRepresentation
        case .rsa:
            let key = try _RSA.Signing.PrivateKey(keySize: .bits2048)
            publicKey = .init(key.publicKey)
            privateKeyPEM = key.pemRepresentation
        }
        let certificate = try Certificate(
            version: .v3,
            serialNumber: Certificate.SerialNumber(),
            publicKey: publicKey,
            notValidBefore: validity.lowerBound,
            notValidAfter: validity.upperBound,
            issuer: issuer.caCertificate.subject,
            subject: try DistinguishedName { CommonName(commonName) },
            signatureAlgorithm: .ecdsaWithSHA256,
            extensions: try Certificate.Extensions {
                Critical(BasicConstraints.notCertificateAuthority)
                Critical(KeyUsage(digitalSignature: true))
                try ExtendedKeyUsage([serverAuth ? .serverAuth : .clientAuth])
                if serverAuth {
                    SubjectAlternativeNames([.dnsName("localhost"), .ipAddress(ASN1OctetString(contentBytes: [127, 0, 0, 1]))])
                }
            },
            issuerPrivateKey: .init(issuer.caKey)
        )
        var serializer = DER.Serializer()
        try serializer.serialize(certificate)
        return Minted(
            certificatePEM: try certificate.serializeAsPEM().pemString,
            privateKeyPEM: privateKeyPEM,
            derBytes: serializer.serializedBytes
        )
    }

    /// A key whose private scalar starts with a nonzero byte, as one in 256 random keys doesn't. `openssl` (LibreSSL)
    /// writes the scalar without its leading zero bytes, a key Security cannot read, so `SecPKCS12Import` drops it and
    /// returns no identity: every test in the process that opens the file would fail at once.
    private static func securityReadableP256Key() -> P256.Signing.PrivateKey {
        var key = P256.Signing.PrivateKey()
        while key.rawRepresentation.first == 0 {
            key = P256.Signing.PrivateKey()
        }
        return key
    }

    /// Writes `<name>.pem`, its key `<name>-key.pem`, and `<name>.p12` with the CA in its chain. An EC key is PKCS#8
    /// with a named curve, which `SecPKCS12Import` requires.
    private static func package(_ client: Minted, as name: String, passphrase: String, in directory: URL) throws {
        let certificateURL = directory.appendingPathComponent("\(name).pem")
        try Data(client.certificatePEM.utf8).write(to: certificateURL)
        let keyURL = directory.appendingPathComponent("\(name)-key.pem")
        try Data(client.privateKeyPEM.utf8).write(to: keyURL)
        try openssl([
            "pkcs12", "-export", "-descert",
            "-inkey", keyURL.path,
            "-in", certificateURL.path,
            "-certfile", directory.appendingPathComponent("ca.pem").path,
            "-name", name,
            "-passout", "env:REQLING_FIXTURE_PASSPHRASE",
            "-out", directory.appendingPathComponent("\(name).p12").path
        ], passphrase: passphrase)
    }

    /// Runs `/usr/bin/openssl`; the passphrase travels through the environment rather than the argument list.
    private static func openssl(_ arguments: [String], passphrase: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        process.arguments = arguments
        process.environment = ["REQLING_FIXTURE_PASSPHRASE": passphrase]
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(bytes: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw FixtureError(description: "openssl \(arguments.first ?? "") failed (\(process.terminationStatus)): \(message)")
        }
    }
}
