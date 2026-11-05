import Foundation
import Security
import Synchronization

/// Holds the values Reqling never writes into project files: secret variable values and certificate passphrases.
///
/// Values are grouped per account (a project, or the Global environment) under string keys (`SecretKey`), so one
/// Keychain item serves a whole project and loading it costs at most one Keychain prompt.
public protocol SecretStore: Sendable {
    func secrets(for account: SecretAccount) throws -> [String: String]
    /// Replaces the account's secrets; an empty dictionary removes them.
    func setSecrets(_ secrets: [String: String], for account: SecretAccount) throws
}

extension SecretStore {
    public func secrets(for project: ProjectID) throws -> [String: String] {
        try secrets(for: .project(project))
    }

    public func setSecrets(_ secrets: [String: String], for project: ProjectID) throws {
        try setSecrets(secrets, for: .project(project))
    }
}

/// Whose secrets a Keychain item holds.
///
/// A project's account name is its ID, which is what every item written before Global existed uses, so none needs
/// migrating; `global` can never collide with one, since project IDs are UUIDs.
public enum SecretAccount: Hashable, Sendable, CustomStringConvertible {
    case project(ProjectID)
    /// The Global environment every project shares (`RequestEnvironment.globalID`).
    case global

    public var description: String {
        switch self {
        case .project(let id): id.description
        case .global: "global"
        }
    }

    var keychainLabel: String {
        switch self {
        case .project: "Reqling project secrets"
        case .global: "Reqling global secrets"
        }
    }
}

/// The keys inside an account's secret dictionary.
public enum SecretKey {
    static let variablePrefix = "variable."

    public static func variable(_ id: VariableID, in environment: EnvironmentID) -> String {
        "\(variablePrefix)\(environment).\(id)"
    }

    public static func certificatePassphrase(_ id: CertificateEntryID) -> String {
        "certificate.\(id).passphrase"
    }

    static func isVariable(_ key: String) -> Bool {
        key.hasPrefix(variablePrefix)
    }
}

/// Stores each account's secrets as one generic-password Keychain item, cached in memory after the first read.
public final class KeychainSecretStore: SecretStore {
    private let service: String
    private let cache = Mutex<[SecretAccount: [String: String]]>([:])

    /// `service` is scoped by bundle identifier, so the dev build never prompts for, or overwrites, the release
    /// build's items.
    public init(service: String) {
        self.service = service
    }

    public func secrets(for account: SecretAccount) throws -> [String: String] {
        if let cached = cache.withLock({ $0[account] }) {
            return cached
        }
        var query = baseQuery(for: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        let secrets: [String: String]
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else {
                throw SecretStoreError.unexpectedData
            }
            secrets = try JSONDecoder().decode([String: String].self, from: data)
        case errSecItemNotFound:
            secrets = [:]
        default:
            throw SecretStoreError.keychain(status)
        }
        cache.withLock { $0[account] = secrets }
        return secrets
    }

    public func setSecrets(_ secrets: [String: String], for account: SecretAccount) throws {
        if secrets.isEmpty {
            let status = SecItemDelete(baseQuery(for: account) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw SecretStoreError.keychain(status)
            }
        } else {
            let data = try JSONEncoder().encode(secrets)
            let status = SecItemUpdate(baseQuery(for: account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            if status == errSecItemNotFound {
                var item = baseQuery(for: account)
                item[kSecValueData as String] = data
                item[kSecAttrLabel as String] = account.keychainLabel
                let addStatus = SecItemAdd(item as CFDictionary, nil)
                guard addStatus == errSecSuccess else {
                    throw SecretStoreError.keychain(addStatus)
                }
            } else if status != errSecSuccess {
                throw SecretStoreError.keychain(status)
            }
        }
        cache.withLock { $0[account] = secrets }
    }

    private func baseQuery(for account: SecretAccount) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account.description
        ]
    }
}

/// An in-memory `SecretStore` for tests and previews.
public final class InMemorySecretStore: SecretStore {
    private let storage = Mutex<[SecretAccount: [String: String]]>([:])
    private let readFailure = Mutex(false)

    public init() {}

    /// While set, reads throw as a Keychain does when its prompt is denied, so callers' handling of that can be tested.
    public var isFailingReads: Bool {
        get { readFailure.withLock { $0 } }
        set { readFailure.withLock { $0 = newValue } }
    }

    public func secrets(for account: SecretAccount) throws -> [String: String] {
        if isFailingReads {
            throw SecretStoreError.keychain(errSecAuthFailed)
        }
        return storage.withLock { $0[account] ?? [:] }
    }

    public func setSecrets(_ secrets: [String: String], for account: SecretAccount) throws {
        storage.withLock { $0[account] = secrets.isEmpty ? nil : secrets }
    }
}

public enum SecretStoreError: Error, LocalizedError {
    case keychain(OSStatus)
    case unexpectedData

    public var errorDescription: String? {
        switch self {
        case .keychain(let status) where [errSecAuthFailed, errSecInteractionNotAllowed, errSecUserCanceled].contains(status):
            // macOS words these as a wrong password, which they rarely are.
            if RunningCodeSignature.hasChangedOnDisk {
                return "Reqling changed on disk after it opened, so macOS won't let it use the Keychain. Quit and reopen Reqling."
            }
            return "macOS didn't allow Reqling to use the Keychain. Try again, and choose Allow if macOS asks."
        case .keychain(let status):
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
            return "The Keychain refused the request: \(message)"
        case .unexpectedData:
            return "The Keychain returned data Reqling could not read."
        }
    }
}
