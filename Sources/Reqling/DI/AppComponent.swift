import NeedleFoundation
import ReqlingKit

/// The root Needle component. It owns every app-scoped service; feature-specific registrations
/// live in `AppComponent+<Feature>.swift` extensions.
final class AppComponent: BootstrapComponent {
    let storageProfile: AppStorageProfile
    /// The secret store an ephemeral (test) graph uses instead of its own in-memory one, such as one whose reads fail
    /// like a locked Keychain. A production graph ignores it.
    let testSecretStore: (any SecretStore)?
    /// The script runner an ephemeral (test) graph uses, such as one over the helper beside the test bundle. Without
    /// one, its scripts fail closed. A production graph ignores it.
    let testScriptRunner: (any ScriptRunning)?
    #if DEBUG
    /// The end-to-end sharing harness this graph serves, if launched as one.
    let harness: SharingHarnessMode?

    init(
        storageProfile: AppStorageProfile,
        testSecretStore: (any SecretStore)? = nil,
        testScriptRunner: (any ScriptRunning)? = nil,
        harness: SharingHarnessMode? = nil
    ) {
        self.storageProfile = storageProfile
        self.testSecretStore = testSecretStore
        self.testScriptRunner = testScriptRunner
        self.harness = harness
        super.init()
    }
    #else
    init(storageProfile: AppStorageProfile, testSecretStore: (any SecretStore)? = nil, testScriptRunner: (any ScriptRunning)? = nil) {
        self.storageProfile = storageProfile
        self.testSecretStore = testSecretStore
        self.testScriptRunner = testScriptRunner
        super.init()
    }
    #endif
}

@MainActor
extension AppComponent {
    var appInfo: AppInfo {
        shared { AppInfo.current }
    }

    /// What Keychain services start with (`AppStorageProfile.keychainNamespace`).
    var keychainNamespace: String {
        storageProfile.keychainNamespace ?? appInfo.bundleIdentifier
    }
}
