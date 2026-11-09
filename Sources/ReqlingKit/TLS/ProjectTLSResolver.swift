import Foundation
import Security

/// Turns a project's TLS configuration into the `TLSContext` one request runs with.
public struct ProjectTLSResolver: Sendable {
    public let configuration: ProjectTLSConfiguration
    public let paths: ProjectPathResolver
    public let passphrase: @Sendable (CertificateEntryID) -> String?
    public let keychainIdentityReference: @Sendable (CertificateEntryID) -> Data?
    public let keychain: any KeychainIdentityStore
    public let pkcs12Probe: any PKCS12ImportProbe

    public init(
        configuration: ProjectTLSConfiguration,
        paths: ProjectPathResolver,
        passphrase: @escaping @Sendable (CertificateEntryID) -> String?,
        keychainIdentityReference: @escaping @Sendable (CertificateEntryID) -> Data?,
        keychain: any KeychainIdentityStore,
        pkcs12Probe: any PKCS12ImportProbe
    ) {
        self.configuration = configuration
        self.paths = paths
        self.passphrase = passphrase
        self.keychainIdentityReference = keychainIdentityReference
        self.keychain = keychain
        self.pkcs12Probe = pkcs12Probe
    }

    /// The context for a request to `host`. The matching identity and the CA files load eagerly, so a wrong passphrase
    /// or a missing file fails the request with a clear error before anything is sent. Other hosts (after a
    /// redirect) load their identity lazily and simply present none if it cannot be opened.
    public func context(host: String, port: Int?, verifiesServer: Bool) throws(TLSError) -> TLSContext {
        let anchors = try loadAnchors()
        let initial = try entry(forHost: host, port: port).map { entry throws(TLSError) in try loadIdentity(entry) }
        let resolver = self
        return TLSContext(verifiesServer: verifiesServer, anchors: anchors, identitySource: identitySource()) { candidateHost, candidatePort in
            if candidateHost.lowercased() == host.lowercased(), candidatePort == port {
                return initial
            }
            return resolver.entry(forHost: candidateHost, port: candidatePort).flatMap { try? resolver.loadIdentity($0) }
        }
    }

    /// The most specific entry whose pattern matches.
    public func entry(forHost host: String, port: Int?) -> ClientCertificateEntry? {
        configuration.clientCertificates
            .compactMap { entry in HostPattern(entry.hostPattern).map { (entry, $0) } }
            .filter { $0.1.matches(host: host, port: port) }
            .max { $0.1.specificity < $1.1.specificity }?
            .0
    }

    public func loadIdentity(_ entry: ClientCertificateEntry) throws(TLSError) -> TLSClientIdentity {
        switch entry.source {
        case .pkcs12(let file):
            return try PKCS12Importer.importIdentity(try paths.identityData(for: file), passphrase: passphrase(entry.id) ?? "", probe: pkcs12Probe)
        case .pem(let certificate, let key):
            return try PEMIdentityImporter.importIdentity(
                certificate: try paths.identityData(for: certificate),
                key: try paths.identityData(for: key),
                passphrase: passphrase(entry.id) ?? ""
            )
        case .keychainIdentity:
            guard let reference = keychainIdentityReference(entry.id) else {
                throw .missingFile("The Keychain identity for \(entry.hostPattern)")
            }
            return try keychain.identity(for: reference)
        }
    }

    /// Everything the identities come from, for `TLSContext.fingerprint`: editing an entry, replacing its file, or
    /// fixing its passphrase must open new connections rather than reuse ones that presented the old identity.
    private func identitySource() -> Data {
        var source = Data()
        func add(_ data: Data) {
            withUnsafeBytes(of: UInt64(data.count).bigEndian) { source.append(contentsOf: $0) }
            source.append(data)
        }
        for entry in configuration.clientCertificates {
            add(Data(entry.id.description.utf8))
            add(Data(entry.hostPattern.utf8))
            switch entry.source {
            case .pkcs12(let file):
                add(Data("pkcs12".utf8))
                add((try? paths.identityData(for: file)) ?? Data())
                add(Data((passphrase(entry.id) ?? "").utf8))
            case .pem(let certificate, let key):
                add(Data("pem".utf8))
                add((try? paths.identityData(for: certificate)) ?? Data())
                add((try? paths.identityData(for: key)) ?? Data())
                add(Data((passphrase(entry.id) ?? "").utf8))
            case .keychainIdentity:
                add(Data("keychain".utf8))
                add(keychainIdentityReference(entry.id) ?? Data())
            }
        }
        return source
    }

    public func loadAnchors() throws(TLSError) -> [SecCertificate] {
        var anchors: [SecCertificate] = []
        for reference in configuration.caCertificates {
            anchors += try CertificateLoader.certificates(from: try paths.data(for: reference))
        }
        return anchors
    }
}
