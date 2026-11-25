import CryptoKit
import Foundation

/// Which account sync is for: the digest key its bases are keyed with, and the account this Mac last synced with.
extension LibrarySync {
    /// The digest key, created on first use, kept in its own Keychain item (`SecretAccount.sync`).
    func loadKey() -> SymmetricKey? {
        guard let stored = try? secretStore.secrets(for: .sync) else {
            return nil
        }
        if let text = stored["key"], let data = Data(base64Encoded: text) {
            return SymmetricKey(data: data)
        }
        let key = SyncDigester.makeKey()
        let data = key.withUnsafeBytes { Data($0) }
        guard (try? secretStore.update(.sync, storing: ["key": data.base64EncodedString()], deleting: [])) != nil else {
            return nil
        }
        return key
    }

    var accountMarker: URL {
        directory.appendingPathComponent("account")
    }

    func lastAccountFolder() -> String? {
        (try? String(contentsOf: accountMarker, encoding: .utf8)).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    func rememberAccountFolder(_ folder: String) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? Data(folder.utf8).write(to: accountMarker, options: .atomic)
    }
}
