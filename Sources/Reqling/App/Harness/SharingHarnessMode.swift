#if DEBUG
import Foundation
import ReqlingKit

/// A launch as the end-to-end sharing harness, read from `-DebugSharingHarness <config.json>`
/// (`scripts/sharing-e2e.sh` passes it on each Mac). The app then keeps its files under the config's directory, its Trash
/// included, and its Keychain items under a namespace of their own, so a run never reads or writes Reqling Dev's or fills
/// the Mac's Trash. It skips the first-sync notice, which a run starting from no files would raise every time, and serves
/// MCP on the config's port with its token, adding the CloudKit probes (`MCPHarnessTools`). Sync runs against the
/// container the harness build names (`SyncAvailability.containerIdentifier`), never the app's own, and applies what it
/// fetches even in the background (`AppDelegate.applicationDidResignActive`).
struct SharingHarnessMode: Decodable {
    /// Where the harness's projects, sync state, and history live, kept between launches so a restart resumes.
    let directory: String
    let port: Int
    let token: String

    /// `nil` for an ordinary launch. Read once, so `AppDI` and the component agree for the whole run; launch arguments
    /// land in `UserDefaults`' argument domain.
    static let current: SharingHarnessMode? = {
        guard let path = UserDefaults.standard.string(forKey: "DebugSharingHarness") else {
            return nil
        }
        // Any other build syncs through the app's own container, where a harness run would reach real data.
        guard Bundle.main.object(forInfoDictionaryKey: "ReqlingCloudKitContainer") != nil else {
            fatalError("The sharing harness runs only in the build `scripts/build.sh --e2e` makes, which has a container of its own.")
        }
        do {
            return try JSONDecoder().decode(SharingHarnessMode.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        } catch {
            fatalError("Couldn't read the sharing harness's config at \(path): \(error)")
        }
    }()

    /// The Keychain namespace the harness's secrets live under, apart from Reqling Dev's.
    static let keychainNamespace = "com.afollestad.reqling.e2e"

    @MainActor
    func makeComponent() -> AppComponent {
        let profile = AppStorageProfile(
            applicationSupportDirectory: URL(fileURLWithPath: directory, isDirectory: true),
            preferences: MemoryPreferences(),
            isEphemeral: false,
            keychainNamespace: Self.keychainNamespace
        )
        let component = AppComponent(storageProfile: profile, harness: self)
        component.settingsStore.update { settings in
            settings.mcpEnabled = true
            settings.mcpPort = port
            settings.checksForUpdatesAutomatically = false
        }
        return component
    }
}
#endif
