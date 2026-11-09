import Foundation

/// Client certificate passphrases, kept in the project's Keychain item beside its secret variables
/// (`SecretKey.certificatePassphrase`), never in its files.
extension ProjectLibrary {
    /// The passphrase for sending a request: a Keychain that cannot be read behaves like no passphrase, and opening the
    /// certificate then reports what is missing. Editors use `loadCertificatePassphrase`, which tells the two apart.
    public func certificatePassphrase(for entry: CertificateEntryID, in project: ProjectID) -> String? {
        try? loadCertificatePassphrase(for: entry, in: project)
    }

    /// The stored passphrase, or `nil` when none is stored. Throws when the Keychain cannot be read, so an editor never
    /// shows a failed read as an empty passphrase and then saves that blank over the stored one.
    public func loadCertificatePassphrase(for entry: CertificateEntryID, in project: ProjectID) throws -> String? {
        try configuration.secretStore.secrets(for: project)[SecretKey.certificatePassphrase(entry)]
    }

    public func setCertificatePassphrase(_ passphrase: String?, for entry: CertificateEntryID, in project: ProjectID) throws {
        try updateCertificatePassphrases([entry: passphrase], in: project)
    }

    /// Applies passphrase changes in one Keychain write; a `nil` or empty value deletes. Entries not listed keep what is
    /// stored, so callers pass only what the user changed or removed.
    public func updateCertificatePassphrases(_ changes: [CertificateEntryID: String?], in project: ProjectID) throws {
        var stored: [String: String] = [:]
        var deleted: Set<String> = []
        for (entry, passphrase) in changes {
            let key = SecretKey.certificatePassphrase(entry)
            if let passphrase, !passphrase.isEmpty {
                stored[key] = passphrase
            } else {
                deleted.insert(key)
            }
        }
        try updateSecrets(of: .project(project), storing: stored, deleting: deleted)
    }
}
