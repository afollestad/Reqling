import Crypto
import CryptoExtras
import Foundation
import NIOSSL
import SwiftASN1
import X509

/// Test-only TLS material, minted once per test process so no key or passphrase is ever committed: a CA, a client
/// identity it signed (`client.pem`, and `client.p12` under a random passphrase), an RSA twin of that identity, and
/// server leaves on demand. Leaves stay short-lived because Apple's SSL policy rejects server certificates valid for
/// more than 825 days.
///
/// The CA and client files live in a per-process temporary `directory`, removed at exit. Packaging the PKCS#12 shells
/// out to `/usr/bin/openssl`, which ships with macOS: neither Security nor swift-certificates can write one.
enum TLSFixtures {
    static var directory: URL {
        get throws { try authority.get().directory }
    }

    static var clientPassphrase: String {
        get throws { try authority.get().passphrase }
    }

    /// One of `ca.pem`, `ca.der`, `client.pem`, or `client.p12`.
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
        get throws { try Data(contentsOf: rsaClient.get()) }
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

private enum LeafKeyType {
    case p256
    case rsa
}

extension TLSFixtures {
    /// Built on first use; a failure (no `openssl`) fails each test that needs it rather than crashing the process.
    private static let authority = Result<FixtureAuthority, any Error> { try makeAuthority() }

    private static let rsaClient = Result<URL, any Error> { try makeRSAClient() }

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
        try makeClient(named: "client-rsa", commonName: "Reqling Test RSA Client", key: .rsa, issuer: authority.get())
    }

    /// A client identity valid for a year, packaged by `package(_:as:passphrase:in:)`.
    @discardableResult
    private static func makeClient(named name: String, commonName: String, key: LeafKeyType, issuer: FixtureAuthority) throws -> URL {
        let now = Date()
        let client = try sign(
            commonName: commonName,
            serverAuth: false,
            key: key,
            validity: now.addingTimeInterval(-3600)...now.addingTimeInterval(365 * 86_400),
            issuer: issuer
        )
        return try package(client, as: name, passphrase: issuer.passphrase, in: issuer.directory)
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
            let key = P256.Signing.PrivateKey()
            publicKey = .init(key.publicKey)
            privateKeyPEM = key.pemRepresentation
        case .rsa:
            let key = try _RSA.Signing.PrivateKey(keySize: .bits2048)
            publicKey = .init(key.publicKey)
            privateKeyPEM = key.pkcs8PEMRepresentation
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

    /// Writes `<name>.pem` and `<name>.p12`, with the CA in its chain, and returns the `.p12`. The key is PKCS#8, with a
    /// named curve for EC, which `SecPKCS12Import` requires; the passphrase travels through the environment rather
    /// than the argument list.
    private static func package(_ client: Minted, as name: String, passphrase: String, in directory: URL) throws -> URL {
        let outputURL = directory.appendingPathComponent("\(name).p12")
        let certificateURL = directory.appendingPathComponent("\(name).pem")
        try Data(client.certificatePEM.utf8).write(to: certificateURL)
        let keyURL = directory.appendingPathComponent("\(name)-key.pem")
        try Data(client.privateKeyPEM.utf8).write(to: keyURL)
        defer { try? FileManager.default.removeItem(at: keyURL) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        process.arguments = [
            "pkcs12", "-export", "-descert",
            "-inkey", keyURL.path,
            "-in", certificateURL.path,
            "-certfile", directory.appendingPathComponent("ca.pem").path,
            "-name", name,
            "-passout", "env:REQLING_FIXTURE_PASSPHRASE",
            "-out", outputURL.path
        ]
        process.environment = ["REQLING_FIXTURE_PASSPHRASE": passphrase]
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(bytes: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw FixtureError(description: "openssl pkcs12 failed (\(process.terminationStatus)): \(message)")
        }
        return outputURL
    }
}
