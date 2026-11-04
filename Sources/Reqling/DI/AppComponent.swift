import NeedleFoundation
import ReqlingKit

/// The root Needle component. It owns every app-scoped service; feature-specific registrations
/// live in `AppComponent+<Feature>.swift` extensions.
final class AppComponent: BootstrapComponent {
    let storageProfile: AppStorageProfile

    init(storageProfile: AppStorageProfile) {
        self.storageProfile = storageProfile
        super.init()
    }
}

@MainActor
extension AppComponent {
    var appInfo: AppInfo {
        shared { AppInfo.current }
    }
}
