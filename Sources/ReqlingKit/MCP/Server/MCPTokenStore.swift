import Foundation
import Security
import Synchronization

/// Where the MCP bearer token lives: the Keychain in the app, memory in tests.
public protocol MCPTokenStore: Sendable {
    func load() throws -> String?
    func save(_ token: String) throws
}

extension MCPTokenStore {
    /// The stored token, or a new one saved now.
    func loadOrCreate() throws -> String {
        if let token = try load(), !token.isEmpty {
            return token
        }
        let token = try MCPBearerToken.make()
        try save(token)
        return token
    }
}

enum MCPBearerToken {
    /// 32 random bytes, base64url without padding, so it is safe in a header and a shell command.
    static func make() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw MCPServerError.listenerFailed("Couldn't generate a token.")
        }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// One generic-password item. `service` is scoped by bundle identifier, so the dev build has its own token.
public final class KeychainMCPTokenStore: MCPTokenStore {
    private let service: String

    public init(service: String) {
        self.service = service
    }

    public func load() throws -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else {
                throw SecretStoreError.unexpectedData
            }
            return String(data: data, encoding: .utf8)
        case errSecItemNotFound:
            return nil
        default:
            throw SecretStoreError.keychain(status)
        }
    }

    public func save(_ token: String) throws {
        let data = Data(token.utf8)
        let status = SecItemUpdate(baseQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = baseQuery
            item[kSecValueData as String] = data
            item[kSecAttrLabel as String] = "Reqling MCP server token"
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else {
                throw SecretStoreError.keychain(added)
            }
        } else if status != errSecSuccess {
            throw SecretStoreError.keychain(status)
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "bearer-token"
        ]
    }
}

public final class InMemoryMCPTokenStore: MCPTokenStore {
    private let token = Mutex<String?>(nil)

    public init(token: String? = nil) {
        self.token.withLock { $0 = token }
    }

    public func load() throws -> String? {
        token.withLock { $0 }
    }

    public func save(_ token: String) throws {
        self.token.withLock { $0 = token }
    }
}
