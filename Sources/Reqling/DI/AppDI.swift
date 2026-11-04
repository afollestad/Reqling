/// Owns the app's single root component and the one-time Needle provider registration.
@MainActor
enum AppDI {
    static let component: AppComponent = {
        registerNeedleProviders()
        return AppComponent(storageProfile: .production)
    }()

    /// A fresh component graph over isolated storage. Callers own the profile's `cleanUp()`.
    static func makeTestComponent(storageProfile: AppStorageProfile) -> AppComponent {
        registerNeedleProviders()
        return AppComponent(storageProfile: storageProfile)
    }

    private static func registerNeedleProviders() {
        _ = providerRegistration
    }

    private static let providerRegistration: Void = {
        registerProviderFactories()
    }()
}
