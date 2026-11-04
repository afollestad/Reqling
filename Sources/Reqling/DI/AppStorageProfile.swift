import Foundation

/// Where the app keeps everything it writes. Every writable path derives from this profile, so the
/// test suites and the dev build never touch the release build's data.
///
/// `@unchecked Sendable` because `UserDefaults` is documented thread-safe and the profile is
/// immutable after bootstrap.
struct AppStorageProfile: @unchecked Sendable {
    let applicationSupportDirectory: URL
    let settingsDefaults: UserDefaults
    let settingsDefaultsSuiteName: String?
    /// Only ephemeral profiles may be wiped; `cleanUp()` refuses everything else.
    let isEphemeral: Bool

    /// Scoped by bundle identifier, so "Reqling Dev" (`com.afollestad.reqling.debug`) keeps its own
    /// Application Support folder and preferences domain beside the release build's.
    static var production: AppStorageProfile {
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "com.afollestad.reqling"
        return AppStorageProfile(
            applicationSupportDirectory: userApplicationSupportDirectory
                .appendingPathComponent(bundleIdentifier, isDirectory: true),
            settingsDefaults: .standard,
            settingsDefaultsSuiteName: nil,
            isEphemeral: false
        )
    }

    /// A unique temporary root and defaults suite per call, so tests can run in parallel without
    /// sharing state. Pair every call with `cleanUp()`.
    static func test(identifier: UUID = UUID(), fileManager: FileManager = .default) -> AppStorageProfile {
        let profileID = "\(ProcessInfo.processInfo.processIdentifier)-\(identifier.uuidString.lowercased())"
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("ReqlingTests", isDirectory: true)
            .appendingPathComponent(profileID, isDirectory: true)
        let suiteName = "com.afollestad.reqling.tests.\(profileID)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fatalError("Failed to create the test UserDefaults suite: \(suiteName)")
        }
        defaults.removePersistentDomain(forName: suiteName)
        return AppStorageProfile(
            applicationSupportDirectory: directory,
            settingsDefaults: defaults,
            settingsDefaultsSuiteName: suiteName,
            isEphemeral: true
        )
    }

    /// Removes an ephemeral profile's directory and defaults suite. A no-op for production storage.
    func cleanUp(fileManager: FileManager = .default) {
        guard isEphemeral, let settingsDefaultsSuiteName else {
            return
        }
        settingsDefaults.removePersistentDomain(forName: settingsDefaultsSuiteName)
        try? fileManager.removeItem(at: applicationSupportDirectory)
    }

    private static var userApplicationSupportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support", isDirectory: true)
    }
}
