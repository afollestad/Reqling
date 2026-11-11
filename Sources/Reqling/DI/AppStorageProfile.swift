import Foundation
import ReqlingKit

/// Where the app keeps everything it writes. Every writable path derives from this profile, so the
/// test suites and the dev build never touch the release build's data.
///
/// `@unchecked Sendable` because `UserDefaults` is documented thread-safe, `MemoryPreferences` locks,
/// and the profile is immutable after bootstrap.
struct AppStorageProfile: @unchecked Sendable {
    let applicationSupportDirectory: URL
    /// Where `SettingsStore` persists.
    let preferences: any Preferences
    /// Only ephemeral profiles may be wiped; `cleanUp()` refuses everything else.
    let isEphemeral: Bool

    /// Scoped by bundle identifier, so "Reqling Dev" (`com.afollestad.reqling.debug`) keeps its own
    /// Application Support folder and preferences domain beside the release build's.
    static var production: AppStorageProfile {
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "com.afollestad.reqling"
        return AppStorageProfile(
            applicationSupportDirectory: userApplicationSupportDirectory
                .appendingPathComponent(bundleIdentifier, isDirectory: true),
            preferences: UserDefaults.standard,
            isEphemeral: false
        )
    }

    /// A unique temporary root and preferences in memory per call, so tests can run in parallel
    /// without sharing state. Pair every call with `cleanUp()`.
    static func test(identifier: UUID = UUID(), fileManager: FileManager = .default) -> AppStorageProfile {
        let profileID = "\(ProcessInfo.processInfo.processIdentifier)-\(identifier.uuidString.lowercased())"
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("ReqlingTests", isDirectory: true)
            .appendingPathComponent(profileID, isDirectory: true)
        return AppStorageProfile(applicationSupportDirectory: directory, preferences: MemoryPreferences(), isEphemeral: true)
    }

    /// Removes an ephemeral profile's directory; its preferences live only in memory. A no-op for production storage.
    func cleanUp(fileManager: FileManager = .default) {
        guard isEphemeral else {
            return
        }
        try? fileManager.removeItem(at: applicationSupportDirectory)
    }

    /// The list of known project folders.
    var registryURL: URL {
        applicationSupportDirectory.appendingPathComponent("library.json")
    }

    /// Where new projects go when no location is chosen.
    var projectsDirectory: URL {
        applicationSupportDirectory.appendingPathComponent("Projects", isDirectory: true)
    }

    var workspaceStateURL: URL {
        applicationSupportDirectory.appendingPathComponent("workspace.json")
    }

    /// The Global environment every project shares; its secret values live in the Keychain.
    var globalEnvironmentURL: URL {
        applicationSupportDirectory.appendingPathComponent("global-environment.json")
    }

    /// What iCloud sync keeps on this Mac (`SyncBaseStore`): digests of what it last synced, never secrets, and no
    /// content but the copy of what was here before an account first synced (`Backup/`).
    var syncDirectory: URL {
        applicationSupportDirectory.appendingPathComponent("Sync", isDirectory: true)
    }

    /// The values scripts set on this Mac (`CurrentValueStore`); secret ones live in the Keychain.
    var currentValuesURL: URL {
        applicationSupportDirectory.appendingPathComponent("current-values.json")
    }

    /// Every request's past runs (`RunHistoryStore`).
    var historyDirectory: URL {
        applicationSupportDirectory.appendingPathComponent("History", isDirectory: true)
    }

    /// Tools Reqling installs itself, such as `protoc` under `protoc/<version>`.
    var toolsDirectory: URL {
        applicationSupportDirectory.appendingPathComponent("Tools", isDirectory: true)
    }

    /// Compiled descriptor sets kept across launches, so reopening a project does not rerun protoc on unchanged protos.
    var protocCacheDirectory: URL {
        applicationSupportDirectory.appendingPathComponent("ProtocCache", isDirectory: true)
    }

    /// Introspected GraphQL schemas kept across launches (`GraphQLSchemaStore`), per project and endpoint.
    var graphQLSchemasDirectory: URL {
        applicationSupportDirectory.appendingPathComponent("GraphQLSchemas", isDirectory: true)
    }

    /// Staged updates, their metadata, and the install helper's scripts and logs. The dev build's Application Support
    /// folder is its own, so its updates never mix with the release build's.
    var updatesDirectory: URL {
        applicationSupportDirectory.appendingPathComponent("Updates", isDirectory: true)
    }

    /// Ephemeral profiles "trash" into their own directory; the real Trash belongs to the user.
    var trashDirectory: URL {
        applicationSupportDirectory.appendingPathComponent("Trash", isDirectory: true)
    }

    private static var userApplicationSupportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support", isDirectory: true)
    }
}
