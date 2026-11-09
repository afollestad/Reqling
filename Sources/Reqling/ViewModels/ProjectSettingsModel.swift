import Foundation
import Observation
import ReqlingKit
import UniformTypeIdentifiers

/// Edits a project's name, project-level auth, client certificates, CA certificates, and proto definitions as a draft
/// that commits on Done. Passphrases go to the Keychain and Keychain identity choices to this Mac's workspace state,
/// never to files.
///
/// Done merges the draft into what is stored now (see `save()`), so an agent's or a `git pull`'s change made while the
/// sheet was open survives unless the sheet changed the same setting or certificate entry.
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
    /// Each client certificate's status as `refreshStatus(of:)` last found it; none until its first check finishes.
    private(set) var certificateStatuses: [CertificateEntryID: CertificateStatus] = [:]

    @ObservationIgnored unowned let app: AppModel
    @ObservationIgnored private let now: () -> Date
    /// The passphrases as loaded, so saving writes only the ones the user changed. One the Keychain refused to read is
    /// absent here and in `passphrases`, so leaving its field alone can never save the blank over the stored value.
    @ObservationIgnored private var savedPassphrases: [CertificateEntryID: String] = [:]
    /// The Keychain identity choices as loaded, so saving writes only the ones the user changed.
    @ObservationIgnored private var savedKeychainIdentities: [CertificateEntryID: Data] = [:]
    /// The entries the project had, so saving can delete the passphrases and identity references of removed ones.
    @ObservationIgnored private var savedEntryIDs: Set<CertificateEntryID> = []
    /// The settings as loaded or last saved: the base of Done's merge.
    @ObservationIgnored private var base: ProjectSettingsBase
    /// Serial and off the cooperative pool: a status check blocks while `PKCS12ImportProbe` waits on its helper.
    @ObservationIgnored private let statusQueue = DispatchQueue(label: "com.afollestad.reqling.certificate-status")

    init(projectID: ProjectID, app: AppModel, now: @escaping () -> Date = { Date() }) {
        self.projectID = projectID
        self.app = app
        self.now = now
        let document = app.library.document(projectID)
        let base = ProjectSettingsBase(
            name: document?.name ?? "",
            auth: document?.auth ?? .none,
            tls: document?.tls ?? ProjectTLSConfiguration(),
            grpc: document?.grpc ?? ProjectGRPCConfiguration()
        )
        self.base = base
        name = base.name
        auth = base.auth
        clientCertificates = base.tls.clientCertificates
        caCertificates = base.tls.caCertificates
        protoRoots = base.grpc.protoRoots
        protoEntryFiles = base.grpc.protoFiles.map { ProtoEntryFile(path: $0) }
        descriptorSets = base.grpc.descriptorSets
        passphrases = [:]
        keychainIdentities = [:]
        unreadablePassphrases = []
        self.base.grpc = grpcConfiguration
        loadSecrets(of: clientCertificates)
    }

    var availableKeychainIdentities: [KeychainIdentityInfo] {
        app.keychain.availableIdentities()
    }

    func describe(_ reference: ProjectPathReference, in slot: ProjectPathSlot) -> String {
        app.pathResolver(for: projectID)?.describe(reference, in: slot) ?? ""
    }

    // MARK: - Certificates

    /// A PKCS#12 file, or a certificate and its private key: the same file when it holds the key, otherwise one a second
    /// panel asks for. Both are chosen before either becomes a reference, so cancelling the second registers no path.
    func addCertificateFile() {
        let types = ["p12", "pfx", "pem", "crt", "cer"].compactMap { UTType(filenameExtension: $0) }
        guard let url = app.system.chooseFile(prompt: "Add Certificate", allowedTypes: types) else {
            return
        }
        // The entry's ID comes first: its files are chosen for it.
        let id = CertificateEntryID()
        guard !["p12", "pfx"].contains(url.pathExtension.lowercased()) else {
            if let reference = app.reference(for: url, in: projectID, at: .clientCertificate(id)) {
                clientCertificates.append(ClientCertificateEntry(id: id, hostPattern: "", source: .pkcs12(reference)))
            }
            return
        }
        let keyURL: URL
        if let data = try? Data(contentsOf: url), PEMIdentityImporter.containsPrivateKey(data) {
            keyURL = url
        } else {
            // Unfiltered: keys come as .key, .pem, or no extension, and the system types .key as a Keynote document.
            let message = "Choose the private key for \(url.lastPathComponent)."
            guard let chosen = app.system.chooseFile(prompt: "Choose Private Key", message: message, allowedTypes: []) else {
                return
            }
            keyURL = chosen
        }
        guard let certificate = app.reference(for: url, in: projectID, at: .clientCertificate(id)),
              let key = keyURL == url ? certificate : app.reference(for: keyURL, in: projectID, at: .clientCertificate(id)) else {
            return
        }
        clientCertificates.append(ClientCertificateEntry(id: id, hostPattern: "", source: .pem(certificate: certificate, key: key)))
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
        certificateStatuses[id] = nil
    }

    func addCACertificate() {
        let types = ["pem", "crt", "cer", "der"].compactMap { UTType(filenameExtension: $0) }
        guard let url = app.system.chooseFile(prompt: "Add CA Certificate", allowedTypes: types),
              let reference = app.reference(for: url, in: projectID, at: .caCertificates) else {
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

    /// Opens the entry the way a request would, so a wrong passphrase or missing file shows up here first, and keeps
    /// the result in `certificateStatuses`. The row starts it from `.task(id:)`, never from `body`: the first check of
    /// a PKCS#12 file and passphrase launches the probe's helper. A check superseded while it ran keeps nothing.
    @discardableResult
    func refreshStatus(of entry: ClientCertificateEntry) async -> CertificateStatus {
        let status = await loadStatus(of: entry)
        if !Task.isCancelled, clientCertificates.contains(where: { $0.id == entry.id }) {
            certificateStatuses[entry.id] = status
        }
        return status
    }

    private func loadStatus(of entry: ClientCertificateEntry) async -> CertificateStatus {
        guard let paths = app.pathResolver(for: projectID) else {
            return .problem("The project is not available.")
        }
        let passphrase = passphrases[entry.id]
        if entry.source.usesPassphrase, passphrase == nil, unreadablePassphrases.contains(entry.id) {
            return .problem("Reqling couldn't read this certificate's passphrase from the Keychain.")
        }
        let reference = keychainIdentities[entry.id]
        let resolver = ProjectTLSResolver(
            configuration: ProjectTLSConfiguration(clientCertificates: [entry]),
            paths: paths,
            passphrase: { _ in passphrase },
            keychainIdentityReference: { _ in reference },
            keychain: app.keychain,
            pkcs12Probe: app.pkcs12Probe
        )
        let summary = await withCheckedContinuation { (continuation: CheckedContinuation<Result<CertificateSummary?, TLSError>, Never>) in
            statusQueue.async {
                continuation.resume(returning: Result { () throws(TLSError) in
                    try resolver.loadIdentity(entry).certificate.map(CertificateSummary.init)
                })
            }
        }
        switch summary {
        case .success(let summary?):
            return classify(summary)
        case .success(nil):
            return .problem("The identity has no certificate.")
        case .failure(let error):
            return .problem(error.localizedDescription)
        }
    }

    func status(ofCA reference: ProjectPathReference) -> CertificateStatus {
        guard let paths = app.pathResolver(for: projectID) else {
            return .problem("The project is not available.")
        }
        do {
            let certificates = try CertificateLoader.certificates(from: try paths.data(for: reference, in: .caCertificates))
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

    /// Merges the draft into the stored settings, three-way against what the sheet loaded: the name, auth, CA
    /// certificates, and proto definitions each as one field, and client certificates per entry ID (`ListMerge`), an
    /// entry whose passphrase or Keychain identity the sheet changed counting as edited. Whatever the sheet left alone
    /// takes the stored version, deletions included; where both changed the same thing, the sheet wins.
    @discardableResult
    func save() -> Bool {
        let base = base
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        // A blank name was never saved; it leaves whatever is stored.
        let newName = name != base.name && !trimmedName.isEmpty ? trimmedName : nil
        let auth = auth
        let clientCertificates = clientCertificates
        let caCertificates = caCertificates
        let grpc = grpcConfiguration
        let secretsChanged = entriesWithChangedSecrets
        let saved = app.perform("Couldn't Save the Project Settings") {
            let merged = try app.library.mutate(projectID) { document in
                document.name = newName ?? document.name
                if auth != base.auth {
                    document.auth = auth
                }
                document.tls.clientCertificates = ListMerge.merge(
                    base: base.tls.clientCertificates,
                    draft: clientCertificates,
                    stored: document.tls.clientCertificates,
                    isEdited: { $0 != $1 || secretsChanged.contains($1.id) }
                )
                if caCertificates != base.tls.caCertificates {
                    document.tls.caCertificates = caCertificates
                }
                if grpc != base.grpc {
                    document.grpc = grpc
                }
                return ProjectSettingsBase(name: document.name, auth: document.auth, tls: document.tls, grpc: document.grpc)
            }
            if let document = app.library.document(projectID) {
                app.lifecycle.markIdentityFiles(of: document)
            }
            try savePassphrasesAndIdentities()
            return merged
        }
        guard let saved else {
            return false
        }
        adopt(saved)
        return true
    }

    /// Entries whose passphrase or Keychain identity the sheet changed: an edit even when the entry itself is unchanged.
    private var entriesWithChangedSecrets: Set<CertificateEntryID> {
        Set(clientCertificates.map(\.id).filter { id in
            passphrase(for: id) != savedPassphrases[id] || keychainIdentities[id] != savedKeychainIdentities[id]
        })
    }

    /// The passphrase as typed; an empty field means none.
    private func passphrase(for id: CertificateEntryID) -> String? {
        passphrases[id].flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Writes only the passphrases and Keychain identities the sheet changed, and forgets those of entries the sheet
    /// removed. An entry added or removed elsewhere is not the sheet's to touch, so one added while the sheet was open
    /// keeps its passphrase. Every entry changed here survives the merge, so none of these writes is for a lost entry.
    private func savePassphrasesAndIdentities() throws {
        var changes: [CertificateEntryID: String?] = [:]
        for entry in clientCertificates {
            let typed = passphrase(for: entry.id)
            if typed != savedPassphrases[entry.id] {
                changes.updateValue(typed, forKey: entry.id)
            }
            if keychainIdentities[entry.id] != savedKeychainIdentities[entry.id] {
                app.workspace.setKeychainIdentity(keychainIdentities[entry.id], for: entry.id)
            }
        }
        for removed in savedEntryIDs.subtracting(clientCertificates.map(\.id)) {
            changes.updateValue(nil, forKey: removed)
            app.workspace.setKeychainIdentity(nil, for: removed)
        }
        if !changes.isEmpty {
            try app.library.updateCertificatePassphrases(changes, in: projectID)
        }
        unreadablePassphrases.subtract(changes.keys)
    }

    /// Shows what Done stored and makes it the next save's base, loading the secrets of entries added elsewhere.
    private func adopt(_ saved: ProjectSettingsBase) {
        let known = Set(clientCertificates.map(\.id))
        let entryIDs = Set(saved.tls.clientCertificates.map(\.id))
        base = saved
        name = saved.name
        auth = saved.auth
        clientCertificates = saved.tls.clientCertificates
        caCertificates = saved.tls.caCertificates
        protoRoots = saved.grpc.protoRoots
        protoEntryFiles = saved.grpc.protoFiles.map { ProtoEntryFile(path: $0) }
        descriptorSets = saved.grpc.descriptorSets
        passphrases = passphrases.filter { entryIDs.contains($0.key) }
        keychainIdentities = keychainIdentities.filter { entryIDs.contains($0.key) }
        unreadablePassphrases.formIntersection(entryIDs)
        certificateStatuses = certificateStatuses.filter { entryIDs.contains($0.key) }
        base.grpc = grpcConfiguration
        loadSecrets(of: saved.tls.clientCertificates.filter { !known.contains($0.id) })
    }

    /// Reads the entries' passphrases and Keychain identity choices into the draft and records them as saved.
    private func loadSecrets(of entries: [ClientCertificateEntry]) {
        for entry in entries {
            do {
                passphrases[entry.id] = try app.library.loadCertificatePassphrase(for: entry.id, in: projectID)
            } catch {
                unreadablePassphrases.insert(entry.id)
            }
            keychainIdentities[entry.id] = app.workspace.keychainIdentity(for: entry.id)
        }
        let entryIDs = Set(clientCertificates.map(\.id))
        savedPassphrases = passphrases.filter { entryIDs.contains($0.key) && !$0.value.isEmpty }
        savedKeychainIdentities = keychainIdentities.filter { entryIDs.contains($0.key) }
        savedEntryIDs = entryIDs
    }
}

/// The settings Done merges, as loaded or last saved. `grpc` is as saving would write it, entry files trimmed and
/// deduplicated, so a file's blank or repeated entries never read as the sheet's edit.
private struct ProjectSettingsBase {
    var name: String
    var auth: HTTPAuth
    var tls: ProjectTLSConfiguration
    var grpc: ProjectGRPCConfiguration
}
