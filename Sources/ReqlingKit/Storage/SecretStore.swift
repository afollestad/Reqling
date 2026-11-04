import Foundation
import Security
import Synchronization

/// Holds the values Reqling never writes into project files: secret variable values and certificate passphrases.
///
/// Values are grouped per project under string keys (`SecretKey`), so one Keychain item serves a whole project and
/// loading it costs at most one Keychain prompt.
public protocol SecretStore: Sendable {
    func secrets(for project: ProjectID) throws -> [String: String]
    /// Replaces the project's secrets; an empty dictionary removes them.
    func setSecrets(_ secrets: [String: String], for project: ProjectID) throws
}

/// The keys inside a project's secret dictionary.
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

/// Stores each project's secrets as one generic-password Keychain item, cached in memory after the first read.
public final class KeychainSecretStore: SecretStore {
    private let service: String
    private let cache = Mutex<[ProjectID: [String: String]]>([:])

    /// `service` is scoped by bundle identifier, so the dev build never prompts for, or overwrites, the release
    /// build's items.
    public init(service: String) {
        self.service = service
    }

    public func secrets(for project: ProjectID) throws -> [String: String] {
        if let cached = cache.withLock({ $0[project] }) {
            return cached
        }
        var query = baseQuery(for: project)
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
        cache.withLock { $0[project] = secrets }
        return secrets
    }

    public func setSecrets(_ secrets: [String: String], for project: ProjectID) throws {
        if secrets.isEmpty {
            let status = SecItemDelete(baseQuery(for: project) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw SecretStoreError.keychain(status)
            }
        } else {
            let data = try JSONEncoder().encode(secrets)
            let status = SecItemUpdate(baseQuery(for: project) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            if status == errSecItemNotFound {
                var item = baseQuery(for: project)
                item[kSecValueData as String] = data
                item[kSecAttrLabel as String] = "Reqling project secrets"
                let addStatus = SecItemAdd(item as CFDictionary, nil)
                guard addStatus == errSecSuccess else {
                    throw SecretStoreError.keychain(addStatus)
                }
            } else if status != errSecSuccess {
                throw SecretStoreError.keychain(status)
            }
        }
        cache.withLock { $0[project] = secrets }
    }

    private func baseQuery(for project: ProjectID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: project.description
        ]
    }
}

/// An in-memory `SecretStore` for tests and previews.
public final class InMemorySecretStore: SecretStore {
    private let storage = Mutex<[ProjectID: [String: String]]>([:])
    private let readFailure = Mutex(false)

    public init() {}

    /// While set, reads throw as a Keychain does when its prompt is denied, so callers' handling of that can be tested.
    public var isFailingReads: Bool {
        get { readFailure.withLock { $0 } }
        set { readFailure.withLock { $0 = newValue } }
    }

    public func secrets(for project: ProjectID) throws -> [String: String] {
        if isFailingReads {
            throw SecretStoreError.keychain(errSecAuthFailed)
        }
        return storage.withLock { $0[project] ?? [:] }
    }

    public func setSecrets(_ secrets: [String: String], for project: ProjectID) throws {
        storage.withLock { $0[project] = secrets.isEmpty ? nil : secrets }
    }
}

public enum SecretStoreError: Error, LocalizedError {
    case keychain(OSStatus)
    case unexpectedData

    public var errorDescription: String? {
        switch self {
        case .keychain(let status):
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
            return "The Keychain refused the request: \(message)"
        case .unexpectedData:
            return "The Keychain returned data Reqling could not read."
        }
    }
}
