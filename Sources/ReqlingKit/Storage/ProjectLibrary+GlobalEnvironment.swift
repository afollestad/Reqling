import Foundation

/// The Global environment: variables every project in the library sees beneath its own Default.
///
/// It lives in one file on this Mac (`Configuration.globalEnvironmentURL`), never in a project folder, so a project
/// shared through git never carries one person's Global; its secret values sit in the Keychain under
/// `SecretAccount.global`.
extension ProjectLibrary {
    /// Applies `body` to a copy of Global, stores new and changed secrets, writes the file, publishes the result, and
    /// only then deletes the secrets the edit removed, in the same order `mutate` uses for a project. Global's ID and
    /// name are fixed, whatever `body` sets. A failed write leaves memory as it was.
    @discardableResult
    public func mutateGlobalEnvironment<Result>(_ body: (inout RequestEnvironment) throws -> Result) throws -> Result {
        reloadGlobalSecretsIfUnread()
        let old = globalEnvironment
        var draft = old
        let result = try body(&draft)
        let new = RequestEnvironment.global(variables: draft.variables)
        guard new != old else {
            return result
        }
        let secrets = SecretChanges(old: Self.secretValues(in: [old]), new: Self.secretValues(in: [new]))
        try updateSecrets(of: .global, storing: secrets.stored, deleting: [])
        let url = configuration.globalEnvironmentURL
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try ProjectJSON.encode(GlobalEnvironmentFile(variables: new.variables)).write(to: url, options: .atomic)
        globalEnvironment = new
        // The file no longer references these; a failure here only leaves unused values in the Keychain.
        try? updateSecrets(of: .global, storing: [:], deleting: secrets.deleted)
        resetCurrentValues(old: [old], new: [new]) { _ in .global }
        return result
    }

    /// Reads Global's secret values again when loading could not, filling the ones still blank and clearing the issue.
    /// `reloadSecretsIfUnread(for:)` calls this before a run and as the Environments sheet opens, and every edit calls it
    /// before applying itself, so a merge starts from the stored values, not blanks.
    public func reloadGlobalSecretsIfUnread() {
        guard globalSecretsUnread, let secrets = try? configuration.secretStore.secrets(for: .global) else {
            return
        }
        var environment = globalEnvironment
        Self.fillBlankSecrets(in: &environment, from: secrets)
        globalSecretsUnread = false
        globalEnvironmentIssue = nil
        if environment != globalEnvironment {
            globalEnvironment = environment
        }
    }

    /// Reads Global's file, then its secret values. A missing file is an empty Global; one that cannot be read or
    /// decoded is set aside first, since the next edit rewrites the file and would otherwise destroy what it held.
    func loadGlobalEnvironment() {
        let url = configuration.globalEnvironmentURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            return
        }
        guard let data = try? Data(contentsOf: url), let file = try? ProjectJSON.decode(GlobalEnvironmentFile.self, from: data) else {
            let backup = UndecodableFileBackup.preserve(url)
            globalEnvironmentIssue = backup.map { "Global's file could not be read, so Reqling set it aside as “\($0.lastPathComponent)”." }
                ?? "Global's file could not be read."
            return
        }
        var environment = RequestEnvironment.global(variables: file.variables)
        if environment.variables.contains(where: \.isSecret) {
            do {
                let secrets = try configuration.secretStore.secrets(for: .global)
                for index in environment.variables.indices where environment.variables[index].isSecret {
                    environment.variables[index].value = secrets[SecretKey.variable(environment.variables[index].id, in: environment.id)] ?? ""
                }
            } catch {
                globalSecretsUnread = true
                globalEnvironmentIssue = Self.unreadableSecretsMessage
            }
        }
        globalEnvironment = environment
    }
}

/// Global's file. It states no ID or name: both are fixed (`RequestEnvironment.globalID`).
struct GlobalEnvironmentFile: Codable, Equatable {
    var variables: [Variable]

    init(variables: [Variable]) {
        self.variables = variables
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        variables = try container.decodeIfPresent([Variable].self, forKey: .variables) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case variables
    }
}
