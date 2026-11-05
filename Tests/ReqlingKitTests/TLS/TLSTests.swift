import Foundation
import ReqlingKit
import Security
import Synchronization
import XCTest

final class HostPatternTests: XCTestCase {
    func testParsesHostsWildcardsAndPorts() {
        XCTAssertEqual(HostPattern("API.Example.com")?.host, "api.example.com")
        XCTAssertEqual(HostPattern("*.internal:8443")?.port, 8443)
        XCTAssertEqual(HostPattern("*.internal:8443")?.isWildcard, true)
        XCTAssertNil(HostPattern(""))
        XCTAssertNil(HostPattern("a.*.com"))
        XCTAssertNil(HostPattern("host:99999"))
        XCTAssertNil(HostPattern("https://host"))
    }

    func testMatching() {
        let wildcard = HostPattern("*.example.com")!
        XCTAssertTrue(wildcard.matches(host: "api.example.com", port: 443))
        XCTAssertTrue(wildcard.matches(host: "a.b.example.com", port: nil))
        XCTAssertFalse(wildcard.matches(host: "example.com", port: 443))
        XCTAssertFalse(HostPattern("example.com:8443")!.matches(host: "example.com", port: 443))
    }

    func testTheMostSpecificPatternWins() throws {
        let entries = ["*.example.com", "api.example.com", "*.api.example.com", "api.example.com:8443"].map {
            ClientCertificateEntry(hostPattern: $0, source: .keychainIdentity)
        }
        let resolver = ProjectTLSResolver(
            configuration: ProjectTLSConfiguration(clientCertificates: entries),
            paths: ProjectPathResolver(projectRoot: URL(fileURLWithPath: "/tmp")),
            passphrase: { _ in nil },
            keychainIdentityReference: { _ in nil },
            keychain: SystemKeychainIdentityStore(),
            pkcs12Probe: TLSFixtures.probe
        )

        XCTAssertEqual(resolver.entry(forHost: "api.example.com", port: 443)?.hostPattern, "api.example.com")
        XCTAssertEqual(resolver.entry(forHost: "api.example.com", port: 8443)?.hostPattern, "api.example.com:8443")
        XCTAssertEqual(resolver.entry(forHost: "v2.api.example.com", port: nil)?.hostPattern, "*.api.example.com")
        XCTAssertEqual(resolver.entry(forHost: "www.example.com", port: nil)?.hostPattern, "*.example.com")
        XCTAssertNil(resolver.entry(forHost: "other.org", port: nil))
    }
}

final class CertificateTests: XCTestCase {
    func testImportsTheFixtureIdentityInMemory() throws {
        let identity = try PKCS12Importer.importIdentity(
            try TLSFixtures.data("client.p12"),
            passphrase: TLSFixtures.clientPassphrase,
            probe: TLSFixtures.probe
        )

        XCTAssertEqual(identity.certificate.map { CertificateSummary($0).subject }, "Reqling Test Client")
    }

    func testAWrongPassphraseIsReportedAsSuch() throws {
        XCTAssertThrowsError(try PKCS12Importer.importIdentity(try TLSFixtures.data("client.p12"), passphrase: "nope", probe: TLSFixtures.probe)) {
            XCTAssertEqual($0 as? TLSError, .wrongPassphrase)
        }
    }

    /// Imported in this process, the file would end it: `SecPKCS12Import` raises an uncatchable exception on it.
    func testAFileThatCrashesTheImporterFailsClearlyInstead() throws {
        let explicit = try TLSFixtures.explicitCurveClientPKCS12

        XCTAssertThrowsError(try PKCS12Importer.importIdentity(explicit, passphrase: TLSFixtures.clientPassphrase, probe: TLSFixtures.probe)) {
            XCTAssertEqual($0 as? TLSError, .unsupportedCertificate)
        }
        // A wrong passphrase stops the importer before it reaches the certificate.
        XCTAssertThrowsError(try PKCS12Importer.importIdentity(explicit, passphrase: "nope", probe: TLSFixtures.probe)) {
            XCTAssertEqual($0 as? TLSError, .wrongPassphrase)
        }
    }

    func testAPEMPairWhoseCertificateKeyIsUnreadableFailsClearly() throws {
        let explicit = try TLSFixtures.explicitCurveClientPEM

        XCTAssertThrowsError(try PEMIdentityImporter.importIdentity(certificate: explicit.certificate, key: explicit.key, passphrase: "")) {
            XCTAssertEqual($0 as? TLSError, .unsupportedCertificate)
        }
        // Beside the leaf, such a certificate is never read for a key, so the pair still opens.
        let identity = try PEMIdentityImporter.importIdentity(
            certificate: try TLSFixtures.data("client.pem") + Data("\n".utf8) + explicit.certificate,
            key: try TLSFixtures.data("client-key.pem"),
            passphrase: ""
        )
        XCTAssertEqual(identity.certificate.map { CertificateSummary($0).subject }, "Reqling Test Client")
    }

    func testLoadsPEMAndDERCertificatesAndSummarizesThem() throws {
        let pem = try CertificateLoader.certificates(from: try TLSFixtures.data("ca.pem"))
        let der = try CertificateLoader.certificates(from: try TLSFixtures.data("ca.der"))
        let bundle = try CertificateLoader.certificates(from: try TLSFixtures.data("ca.pem") + TLSFixtures.data("client.pem"))

        XCTAssertEqual(pem.count, 1)
        XCTAssertEqual(der.count, 1)
        XCTAssertEqual(bundle.count, 2)
        let summary = CertificateSummary(bundle[1])
        XCTAssertEqual(summary.subject, "Reqling Test Client")
        XCTAssertEqual(summary.issuer, "Reqling Test CA")
        XCTAssertFalse(summary.isExpired(at: Date()))
        XCTAssertThrowsError(try CertificateLoader.certificates(from: Data("not a certificate".utf8)))
    }

    func testAnExpiredCertificateIsReportedExpired() throws {
        let minted = try TLSFixtures.mint(
            notValidBefore: Date().addingTimeInterval(-7200),
            notValidAfter: Date().addingTimeInterval(-3600)
        )
        let certificate = try XCTUnwrap(SecCertificateCreateWithData(nil, Data(minted.derBytes) as CFData))

        XCTAssertTrue(CertificateSummary(certificate).isExpired(at: Date()))
    }

    func testTrustEvaluationUsesTheProjectCAInAdditionToSystemRoots() throws {
        let leaf = try XCTUnwrap(SecCertificateCreateWithData(nil, Data(try TLSFixtures.mint().derBytes) as CFData))
        let authority = try CertificateLoader.certificates(from: try TLSFixtures.data("ca.pem"))
        func trust() throws -> SecTrust {
            var trust: SecTrust?
            XCTAssertEqual(SecTrustCreateWithCertificates([leaf] as CFArray, SecPolicyCreateSSL(true, nil), &trust), errSecSuccess)
            return try XCTUnwrap(trust)
        }

        XCTAssertNoThrow(try TLSTrustEvaluator.evaluate(trust(), host: "localhost", anchors: authority).get())
        XCTAssertThrowsError(try TLSTrustEvaluator.evaluate(trust(), host: "localhost", anchors: []).get())
        XCTAssertThrowsError(try TLSTrustEvaluator.evaluate(trust(), host: "example.com", anchors: authority).get())
    }

    func testTheResolverLoadsTheMatchingIdentityEagerlyAndFailsClearly() throws {
        let root = try TLSFixtures.directory
        let entry = ClientCertificateEntry(hostPattern: "localhost", source: .pkcs12(.relative("client.p12")))
        func resolver(passphrase: String?) -> ProjectTLSResolver {
            ProjectTLSResolver(
                configuration: ProjectTLSConfiguration(clientCertificates: [entry], caCertificates: [.relative("ca.pem")]),
                paths: ProjectPathResolver(projectRoot: root),
                passphrase: { _ in passphrase },
                keychainIdentityReference: { _ in nil },
                keychain: SystemKeychainIdentityStore(),
                pkcs12Probe: TLSFixtures.probe
            )
        }

        let context = try resolver(passphrase: TLSFixtures.clientPassphrase).context(host: "localhost", port: 443, verifiesServer: true)
        XCTAssertEqual(context.anchors.count, 1)
        XCTAssertNotNil(context.clientIdentity("localhost", 443))
        XCTAssertNil(context.clientIdentity("example.com", 443))
        XCTAssertThrowsError(try resolver(passphrase: "wrong").context(host: "localhost", port: 443, verifiesServer: true)) { error in
            XCTAssertEqual(error as? TLSError, .wrongPassphrase)
        }

        let missing = ProjectTLSResolver(
            configuration: ProjectTLSConfiguration(caCertificates: [.local(LocalPathID())]),
            paths: ProjectPathResolver(projectRoot: root),
            passphrase: { _ in nil },
            keychainIdentityReference: { _ in nil },
            keychain: SystemKeychainIdentityStore(),
            pkcs12Probe: TLSFixtures.probe
        )
        XCTAssertThrowsError(try missing.context(host: "localhost", port: 443, verifiesServer: true)) { error in
            XCTAssertEqual(error as? TLSError, .missingFile("A file chosen on another Mac"))
        }
    }

    func testTheResolverOpensAPEMEntryAndFailsClearlyWithoutItsKey() throws {
        func resolver(key: ProjectPathReference) throws -> ProjectTLSResolver {
            let entry = ClientCertificateEntry(hostPattern: "localhost", source: .pem(certificate: .relative("client.pem"), key: key))
            return ProjectTLSResolver(
                configuration: ProjectTLSConfiguration(clientCertificates: [entry]),
                paths: ProjectPathResolver(projectRoot: try TLSFixtures.directory),
                passphrase: { _ in nil },
                keychainIdentityReference: { _ in nil },
                keychain: SystemKeychainIdentityStore(),
                pkcs12Probe: TLSFixtures.probe
            )
        }

        let context = try resolver(key: .relative("client-key.pem")).context(host: "localhost", port: 443, verifiesServer: true)
        XCTAssertEqual(context.clientIdentity("localhost", 443)?.certificate.map { CertificateSummary($0).subject }, "Reqling Test Client")
        XCTAssertThrowsError(try resolver(key: .relative("missing.key")).context(host: "localhost", port: 443, verifiesServer: true)) { error in
            XCTAssertEqual(error as? TLSError, .missingFile("“missing.key”"))
        }
    }

    func testAPEMSourceIsStoredAsItsCertificateAndKey() throws {
        let json = #"{"type": "pem", "certificate": {"relative": "certs/client.crt"}, "key": {"relative": "certs/client.key"}}"#
        let source = ClientCertificateSource.pem(certificate: .relative("certs/client.crt"), key: .relative("certs/client.key"))

        XCTAssertEqual(try JSONDecoder().decode(ClientCertificateSource.self, from: Data(json.utf8)), source)
        XCTAssertEqual(try JSONDecoder().decode(ClientCertificateSource.self, from: try JSONEncoder().encode(source)), source)
        XCTAssertEqual(ClientCertificateSource.pem(certificate: .relative("both.pem"), key: .relative("both.pem")).files, [.relative("both.pem")])
    }
}

final class HelperPKCS12ImportProbeTests: XCTestCase {
    func testTheHelperTellsAFileThatOpensFromOneThatCrashesTheImporter() throws {
        let probe = TLSFixtures.probe

        XCTAssertNoThrow(try probe.check(try TLSFixtures.data("client.p12"), passphrase: TLSFixtures.clientPassphrase))
        XCTAssertThrowsError(try probe.check(try TLSFixtures.explicitCurveClientPKCS12, passphrase: TLSFixtures.clientPassphrase)) {
            XCTAssertEqual($0 as? TLSError, .unsupportedCertificate)
        }
    }

    func testAVerdictIsKeptPerFileAndPassphrase() throws {
        let launches = Mutex(0)
        let probe = HelperPKCS12ImportProbe(executable: URL(fileURLWithPath: "/bin/cat")) { exited in
            launches.withLock { $0 += 1 }
            return exited.wait(timeout: .distantFuture)
        }

        try probe.check(Data("file".utf8), passphrase: "a")
        try probe.check(Data("file".utf8), passphrase: "a")
        XCTAssertEqual(launches.withLock { $0 }, 1)
        try probe.check(Data("file".utf8), passphrase: "b")
        try probe.check(Data("other".utf8), passphrase: "a")
        XCTAssertEqual(launches.withLock { $0 }, 3)
    }

    func testACheckThatCannotFinishFailsClosedAndIsTriedAgain() throws {
        let attempts = Mutex(0)
        let probe = HelperPKCS12ImportProbe(executable: URL(fileURLWithPath: "/bin/cat")) { exited in
            let attempt = attempts.withLock { $0 += 1; return $0 }
            return attempt == 1 ? .timedOut : exited.wait(timeout: .distantFuture)
        }

        XCTAssertThrowsError(try probe.check(Data("file".utf8), passphrase: "")) {
            XCTAssertEqual($0 as? TLSError, .certificateCheckFailed("The check did not finish in time."))
        }
        XCTAssertNoThrow(try probe.check(Data("file".utf8), passphrase: ""))
    }

    /// Unlike a crash, a kill from outside says nothing of the file, so nothing is kept and the next check runs again.
    /// A crash signal stays untested here: it would leave a crash report on the developer's Mac each run.
    func testAKillFromOutsideIsNotTheFilesVerdict() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let script = directory.file("terminated.sh")
        try Data("#!/bin/sh\nkill -TERM $$\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let probe = HelperPKCS12ImportProbe(executable: script)

        for _ in 0..<2 {
            XCTAssertThrowsError(try probe.check(Data(), passphrase: "")) {
                XCTAssertEqual($0 as? TLSError, .certificateCheckFailed("The checker was stopped by signal \(SIGTERM)."))
            }
        }
    }

    func testAMissingOrFailingHelperFailsEveryCheck() throws {
        XCTAssertThrowsError(try HelperPKCS12ImportProbe(executable: nil).check(Data(), passphrase: "")) {
            XCTAssertEqual($0 as? TLSError, .certificateCheckFailed("Reqling's certificate checker is missing. Reinstall Reqling."))
        }
        XCTAssertThrowsError(try HelperPKCS12ImportProbe(executable: URL(fileURLWithPath: "/usr/bin/false")).check(Data(), passphrase: "")) {
            XCTAssertEqual($0 as? TLSError, .certificateCheckFailed("The checker exited with status 1."))
        }
    }
}
