import Foundation
import Observation

/// The projects Reqling knows about, loaded into memory, and the single path for changing them, plus the Global
/// environment they all share (`ProjectLibrary+GlobalEnvironment.swift`).
///
/// Every edit, from the UI or the MCP server, goes through `mutate`, which saves the folder before publishing the
/// new document. Memory therefore always matches disk after a mutation, which is what lets an external-change reload
/// compare content instead of tracking which writes were Reqling's own.
@MainActor
@Observable
public final class ProjectLibrary {
    public private(set) var projects: [LibraryProject] = []
    /// The variables every project sees beneath its own Default. Set only by `mutateGlobalEnvironment` and its loader.
    public internal(set) var globalEnvironment = RequestEnvironment.global()
    /// Why Global loaded incomplete (its file set aside, or its secret values unreadable), if it did.
    public internal(set) var globalEnvironmentIssue: String?
    /// What scripts set on this Mac over the saved values. Edits of saved values through `mutate` and
    /// `mutateGlobalEnvironment` drop the matching ones (`ProjectLibrary+CurrentValues.swift`).
    @ObservationIgnored public let currentValues: CurrentValueStore

    @ObservationIgnored let configuration: Configuration
    /// Whether Global's secret values still sit blank because loading could not read them; see
    /// `reloadGlobalSecretsIfUnread`.
    @ObservationIgnored var globalSecretsUnread = false
    /// The projects whose secret values still sit blank because loading could not read them; see
    /// `reloadSecretsIfUnread(for:)`.
    @ObservationIgnored var projectsWithUnreadSecrets: Set<ProjectID> = []
    @ObservationIgnored private var indexes: [ProjectID: ProjectDiskIndex] = [:]
    @ObservationIgnored private var monitors: [ProjectID: any ProjectChangeMonitor] = [:]

    public struct Configuration {
        /// The list of known project folders, in display order.
        public var registryURL: URL
        /// Where new projects go when no location is chosen.
        public var defaultProjectsDirectory: URL
        /// The Global environment's file, kept on this Mac rather than in any project.
        public var globalEnvironmentURL: URL
        /// The values scripts set on this Mac (`CurrentValueStore`).
        public var currentValuesURL: URL
        public var secretStore: any SecretStore
        public var trasher: any FileTrashing
        /// `nil` disables watching, as tests do.
        public var monitorFactory: ProjectChangeMonitorFactory?

        public init(
            registryURL: URL,
            defaultProjectsDirectory: URL,
            globalEnvironmentURL: URL,
            currentValuesURL: URL,
            secretStore: any SecretStore,
            trasher: any FileTrashing,
            monitorFactory: ProjectChangeMonitorFactory?
        ) {
            self.registryURL = registryURL
            self.defaultProjectsDirectory = defaultProjectsDirectory
            self.globalEnvironmentURL = globalEnvironmentURL
            self.currentValuesURL = currentValuesURL
            self.secretStore = secretStore
            self.trasher = trasher
            self.monitorFactory = monitorFactory
        }
    }

    public init(configuration: Configuration) {
        self.configuration = configuration
        currentValues = CurrentValueStore(url: configuration.currentValuesURL, secretStore: configuration.secretStore)
        loadRegistry()
        loadGlobalEnvironment()
    }

    // MARK: - Queries

    public func project(_ id: ProjectID) -> LibraryProject? {
        projects.first { $0.id == id }
    }

    public func document(_ id: ProjectID) -> ProjectDocument? {
        project(id)?.document
    }

    // MARK: - Library membership

    /// Creates a project folder named after `name` inside `directory` (default: the library's projects folder).
    @discardableResult
    public func createProject(named name: String, in directory: URL? = nil) throws -> ProjectID {
        let parent = directory ?? configuration.defaultProjectsDirectory
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let folder = Self.availableFolderURL(for: name, in: parent)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let document = ProjectDocument(name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Untitled" : name)
        let index = try ProjectWriter(root: folder, trasher: configuration.trasher).save(document, previous: ProjectDiskIndex())
        indexes[document.id] = index
        projects.append(LibraryProject(id: document.id, url: folder, status: .loaded(document)))
        startMonitoring(document.id, at: folder)
        saveRegistry()
        return document.id
    }

    /// Adds an existing project folder, such as one checked into an API's repository.
    @discardableResult
    public func addProjectFolder(_ url: URL) throws -> ProjectID {
        let result = try ProjectReader(root: url).read()
        guard project(result.document.id) == nil else {
            throw ProjectStorageError.alreadyInLibrary
        }
        projects.append(makeLoadedProject(result, url: url))
        indexes[result.document.id] = result.index
        startMonitoring(result.document.id, at: url)
        saveRegistry()
        return result.document.id
    }

    /// Forgets a project without touching its folder or secrets, so adding the folder back restores everything.
    public func removeProject(_ id: ProjectID) {
        monitors.removeValue(forKey: id)?.stop()
        indexes[id] = nil
        projects.removeAll { $0.id == id }
        saveRegistry()
    }

    /// Moves the project folder to the Trash, removes it from the library, and deletes its secrets and current values.
    public func deleteProject(_ id: ProjectID) throws {
        guard let project = project(id) else {
            throw ProjectStorageError.projectNotFound
        }
        monitors.removeValue(forKey: id)?.stop()
        if FileManager.default.fileExists(atPath: project.url.path) {
            try configuration.trasher.trash(project.url)
        }
        try? configuration.secretStore.setSecrets([:], for: id)
        currentValues.forget(id)
        removeProject(id)
    }

    public func moveProject(_ id: ProjectID, to index: Int) {
        guard let from = projects.firstIndex(where: { $0.id == id }) else {
            return
        }
        let project = projects.remove(at: from)
        projects.insert(project, at: min(max(index, 0), projects.count))
        saveRegistry()
    }

    // MARK: - Editing

    /// Applies `body` to a copy of the project, stores new and changed secrets, saves the folder, publishes the result,
    /// and only then deletes the secrets the edit removed. When nothing changed, nothing is written. A failed save
    /// reloads from disk so memory never claims a state the folder does not have, and leaves every secret its files
    /// still reference in place. Secret values loading could not read are read again first, so an edit starts from the
    /// stored values rather than blanks.
    @discardableResult
    public func mutate<Result>(_ id: ProjectID, _ body: (inout ProjectDocument) throws -> Result) throws -> Result {
        reloadProjectSecretsIfUnread(id)
        guard let position = projects.firstIndex(where: { $0.id == id }),
              let old = projects[position].document,
              let index = indexes[id] else {
            throw ProjectStorageError.projectNotFound
        }
        guard !projects[position].isReadOnly else {
            throw ProjectStorageError.readOnly
        }
        var new = old
        let result = try body(&new)
        guard new != old else {
            return result
        }
        let secrets = SecretChanges(old: Self.secretValues(in: old), new: Self.secretValues(in: new))
        try updateSecrets(of: .project(id), storing: secrets.stored, deleting: [])
        do {
            indexes[id] = try ProjectWriter(root: projects[position].url, trasher: configuration.trasher).save(new, previous: index)
        } catch {
            reload(id)
            throw error
        }
        projects[position].status = .loaded(new)
        // The folder no longer references these; a failure here only leaves unused values in the Keychain.
        try? updateSecrets(of: .project(id), storing: [:], deleting: secrets.deleted)
        resetCurrentValues(old: old.allEnvironments, new: new.allEnvironments) { .environment(id, $0) }
        return result
    }

    /// Re-reads a project from disk, publishing only a real change.
    public func reload(_ id: ProjectID) {
        guard let position = projects.firstIndex(where: { $0.id == id }) else {
            return
        }
        let url = projects[position].url
        do {
            let result = try ProjectReader(root: url).read(previous: indexes[id])
            guard result.document.id == id else {
                // Secrets and workspace state are keyed by the ID; silently adopting a new one would orphan them.
                indexes[id] = nil
                projects[position].status = .unavailable("The project's ID changed on disk. Remove it from Reqling and add the folder again.")
                return
            }
            let reloaded = makeLoadedProject(result, url: url)
            indexes[id] = result.index
            if reloaded != projects[position] {
                projects[position] = reloaded
            }
        } catch {
            indexes[id] = nil
            projects[position].status = .unavailable(error.localizedDescription)
        }
    }

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

    // MARK: - Loading

    private func loadRegistry() {
        var entries: [RegistryEntry] = []
        if let data = try? Data(contentsOf: configuration.registryURL) {
            if let registry = try? ProjectJSON.decode(Registry.self, from: data) {
                entries = registry.projects
            } else {
                // The next membership change rewrites the registry; keep the list it held for repair.
                UndecodableFileBackup.preserve(configuration.registryURL)
            }
        }
        var adoptedNewIDs = false
        for entry in entries where !projects.contains(where: { $0.id == entry.id }) {
            let url = URL(fileURLWithPath: entry.path, isDirectory: true)
            do {
                let result = try ProjectReader(root: url).read()
                let id = result.document.id
                guard !projects.contains(where: { $0.id == id }) else {
                    continue
                }
                adoptedNewIDs = adoptedNewIDs || id != entry.id
                projects.append(makeLoadedProject(result, url: url))
                indexes[id] = result.index
                startMonitoring(id, at: url)
            } catch {
                projects.append(LibraryProject(id: entry.id, url: url, status: .unavailable(error.localizedDescription)))
            }
        }
        if adoptedNewIDs {
            saveRegistry()
        }
    }

    static let unreadableSecretsMessage = "Secret values could not be read from the Keychain."

    /// Fills the project's secret values still blank and drops its Keychain issue, once the Keychain answers. Here
    /// rather than beside `reloadSecretsIfUnread(for:)`, since only this file may write `projects`.
    func reloadProjectSecretsIfUnread(_ id: ProjectID) {
        guard projectsWithUnreadSecrets.contains(id) else {
            return
        }
        guard let position = projects.firstIndex(where: { $0.id == id }), var document = projects[position].document else {
            projectsWithUnreadSecrets.remove(id)
            return
        }
        guard let secrets = try? configuration.secretStore.secrets(for: id) else {
            return
        }
        for environment in document.allEnvironments {
            document.updateEnvironment(environment.id) { Self.fillBlankSecrets(in: &$0, from: secrets) }
        }
        projectsWithUnreadSecrets.remove(id)
        var project = projects[position]
        project.status = .loaded(document)
        project.issues.removeAll { $0.path.isEmpty && $0.message == Self.unreadableSecretsMessage }
        if project != projects[position] {
            projects[position] = project
        }
    }

    /// Builds a loaded project, filling secret values from the store. A loaded project's library ID is always its
    /// document ID, which is also what its secrets and workspace state are keyed by.
    private func makeLoadedProject(_ result: ProjectReader.Result, url: URL) -> LibraryProject {
        var document = result.document
        var issues = result.issues
        let hasSecrets = document.allEnvironments.contains { $0.variables.contains(where: \.isSecret) }
        projectsWithUnreadSecrets.remove(document.id)
        if hasSecrets {
            do {
                let secrets = try configuration.secretStore.secrets(for: document.id)
                Self.fillSecretValues(in: &document, from: secrets)
            } catch {
                projectsWithUnreadSecrets.insert(document.id)
                issues.append(ProjectLoadIssue(path: "", message: Self.unreadableSecretsMessage))
            }
        }
        return LibraryProject(
            id: document.id,
            url: url,
            status: .loaded(document),
            issues: issues,
            isReadOnly: result.isReadOnly
        )
    }

    private static func fillSecretValues(in document: inout ProjectDocument, from secrets: [String: String]) {
        for environment in document.allEnvironments {
            document.updateEnvironment(environment.id) { environment in
                for index in environment.variables.indices where environment.variables[index].isSecret {
                    let key = SecretKey.variable(environment.variables[index].id, in: environment.id)
                    environment.variables[index].value = secrets[key] ?? ""
                }
            }
        }
    }

    func updateSecrets(of account: SecretAccount, storing values: [String: String], deleting keys: Set<String>) throws {
        try configuration.secretStore.update(account, storing: values, deleting: keys)
    }

    private static func secretValues(in document: ProjectDocument) -> [String: String] {
        secretValues(in: document.allEnvironments)
    }

    /// Every secret variable's value, keyed by `SecretKey`.
    static func secretValues(in environments: [RequestEnvironment]) -> [String: String] {
        var values: [String: String] = [:]
        for environment in environments {
            for variable in environment.variables where variable.isSecret {
                values[SecretKey.variable(variable.id, in: environment.id)] = variable.value
            }
        }
        return values
    }

    private func startMonitoring(_ id: ProjectID, at url: URL) {
        guard let factory = configuration.monitorFactory else {
            return
        }
        monitors[id]?.stop()
        monitors[id] = factory(url) { [weak self] in
            self?.reload(id)
        }
    }

    private func saveRegistry() {
        let registry = Registry(projects: projects.map { RegistryEntry(id: $0.id, path: $0.url.path) })
        do {
            try FileManager.default.createDirectory(at: configuration.registryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try ProjectJSON.encode(registry).write(to: configuration.registryURL, options: .atomic)
        } catch {
            // The registry only lists folders; every project's data is already safe in its own folder.
        }
    }

    /// `<name>.reqling`, or `<name> 2.reqling` and so on when taken.
    private static func availableFolderURL(for name: String, in parent: URL) -> URL {
        let sanitized = name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let base = sanitized.isEmpty || sanitized.hasPrefix(".") ? "Untitled" : sanitized
        var candidate = parent.appendingPathComponent("\(base).reqling", isDirectory: true)
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = parent.appendingPathComponent("\(base) \(suffix).reqling", isDirectory: true)
            suffix += 1
        }
        return candidate
    }
}

/// A project as the library sees it: where it lives, and its document or why it could not be loaded.
public struct LibraryProject: Identifiable, Hashable, Sendable {
    public let id: ProjectID
    public var url: URL
    public var status: Status
    public var issues: [ProjectLoadIssue]
    public var isReadOnly: Bool

    public enum Status: Hashable, Sendable {
        case loaded(ProjectDocument)
        case unavailable(String)
    }

    public init(id: ProjectID, url: URL, status: Status, issues: [ProjectLoadIssue] = [], isReadOnly: Bool = false) {
        self.id = id
        self.url = url
        self.status = status
        self.issues = issues
        self.isReadOnly = isReadOnly
    }

    public var document: ProjectDocument? {
        if case .loaded(let document) = status {
            return document
        }
        return nil
    }

    public var name: String {
        document?.name ?? url.deletingPathExtension().lastPathComponent
    }
}

/// How an edit changes a project's or Global's secret variable values, keyed by `SecretKey`.
struct SecretChanges {
    /// New and changed values, stored before the folder is saved.
    let stored: [String: String]
    /// Keys the edit removed, deleted only after the folder no longer references them.
    let deleted: Set<String>

    init(old: [String: String], new: [String: String]) {
        stored = new.filter { old[$0.key] != $0.value }
        deleted = Set(old.keys).subtracting(new.keys)
    }
}

private struct Registry: Codable {
    var projects: [RegistryEntry]
}

private struct RegistryEntry: Codable {
    var id: ProjectID
    var path: String
}
