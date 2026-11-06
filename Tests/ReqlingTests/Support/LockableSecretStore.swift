import Foundation
import ReqlingKit
import Security

/// Fails every read while `isLocked`, as a locked Keychain or a denied access prompt does; writes pass through.
final class LockableSecretStore: SecretStore, @unchecked Sendable {
    private let wrapped: any SecretStore
    var isLocked = false

    init(wrapping wrapped: any SecretStore = InMemorySecretStore()) {
        self.wrapped = wrapped
    }

    func secrets(for account: SecretAccount) throws -> [String: String] {
        if isLocked {
            throw SecretStoreError.keychain(errSecAuthFailed)
        }
        return try wrapped.secrets(for: account)
    }

    func setSecrets(_ secrets: [String: String], for account: SecretAccount) throws {
        try wrapped.setSecrets(secrets, for: account)
    }
}
