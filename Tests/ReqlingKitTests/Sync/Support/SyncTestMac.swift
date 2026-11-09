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
    private(set) var transport: SyncTestTransport
    private(set) var sync: LibrarySync
    private let cloud: SyncTestCloud
    private let suiteName = "com.afollestad.reqling.tests.sync.\(UUID().uuidString)"
    /// How far this Mac's clock runs ahead of the true time, the server's.
    var clockOffset: TimeInterval = 0

    var clock: Date {
        cloud.clock.addingTimeInterval(clockOffset)
    }

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
        self.cloud = cloud
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

    /// Quits Reqling and opens it again: what sync saved survives, and its transport's queue doesn't.
    func restart() async {
        sync.stop()
        transport = SyncTestTransport(cloud: cloud)
        sync = LibrarySync(
            library: storage.library,
            lifecycle: lifecycle,
            secretStore: storage.secrets,
            directory: storage.directory.file("Support/Sync"),
            transport: transport,
            now: { [unowned self] in clock }
        )
        await sync.start()
    }

    func cleanUp() {
        sync.stop()
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        storage.directory.remove()
    }

    /// Lets time pass, for every Mac and the server, so this Mac's next edit is later than any before it.
    func tick(_ seconds: TimeInterval = 1) {
        cloud.clock += seconds
    }

    func project(named name: String) -> LibraryProject? {
        library.projects.first { $0.name == name }
    }
}
