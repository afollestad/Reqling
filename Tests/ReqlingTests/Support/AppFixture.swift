import AppKit
import ReqlingKit
import UniformTypeIdentifiers

@testable import Reqling

/// An isolated app graph: test storage, in-memory secrets, a directory trash, no folder watching, a fixed
/// `AppInfo`, and a stub for every AppKit integration. Autosave runs without waiting unless `sleep` is replaced.
@MainActor
final class AppFixture {
    static let appInfo = AppInfo(name: "Reqling", bundleIdentifier: "com.afollestad.reqling", version: "1.0.0", build: "1")

    let profile = AppStorageProfile.test()
    let component: AppComponent
    let system = StubSystemIntegration()
    let model: AppModel

    init(sleep: @escaping @Sendable (Duration) async throws -> Void = { _ in }) {
        component = AppDI.makeTestComponent(storageProfile: profile)
        model = AppModel(
            library: component.projectLibrary,
            workspace: component.workspaceState,
            runner: component.requestRunner,
            settings: component.settingsStore,
            appInfo: Self.appInfo,
            keychain: component.keychainIdentities,
            system: system,
            sleep: sleep
        )
    }

    var library: ProjectLibrary {
        component.projectLibrary
    }

    func tearDown() {
        profile.cleanUp()
    }
}

/// Records what view models asked AppKit for, and answers with preset values.
@MainActor
final class StubSystemIntegration: SystemIntegration {
    var directoryToChoose: URL?
    var fileToChoose: URL?
    var saveLocation: URL?
    var pathSharing: PathSharing? = .shared
    var quitsDiscardingUnsavedChanges = false
    private(set) var quitConfirmations = 0
    private(set) var pasteboard: String?
    private(set) var revealed: [URL] = []

    func chooseDirectory(prompt: String) -> URL? {
        directoryToChoose
    }

    func chooseFile(prompt: String, allowedTypes: [UTType]) -> URL? {
        fileToChoose
    }

    func chooseSaveLocation(suggestedName: String) -> URL? {
        saveLocation
    }

    func reveal(_ url: URL) {
        revealed.append(url)
    }

    func copyToPasteboard(_ string: String) {
        pasteboard = string
    }

    func choosePathSharing(for url: URL) -> PathSharing? {
        pathSharing
    }

    func confirmQuitDiscardingUnsavedChanges() -> Bool {
        quitConfirmations += 1
        return quitsDiscardingUnsavedChanges
    }
}
