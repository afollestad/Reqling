import Foundation
@testable import ReqlingKit

@testable import Reqling

/// An iCloud with nothing in it, signed in as `account`, for app tests of sync's controls: it counts what's asked of it.
@MainActor
final class StubSyncTransport: SyncTransport {
    weak var delegate: (any SyncTransportDelegate)?
    var account: String? = "account-a"
    private(set) var fetches = 0
    private(set) var sends = 0

    func accountID() async throws -> String? {
        account
    }

    func start(with state: Data?) {}

    func stop() {}

    func enqueue(_ changes: [SyncPendingChange]) {}

    func cancelPending(in zone: SyncZone) {}

    func fetchChanges() async {
        fetches += 1
        delegate?.transportDidFinishFetching(wasWhole: false)
    }

    func sendChanges() async {
        sends += 1
    }

    func resetState() {}
}

extension AppFixture {
    /// A fixture whose iCloud sync runs over `transport`, never iCloud, waiting out its pauses with `sleep`.
    static func syncing(
        over transport: StubSyncTransport,
        profileExpiry: Date? = nil,
        now: @escaping () -> Date = Date.init,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { _ in }
    ) -> AppFixture {
        AppFixture(sync: { component, system in
            let lifecycle = ProjectLifecycle(
                library: component.projectLibrary,
                runner: component.requestRunner,
                workspace: component.workspaceState,
                protoWorkspaces: component.protoWorkspaces
            )
            let sync = LibrarySync(
                library: component.projectLibrary,
                lifecycle: lifecycle,
                secretStore: component.secretStore,
                directory: component.storageProfile.syncDirectory,
                transport: transport,
                now: now
            )
            return ICloudSyncModel(
                sync: sync,
                library: component.projectLibrary,
                settings: component.settingsStore,
                system: system,
                profileExpiry: profileExpiry,
                now: now,
                sleep: sleep
            )
        })
    }
}
