import Foundation
import ReqlingKit
import Security
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
            keychain: SystemKeychainIdentityStore()
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
        let identity = try PKCS12Importer.importIdentity(try TLSFixtures.data("client.p12"), passphrase: TLSFixtures.clientPassphrase)

        XCTAssertEqual(identity.certificate.map { CertificateSummary($0).subject }, "Reqling Test Client")
    }

    func testAWrongPassphraseIsReportedAsSuch() throws {
        XCTAssertThrowsError(try PKCS12Importer.importIdentity(try TLSFixtures.data("client.p12"), passphrase: "nope")) { error in
            XCTAssertEqual(error as? TLSError, .wrongPassphrase)
        }
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
                keychain: SystemKeychainIdentityStore()
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
            keychain: SystemKeychainIdentityStore()
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
                keychain: SystemKeychainIdentityStore()
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
