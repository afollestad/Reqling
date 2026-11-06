import NeedleFoundation
import ReqlingKit

/// The root Needle component. It owns every app-scoped service; feature-specific registrations
/// live in `AppComponent+<Feature>.swift` extensions.
final class AppComponent: BootstrapComponent {
    let storageProfile: AppStorageProfile
    /// The secret store an ephemeral (test) graph uses instead of its own in-memory one, such as one whose reads fail
    /// like a locked Keychain. A production graph ignores it.
    let testSecretStore: (any SecretStore)?

    init(storageProfile: AppStorageProfile, testSecretStore: (any SecretStore)? = nil) {
        self.storageProfile = storageProfile
        self.testSecretStore = testSecretStore
        super.init()
    }
}

@MainActor
extension AppComponent {
    var appInfo: AppInfo {
        shared { AppInfo.current }
    }
}
