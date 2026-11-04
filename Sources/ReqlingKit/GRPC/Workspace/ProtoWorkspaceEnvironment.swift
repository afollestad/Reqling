import Foundation

/// Everything a `ProtoWorkspace` reaches outside itself, injected so tests drive file events and debounce time.
public struct ProtoWorkspaceEnvironment: Sendable {
    public var importer: ProtocImporter
    /// Runs before each compile, so a Settings override or a fresh install applies without rebuilding workspaces.
    /// Throws `ProtocLocatorError` for a broken override.
    public var locateProtoc: @Sendable () async throws -> ProtocInstallation?
    /// Change notifications for proto root directories and descriptor set files. The stream ends watching when the
    /// workspace stops iterating it.
    public var changes: @MainActor @Sendable ([URL]) -> AsyncStream<Void>
    /// Drives the debounce after a file change.
    public var sleep: @Sendable (Duration) async throws -> Void
    /// Stamps `ProtoWorkspace.Status.ready`.
    public var now: @Sendable () -> Date
    /// How long the files must stay quiet before a recompile; an editor's save or a checkout touches many at once.
    public var debounce: Duration

    public init(
        importer: ProtocImporter,
        locateProtoc: @escaping @Sendable () async throws -> ProtocInstallation?,
        changes: @escaping @MainActor @Sendable ([URL]) -> AsyncStream<Void>,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        now: @escaping @Sendable () -> Date = Date.init,
        debounce: Duration = .milliseconds(500)
    ) {
        self.importer = importer
        self.locateProtoc = locateProtoc
        self.changes = changes
        self.sleep = sleep
        self.now = now
        self.debounce = debounce
    }

    /// The app's wiring: protoc found through `ProtocLocator` with the Settings override `protocPath` returns, compiles
    /// cached in `cacheDirectory`, and FSEvents for changes.
    ///
    /// - Parameters:
    ///   - toolsDirectory: The `Tools` folder `ProtocInstaller` installs into.
    ///   - cacheDirectory: Where compiled descriptor sets are kept across launches.
    public static func live(
        toolsDirectory: URL,
        cacheDirectory: URL,
        protocPath: @escaping @MainActor @Sendable () -> String?
    ) -> ProtoWorkspaceEnvironment {
        let locator = ProtocLocator(toolsDirectory: toolsDirectory)
        return ProtoWorkspaceEnvironment(
            importer: ProtocImporter(cacheDirectory: cacheDirectory),
            locateProtoc: {
                try await locator.locate(overridePath: await protocPath())
            },
            changes: { urls in
                FSEventsProtoChanges.stream(watching: urls)
            }
        )
    }
}
