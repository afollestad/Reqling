import Foundation
@testable import ReqlingKit
import XCTest

/// One Mac in a sync test: its own library, Keychain, workspace, and runner over its own temporary directory, and a
/// transport to the shared `SyncTestCloud`. Watching is off, so `reload` stands in for an outside edit landing.
@MainActor
final class SyncTestMac {
    let storage: LibraryFixture
    let workspace: WorkspaceStateStore
    let runner: RequestRunner
    let lifecycle: ProjectLifecycle
    let transport: SyncTestTransport
    let sync: LibrarySync
    private let suiteName = "com.afollestad.reqling.tests.sync.\(UUID().uuidString)"
    var clock = Date(timeIntervalSince1970: 1_000_000)

    var library: ProjectLibrary {
        storage.library
    }

    init(cloud: SyncTestCloud) throws {
        storage = try LibraryFixture()
        workspace = WorkspaceStateStore(fileURL: storage.directory.file("Support/workspace.json"))
        let settings = SettingsStore(defaults: try XCTUnwrap(UserDefaults(suiteName: suiteName)))
        runner = RequestRunner(
            library: storage.library,
            workspace: workspace,
            settings: settings,
            keychain: EmptyKeychain(),
            pkcs12Probe: TLSFixtures.probe,
            history: RunHistory(directory: storage.directory.file("Support/History"), settings: settings),
            userAgent: "Reqling/1.0",
            scripts: HelperScriptRunner(executable: nil, runtimeDirectory: nil)
        )
        let protoWorkspaces = ProtoWorkspaceStore(environment: ProtoWorkspaceEnvironment(
            importer: ProtocImporter(cacheDirectory: storage.directory.file("Support/ProtocCache")),
            locateProtoc: { nil },
            changes: { _ in AsyncStream { $0.finish() } }
        ))
        lifecycle = ProjectLifecycle(library: storage.library, runner: runner, workspace: workspace, protoWorkspaces: protoWorkspaces)
        transport = SyncTestTransport(cloud: cloud)
        var now: () -> Date = { Date() }
        sync = LibrarySync(
            library: storage.library,
            lifecycle: lifecycle,
            secretStore: storage.secrets,
            directory: storage.directory.file("Support/Sync"),
            transport: transport,
            now: { now() }
        )
        now = { [unowned self] in clock }
    }

    func cleanUp() {
        sync.stop()
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        storage.directory.remove()
    }

    /// Moves this Mac's clock forward, so its next edit is later than any before it.
    func tick(_ seconds: TimeInterval = 1) {
        clock += seconds
    }

    func project(named name: String) -> LibraryProject? {
        library.projects.first { $0.name == name }
    }
}
