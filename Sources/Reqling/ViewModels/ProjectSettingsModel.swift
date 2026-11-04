import Foundation
import Observation
import ReqlingKit
import UniformTypeIdentifiers

/// Edits a project's name, project-level auth, client certificates, CA certificates, and proto definitions as a draft
/// that commits on Done. Passphrases go to the Keychain and Keychain identity choices to this Mac's workspace state,
/// never to files.
@MainActor
@Observable
final class ProjectSettingsModel {
    enum CertificateStatus: Equatable {
        case valid(CertificateSummary)
        case expired(CertificateSummary)
        case problem(String)
    }

    let projectID: ProjectID
    var name: String
    var auth: HTTPAuth
    var clientCertificates: [ClientCertificateEntry]
    var caCertificates: [ProjectPathReference]
    var passphrases: [CertificateEntryID: String]
    var keychainIdentities: [CertificateEntryID: Data]
    var protoRoots: [ProjectPathReference]
    var protoEntryFiles: [ProtoEntryFile]
    var descriptorSets: [ProjectPathReference]
    /// Entries whose stored passphrase the Keychain refused to read. Their field starts empty without meaning "no
    /// passphrase": saving keeps the stored value unless the user types a new one.
    private(set) var unreadablePassphrases: Set<CertificateEntryID>

    @ObservationIgnored unowned let app: AppModel
    @ObservationIgnored private let now: () -> Date
    /// The passphrases as loaded, so saving writes only the ones the user changed. One the Keychain refused to read is
    /// absent here and in `passphrases`, so leaving its field alone can never save the blank over the stored value.
    @ObservationIgnored private var savedPassphrases: [CertificateEntryID: String]
    /// The entries the project had, so saving can delete the passphrases and identity references of removed ones.
    @ObservationIgnored private var savedEntryIDs: Set<CertificateEntryID>

    init(projectID: ProjectID, app: AppModel, now: @escaping () -> Date = { Date() }) {
        self.projectID = projectID
        self.app = app
        self.now = now
        let document = app.library.document(projectID)
        name = document?.name ?? ""
        auth = document?.auth ?? .none
        let entries = document?.tls.clientCertificates ?? []
        clientCertificates = entries
        caCertificates = document?.tls.caCertificates ?? []
        let grpc = document?.grpc ?? ProjectGRPCConfiguration()
        protoRoots = grpc.protoRoots
        protoEntryFiles = grpc.protoFiles.map { ProtoEntryFile(path: $0) }
        descriptorSets = grpc.descriptorSets
        var passphrases: [CertificateEntryID: String] = [:]
        var unreadable: Set<CertificateEntryID> = []
        var identities: [CertificateEntryID: Data] = [:]
        for entry in entries {
            do {
                passphrases[entry.id] = try app.library.loadCertificatePassphrase(for: entry.id, in: projectID)
            } catch {
                unreadable.insert(entry.id)
            }
            identities[entry.id] = app.workspace.keychainIdentity(for: entry.id)
        }
        self.passphrases = passphrases
        unreadablePassphrases = unreadable
        savedPassphrases = passphrases
        savedEntryIDs = Set(entries.map(\.id))
        keychainIdentities = identities
    }

    var availableKeychainIdentities: [KeychainIdentityInfo] {
        app.keychain.availableIdentities()
    }

    func describe(_ reference: ProjectPathReference) -> String {
        app.pathResolver(for: projectID)?.describe(reference) ?? ""
    }

    // MARK: - Certificates

    func addPKCS12Certificate() {
        let types = ["p12", "pfx"].compactMap { UTType(filenameExtension: $0) }
        guard let url = app.system.chooseFile(prompt: "Add Certificate", allowedTypes: types),
              let reference = app.reference(for: url, in: projectID) else {
            return
        }
        clientCertificates.append(ClientCertificateEntry(hostPattern: "", source: .pkcs12(reference)))
    }

    func addKeychainCertificate() {
        let entry = ClientCertificateEntry(hostPattern: "", source: .keychainIdentity)
        clientCertificates.append(entry)
        keychainIdentities[entry.id] = availableKeychainIdentities.first?.persistentReference
    }

    func removeClientCertificate(_ id: CertificateEntryID) {
        clientCertificates.removeAll { $0.id == id }
        passphrases[id] = nil
        keychainIdentities[id] = nil
        unreadablePassphrases.remove(id)
    }

    func addCACertificate() {
        let types = ["pem", "crt", "cer", "der"].compactMap { UTType(filenameExtension: $0) }
        guard let url = app.system.chooseFile(prompt: "Add CA Certificate", allowedTypes: types),
              let reference = app.reference(for: url, in: projectID) else {
            return
        }
        caCertificates.append(reference)
    }

    func removeCACertificate(at index: Int) {
        guard caCertificates.indices.contains(index) else {
            return
        }
        caCertificates.remove(at: index)
    }

    func isValidHostPattern(_ pattern: String) -> Bool {
        HostPattern(pattern) != nil
    }

    /// Opens the entry the way a request would, so a wrong passphrase or missing file shows up here first.
    func status(of entry: ClientCertificateEntry) -> CertificateStatus {
        guard let paths = app.pathResolver(for: projectID) else {
            return .problem("The project is not available.")
        }
        let passphrase = passphrases[entry.id]
        if case .pkcs12 = entry.source, passphrase == nil, unreadablePassphrases.contains(entry.id) {
            return .problem("Reqling couldn't read this certificate's passphrase from the Keychain.")
        }
        let reference = keychainIdentities[entry.id]
        let resolver = ProjectTLSResolver(
            configuration: ProjectTLSConfiguration(clientCertificates: [entry]),
            paths: paths,
            passphrase: { _ in passphrase },
            keychainIdentityReference: { _ in reference },
            keychain: app.keychain
        )
        do {
            guard let certificate = try resolver.loadIdentity(entry).certificate else {
                return .problem("The identity has no certificate.")
            }
            return classify(CertificateSummary(certificate))
        } catch {
            return .problem(error.localizedDescription)
        }
    }

    func status(ofCA reference: ProjectPathReference) -> CertificateStatus {
        guard let paths = app.pathResolver(for: projectID) else {
            return .problem("The project is not available.")
        }
        do {
            let certificates = try CertificateLoader.certificates(from: try paths.data(for: reference))
            guard let first = certificates.first else {
                return .problem("The file contains no certificates.")
            }
            return classify(CertificateSummary(first))
        } catch {
            return .problem(error.localizedDescription)
        }
    }

    private func classify(_ summary: CertificateSummary) -> CertificateStatus {
        summary.isExpired(at: now()) ? .expired(summary) : .valid(summary)
    }

    // MARK: - Saving

    @discardableResult
    func save() -> Bool {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let tls = ProjectTLSConfiguration(clientCertificates: clientCertificates, caCertificates: caCertificates)
        let auth = auth
        let grpc = grpcConfiguration
        let saved: Void? = app.perform("Couldn't Save the Project Settings") {
            try app.library.mutate(projectID) { document in
                if !trimmedName.isEmpty {
                    document.name = trimmedName
                }
                document.auth = auth
                document.tls = tls
                document.grpc = grpc
            }
            try savePassphrasesAndIdentities()
        }
        return saved != nil
    }

    /// Writes only passphrases that differ from what was loaded, and forgets the secrets of removed entries.
    private func savePassphrasesAndIdentities() throws {
        let currentIDs = Set(clientCertificates.map(\.id))
        var changes: [CertificateEntryID: String?] = [:]
        for entry in clientCertificates {
            let passphrase = passphrases[entry.id].flatMap { $0.isEmpty ? nil : $0 }
            if passphrase != savedPassphrases[entry.id] {
                changes.updateValue(passphrase, forKey: entry.id)
            }
            app.workspace.setKeychainIdentity(keychainIdentities[entry.id], for: entry.id)
        }
        for removed in savedEntryIDs.subtracting(currentIDs) {
            changes.updateValue(nil, forKey: removed)
            app.workspace.setKeychainIdentity(nil, for: removed)
        }
        if !changes.isEmpty {
            try app.library.updateCertificatePassphrases(changes, in: projectID)
        }
        savedPassphrases = passphrases.filter { currentIDs.contains($0.key) && !$0.value.isEmpty }
        savedEntryIDs = currentIDs
        unreadablePassphrases = unreadablePassphrases.intersection(currentIDs).subtracting(changes.keys)
    }
}
