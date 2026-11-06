import ReqlingKit

/// Owns the app's single root component and the one-time Needle provider registration.
@MainActor
enum AppDI {
    static let component: AppComponent = {
        registerNeedleProviders()
        #if DEBUG
        if let screenshotMode = ScreenshotMode.current {
            return screenshotMode.makeComponent()
        }
        #endif
        return AppComponent(storageProfile: .production)
    }()

    /// A fresh component graph over isolated storage, with in-memory secrets unless `secretStore` stands in. Callers own
    /// the profile's `cleanUp()`.
    static func makeTestComponent(storageProfile: AppStorageProfile, secretStore: (any SecretStore)? = nil) -> AppComponent {
        registerNeedleProviders()
        return AppComponent(storageProfile: storageProfile, testSecretStore: secretStore)
    }

    private static func registerNeedleProviders() {
        _ = providerRegistration
    }

    private static let providerRegistration: Void = {
        registerProviderFactories()
    }()
}
