import Foundation

/// Where `SettingsStore` persists: `UserDefaults.standard` for the app, `MemoryPreferences` for tests and screenshot
/// launches. Only the calls Reqling makes, so memory can stand in for a `UserDefaults` suite, which leaves an empty plist
/// in `~/Library/Preferences` even after its domain is removed.
public protocol Preferences: AnyObject {
    func data(forKey defaultName: String) -> Data?
    /// Stores `value`, or removes the key for `nil`.
    func set(_ value: Any?, forKey defaultName: String)
}

extension UserDefaults: Preferences {}

/// Preferences that last only as long as the process. Locked, since `UserDefaults`, which it stands in for, is
/// thread-safe.
public final class MemoryPreferences: Preferences, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Any] = [:]

    public init() {}

    public func data(forKey defaultName: String) -> Data? {
        lock.withLock { values[defaultName] as? Data }
    }

    public func set(_ value: Any?, forKey defaultName: String) {
        lock.withLock { values[defaultName] = value }
    }
}
