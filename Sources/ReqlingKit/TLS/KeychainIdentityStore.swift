import Foundation
import Security

/// A client identity already installed in the user's keychains.
public struct KeychainIdentityInfo: Hashable, Sendable {
    /// Stable across launches; this Mac's `WorkspaceStateStore` keeps it per certificate entry.
    public let persistentReference: Data
    public let summary: CertificateSummary

    public init(persistentReference: Data, summary: CertificateSummary) {
        self.persistentReference = persistentReference
        self.summary = summary
    }
}

/// Lists and opens keychain identities; a protocol so tests never touch the developer's keychain.
public protocol KeychainIdentityStore: Sendable {
    func availableIdentities() -> [KeychainIdentityInfo]
    func identity(for persistentReference: Data) throws(TLSError) -> TLSClientIdentity
}

public struct SystemKeychainIdentityStore: KeychainIdentityStore {
    public init() {}

    public func availableIdentities() -> [KeychainIdentityInfo] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnRef as String: true,
            kSecReturnPersistentRef as String: true
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else {
            return []
        }
        return items.compactMap { item in
            guard let reference = item[kSecValuePersistentRef as String] as? Data,
                  let identity = Self.identity(from: item[kSecValueRef as String]) else {
                return nil
            }
            var certificate: SecCertificate?
            SecIdentityCopyCertificate(identity, &certificate)
            return certificate.map { KeychainIdentityInfo(persistentReference: reference, summary: CertificateSummary($0)) }
        }
        .sorted { $0.summary.subject.localizedStandardCompare($1.summary.subject) == .orderedAscending }
    }

    public func identity(for persistentReference: Data) throws(TLSError) -> TLSClientIdentity {
        let query: [String: Any] = [
            kSecValuePersistentRef as String: persistentReference,
            kSecReturnRef as String: true
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let identity = Self.identity(from: result) else {
            throw .missingFile("The chosen Keychain identity")
        }
        return TLSClientIdentity(identity: identity)
    }

    private static func identity(from value: Any?) -> SecIdentity? {
        guard let value = value as CFTypeRef?, CFGetTypeID(value) == SecIdentityGetTypeID() else {
            return nil
        }
        return unsafeDowncast(value, to: SecIdentity.self)
    }
}

/// No identities; for tests and previews, which must never read the developer's keychains.
public struct EmptyKeychainIdentityStore: KeychainIdentityStore {
    public init() {}

    public func availableIdentities() -> [KeychainIdentityInfo] {
        []
    }

    public func identity(for persistentReference: Data) throws(TLSError) -> TLSClientIdentity {
        throw .missingFile("The Keychain identity")
    }
}
