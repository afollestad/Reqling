import Foundation
import Observation
import ReqlingTemplating

/// Where a current value lives: Global, or one environment of one project.
public enum CurrentValueScope: Hashable, Sendable {
    case global
    case environment(ProjectID, EnvironmentID)

    var account: SecretAccount {
        switch self {
        case .global: .global
        case .environment(let project, _): .project(project)
        }
    }

    var environmentID: EnvironmentID {
        switch self {
        case .global: RequestEnvironment.globalID
        case .environment(_, let environment): environment
        }
    }
}

/// This Mac's current values one run of a project sees: Global's, and each of the project's environments'.
public struct CurrentValueSnapshot: Hashable, Sendable {
    public var global: [String: CurrentVariable]
    public var environments: [EnvironmentID: [String: CurrentVariable]]

    public init(global: [String: CurrentVariable] = [:], environments: [EnvironmentID: [String: CurrentVariable]] = [:]) {
        self.global = global
        self.environments = environments
    }

    public static let empty = CurrentValueSnapshot()

    public func values(for environment: EnvironmentID) -> [String: CurrentVariable] {
        environments[environment] ?? [:]
    }
}

/// Values scripts set on this Mac, which override an environment's saved values key by key and never reach a project
/// folder, so running requests never shows up in `git status`.
///
/// Plain values and secret markers live in one file (`current-values.json`, beside `workspace.json`, which is rewritten
/// on every selection change and so would rewrite a large stashed value with it). A secret value lives in the account's
/// existing Keychain item under `SecretKey.currentValue`, so it costs no new item or prompt. A secret the Keychain
/// can't read is left out, so a run falls back to the saved value; one it can't store is kept for the session.
@MainActor
@Observable
public final class CurrentValueStore {
    /// Bumps with every change, so views memoized on what scripts set can key on it.
    public private(set) var revision = 0
    private var file: CurrentValuesFile

    @ObservationIgnored private let url: URL
    @ObservationIgnored private let secretStore: any SecretStore
    /// Secret values the Keychain refused to store, kept so this session's runs still see them.
    @ObservationIgnored private var unsavedSecrets: [SecretAccount: [String: String]] = [:]
    /// Ignored by observation because reads set them, and a view's body reads values: publishing from there is a
    /// change during a view update. `issue` reads `revision`, so writes still refresh whoever shows it.
    @ObservationIgnored private var readFailed = false
    @ObservationIgnored private var writeFailed = false
    /// Called after each change this Mac makes (`ProjectLibrary.changeObserver`), never after `applySynced`.
    @ObservationIgnored var onChange: (() -> Void)?
    /// Whether the file couldn't be read at launch and was set aside, so this store started empty. Sync then treats
    /// current values as unknown rather than as all dropped.
    @ObservationIgnored private(set) var wasSetAside = false

    static let unreadableMessage = "Current values that scripts set as secret could not be read from the Keychain."
    static let unwritableMessage = "Current values that scripts set as secret could not be stored in the Keychain, "
        + "so they last until Reqling quits."

    public init(url: URL, secretStore: any SecretStore) {
        self.url = url
        self.secretStore = secretStore
        file = CurrentValuesFile()
        if let data = try? Data(contentsOf: url) {
            if let decoded = try? ProjectJSON.decode(CurrentValuesFile.self, from: data) {
                file = decoded
            } else {
                // The next change rewrites the file; keep what it held for repair.
                UndecodableFileBackup.preserve(url)
                wasSetAside = true
            }
        }
    }

    /// Why a secret current value couldn't be read or stored, if one couldn't.
    public var issue: String? {
        _ = revision
        if writeFailed {
            return Self.unwritableMessage
        }
        return readFailed ? Self.unreadableMessage : nil
    }

    /// The current values in one scope, markers included, with secret values from the Keychain.
    public func values(in scope: CurrentValueScope) -> [String: CurrentVariable] {
        let stored = file.values(in: scope)
        guard !stored.isEmpty else {
            return [:]
        }
        let secrets = stored.values.contains(.secret) ? secretValues(for: scope.account) : [:]
        var values: [String: CurrentVariable] = [:]
        for (key, value) in stored {
            switch value {
            case .plain(let text):
                values[key] = .value(TemplateVariable(value: text))
            case .unset:
                values[key] = .unset
            case .secret:
                if let secret = secrets[SecretKey.currentValue(key, in: scope.environmentID)] {
                    values[key] = .value(TemplateVariable(value: secret, isSecret: true))
                }
            }
        }
        return values
    }

    /// What a run of `project` sees: Global's current values and those of each of its environments.
    public func snapshot(for project: ProjectID) -> CurrentValueSnapshot {
        var snapshot = CurrentValueSnapshot(global: values(in: .global))
        for environment in file.environments(of: project) {
            snapshot.environments[environment] = values(in: .environment(project, environment))
        }
        return snapshot
    }

    /// Whether any current value or marker is stored for `project`'s environments or Global.
    public func hasValues(for project: ProjectID) -> Bool {
        !file.global.isEmpty || !file.environments(of: project).isEmpty
    }

    /// Stores what a script phase set, in one file write and at most two Keychain writes: a value, a marker, or `nil` to
    /// drop the key. New secret values reach the Keychain before their markers reach the file, and replaced ones leave
    /// it only after, so a marker never points at a value a crash left unwritten.
    func apply(_ changes: [String: CurrentVariable?], in scope: CurrentValueScope) {
        guard !changes.isEmpty else {
            return
        }
        let existing = file.values(in: scope)
        var stored: [String: String] = [:]
        var deleted: Set<String> = []
        var updated = file
        for (key, change) in changes {
            let secretKey = SecretKey.currentValue(key, in: scope.environmentID)
            let newValue: StoredCurrentValue?
            switch change {
            case .value(let variable)? where variable.isSecret:
                stored[secretKey] = variable.value
                newValue = .secret
            case .value(let variable)?:
                newValue = .plain(variable.value)
            case .unset?:
                newValue = .unset
            case nil:
                newValue = nil
            }
            if existing[key] == .secret, newValue != .secret {
                deleted.insert(secretKey)
            }
            updated.set(newValue, for: key, in: scope)
        }
        updateSecrets(scope.account, storing: stored, deleting: [])
        save(updated)
        updateSecrets(scope.account, storing: [:], deleting: deleted)
    }

    /// Drops the current values for `keys` in `scope`, or all of them when `keys` is `nil`: Reset in the Environments
    /// sheet, and every edit of a saved value (`ProjectLibrary.mutate`), so the edit takes effect.
    public func reset(_ keys: Set<String>? = nil, in scope: CurrentValueScope) {
        let present = file.values(in: scope)
        let dropped = keys.map { $0.intersection(present.keys) } ?? Set(present.keys)
        guard !dropped.isEmpty else {
            return
        }
        apply(Dictionary(uniqueKeysWithValues: dropped.map { ($0, CurrentVariable?.none) }), in: scope)
    }

    // MARK: - Sync

    /// The scopes holding any current value or marker, for sync to encode.
    var storedScopes: [CurrentValueScope] {
        var scopes: [CurrentValueScope] = file.global.isEmpty ? [] : [.global]
        for (project, environments) in file.projects {
            guard let projectID = ProjectID(string: project) else {
                continue
            }
            scopes += environments.keys.compactMap(EnvironmentID.init(string:)).map { .environment(projectID, $0) }
        }
        return scopes
    }

    /// One scope's values and markers as stored, secret values not included.
    func storedValues(in scope: CurrentValueScope) -> [String: StoredCurrentValue] {
        file.values(in: scope)
    }

    /// Replaces one scope's values with what another Mac set, in `apply`'s order, without calling `onChange`. A secret
    /// value never comes back as plain text for the same key, whichever Mac wrote last; a marker whose value didn't come
    /// along keeps the value this Mac holds.
    func applySynced(_ values: [String: StoredCurrentValue], secrets: [String: String], in scope: CurrentValueScope) {
        let existing = file.values(in: scope)
        var changes: [String: CurrentVariable?] = [:]
        for key in Set(existing.keys).union(values.keys) {
            switch values[key] {
            case .plain(let text)? where existing[key] == .secret:
                changes[key] = .value(TemplateVariable(value: text, isSecret: true))
            case .plain(let text)?:
                changes[key] = .value(TemplateVariable(value: text))
            case .secret?:
                if let secret = secrets[key] {
                    changes[key] = .value(TemplateVariable(value: secret, isSecret: true))
                } else if existing[key] != .secret {
                    // A marker without its value would point at nothing; leave the key as it is here.
                    continue
                }
            case .unset?:
                changes[key] = .unset
            case nil:
                changes[key] = .some(nil)
            }
        }
        let notified = onChange
        onChange = nil
        apply(changes, in: scope)
        onChange = notified
    }

    /// Drops every current value of a deleted project. Its Keychain item goes with the project's secrets.
    func forget(_ project: ProjectID) {
        var updated = file
        updated.projects[project.description] = nil
        unsavedSecrets[.project(project)] = nil
        save(updated)
    }

    private func secretValues(for account: SecretAccount) -> [String: String] {
        let unsaved = unsavedSecrets[account] ?? [:]
        do {
            let secrets = try secretStore.secrets(for: account).merging(unsaved) { _, unsaved in unsaved }
            readFailed = false
            return secrets
        } catch {
            readFailed = true
            return unsaved
        }
    }

    /// Stores and deletes secret values, keeping any the Keychain refused for the session.
    private func updateSecrets(_ account: SecretAccount, storing values: [String: String], deleting keys: Set<String>) {
        guard !values.isEmpty || !keys.isEmpty else {
            return
        }
        var unsaved = unsavedSecrets[account] ?? [:]
        for key in keys {
            unsaved[key] = nil
        }
        do {
            try secretStore.update(account, storing: values, deleting: keys)
            for key in values.keys {
                unsaved[key] = nil
            }
        } catch {
            unsaved.merge(values) { _, new in new }
            writeFailed = true
        }
        unsavedSecrets[account] = unsaved.isEmpty ? nil : unsaved
    }

    private func save(_ updated: CurrentValuesFile) {
        guard updated != file else {
            return
        }
        file = updated
        revision += 1
        onChange?()
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try ProjectJSON.encode(updated).write(to: url, options: .atomic)
        } catch {
            // Like workspace state, losing a write costs values a script can set again, never project data.
        }
    }
}

/// `current-values.json`: Global's values, then each project's by environment, keyed by ID strings.
struct CurrentValuesFile: Codable, Equatable {
    var global: [String: StoredCurrentValue] = [:]
    var projects: [String: [String: [String: StoredCurrentValue]]] = [:]

    init() {}

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        global = try container.decodeIfPresent([String: StoredCurrentValue].self, forKey: .global) ?? [:]
        projects = try container.decodeIfPresent([String: [String: [String: StoredCurrentValue]]].self, forKey: .projects) ?? [:]
    }

    private enum CodingKeys: String, CodingKey {
        case global
        case projects
    }

    func values(in scope: CurrentValueScope) -> [String: StoredCurrentValue] {
        switch scope {
        case .global: global
        case .environment(let project, let environment): projects[project.description]?[environment.description] ?? [:]
        }
    }

    func environments(of project: ProjectID) -> [EnvironmentID] {
        (projects[project.description] ?? [:]).keys.compactMap(EnvironmentID.init(string:))
    }

    /// Sets or, with `nil`, drops one key, pruning emptied environments and projects so the file never grows stale.
    mutating func set(_ value: StoredCurrentValue?, for key: String, in scope: CurrentValueScope) {
        switch scope {
        case .global:
            global[key] = value
        case .environment(let project, let environment):
            var environments = projects[project.description] ?? [:]
            var values = environments[environment.description] ?? [:]
            values[key] = value
            environments[environment.description] = values.isEmpty ? nil : values
            projects[project.description] = environments.isEmpty ? nil : environments
        }
    }
}

/// One stored current value: plain text, a marker that its value is in the Keychain, or a marker that hides the saved
/// value. Coded as `{"value": …}`, `{"secret": true}`, or `{"unset": true}`.
enum StoredCurrentValue: Codable, Equatable {
    case plain(String)
    case secret
    case unset

    private enum CodingKeys: String, CodingKey {
        case value
        case secret
        case unset
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let value = try container.decodeIfPresent(String.self, forKey: .value) {
            self = .plain(value)
        } else if try container.decodeIfPresent(Bool.self, forKey: .secret) == true {
            self = .secret
        } else if try container.decodeIfPresent(Bool.self, forKey: .unset) == true {
            self = .unset
        } else {
            let context = DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "A current value needs `value`, `secret`, or `unset`."
            )
            throw DecodingError.dataCorrupted(context)
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .plain(let value): try container.encode(value, forKey: .value)
        case .secret: try container.encode(true, forKey: .secret)
        case .unset: try container.encode(true, forKey: .unset)
        }
    }
}
