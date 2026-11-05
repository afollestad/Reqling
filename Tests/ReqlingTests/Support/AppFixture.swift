import AppKit
import ReqlingKit
import UniformTypeIdentifiers

@testable import Reqling

/// An isolated app graph: test storage, in-memory secrets, a directory trash, no folder watching, a fixed
/// `AppInfo`, and a stub for every AppKit integration and for protoc discovery and installation. Autosave runs
/// without waiting unless `sleep` is replaced.
@MainActor
final class AppFixture {
    static let appInfo = AppInfo(name: "Reqling", bundleIdentifier: "com.afollestad.reqling", version: "1.0.0", build: "1")

    let profile = AppStorageProfile.test()
    let component: AppComponent
    let system = StubSystemIntegration()
    let protoc: ProtocToolingFixture
    let model: AppModel

    init(
        protocLocator: StubProtocLocator = StubProtocLocator(),
        protocInstaller: StubProtocInstaller = StubProtocInstaller(),
        updates: AppUpdateManager? = nil,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { _ in }
    ) {
        component = AppDI.makeTestComponent(storageProfile: profile)
        protoc = ProtocToolingFixture(locator: protocLocator, installer: protocInstaller, settings: component.settingsStore, system: system)
        model = AppModel(
            library: component.projectLibrary,
            workspace: component.workspaceState,
            runner: component.requestRunner,
            settings: component.settingsStore,
            appInfo: Self.appInfo,
            keychain: component.keychainIdentities,
            system: system,
            protoWorkspaces: component.protoWorkspaces,
            protocTooling: protoc.model,
            mcpServer: component.mcpServer,
            updates: updates ?? component.appUpdates,
            sleep: sleep
        )
    }

    var library: ProjectLibrary {
        component.projectLibrary
    }

    func tearDown() {
        // Stops every workspace's compile and watching before their files go.
        component.protoWorkspaces.retain(only: [])
        profile.cleanUp()
    }
}

/// Records what view models asked AppKit for, and answers with preset values.
@MainActor
final class StubSystemIntegration: SystemIntegration {
    var directoryToChoose: URL?
    var fileToChoose: URL?
    /// Answers `chooseFile` calls in order, `nil` cancelling one; `fileToChoose` answers once it runs out.
    var filesToChoose: [URL?] = []
    private(set) var fileMessages: [String?] = []
    var saveLocation: URL?
    var pathSharing: PathSharing? = .shared
    var quitsDiscardingUnsavedChanges = false
    private(set) var quitConfirmations = 0
    private(set) var pasteboard: String?
    private(set) var revealed: [URL] = []
    private(set) var broughtToFront = 0

    func chooseDirectory(prompt: String) -> URL? {
        directoryToChoose
    }

    func chooseFile(prompt: String, message: String?, allowedTypes: [UTType]) -> URL? {
        fileMessages.append(message)
        return filesToChoose.isEmpty ? fileToChoose : filesToChoose.removeFirst()
    }

    func chooseSaveLocation(suggestedName: String) -> URL? {
        saveLocation
    }

    func reveal(_ url: URL) {
        revealed.append(url)
    }

    func bringToFront() {
        broughtToFront += 1
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
