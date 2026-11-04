import Foundation
import Observation

/// One project's proto schema: its proto roots compiled with protoc, merged with its descriptor sets.
///
/// Recompiles on `recompile()`, on a configuration that resolves differently, and, debounced, when files under the
/// roots or the descriptor sets change. Only the newest compile publishes; an older one still running is cancelled,
/// which terminates its protoc.
@MainActor
@Observable
public final class ProtoWorkspace {
    public enum Status: Hashable, Sendable {
        /// Nothing configured.
        case empty
        case compiling
        case ready(serviceCount: Int, compiledAt: Date)
        /// Proto roots are configured but no protoc was found; descriptor sets are still loaded.
        case needsProtoc
        case failed([ProtocDiagnostic])
        /// Configured roots, entry files, or descriptor sets that are not on disk, by `ProjectPathResolver.describe`.
        case missingPaths([String])
    }

    public let projectID: ProjectID
    public private(set) var configuration: ProjectGRPCConfiguration
    /// The last build's schema. It stays in place while a recompile runs, so pickers never flash empty.
    public private(set) var registry: DescriptorRegistry = .empty
    public private(set) var status: Status = .empty
    /// Problems that did not stop the build, such as `.proto` files skipped because protoc could misread their names.
    /// Kept apart from `status` so a `.ready` schema can still explain what it left out.
    public private(set) var warnings: [ProtocDiagnostic] = []

    @ObservationIgnored private let environment: ProtoWorkspaceEnvironment
    @ObservationIgnored private var plan: ProtoWorkspacePlan
    @ObservationIgnored private var lastCompilation: ProtoWorkspaceCompilation?
    @ObservationIgnored private var compileTask: Task<Void, Never>?
    @ObservationIgnored private var debounceTask: Task<Void, Never>?
    @ObservationIgnored private var watchTask: Task<Void, Never>?
    @ObservationIgnored private var watchedURLs: [URL] = []
    /// Bumped per compile; a result from an older one is dropped even if it finished before seeing its cancellation.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var isStopped = false

    /// Starts watching and compiling right away.
    public init(
        projectID: ProjectID,
        configuration: ProjectGRPCConfiguration,
        resolver: ProjectPathResolver,
        environment: ProtoWorkspaceEnvironment
    ) {
        self.projectID = projectID
        self.configuration = configuration
        self.environment = environment
        plan = ProtoWorkspacePlan(configuration: configuration, resolver: resolver)
        restartWatching()
        startCompile(reusingCache: true)
    }

    isolated deinit {
        stop()
    }

    /// Adopts a new configuration or local-path mapping, recompiling only when it resolves to different paths.
    public func update(configuration: ProjectGRPCConfiguration, resolver: ProjectPathResolver) {
        let newPlan = ProtoWorkspacePlan(configuration: configuration, resolver: resolver)
        self.configuration = configuration
        guard newPlan != plan, !isStopped else {
            return
        }
        plan = newPlan
        lastCompilation = nil
        restartWatching()
        startCompile(reusingCache: true)
    }

    /// Compiles now, bypassing the compile cache, and cancels a pending debounce and any compile in flight. An
    /// explicit request is how a user recovers from anything the cache could not see change.
    public func recompile() {
        guard !isStopped else {
            return
        }
        startCompile(reusingCache: false)
    }

    /// Returns once no debounce or compile is pending, for callers that need the newest schema, such as a run that
    /// resolves its method. A pending debounce counts, so this waits out the debounce delay.
    ///
    /// A file event while waiting replaces the debounce, and a debounce or recompile replaces the compile, so it waits
    /// again until neither changed across a pass, but for at most `settlePasses`. Editor autosave or a sync client can
    /// write faster than the debounce indefinitely; past the cap, the caller gets the latest published schema rather
    /// than waiting on a quiet moment that may never come.
    public func settled() async {
        for _ in 0..<Self.settlePasses {
            let debounce = debounceTask
            let compile = compileTask
            await debounce?.value
            await compile?.value
            if debounce == debounceTask, compile == compileTask {
                return
            }
        }
    }

    /// Enough for an event that replaces the debounce and the compile it then starts (three passes), with one spare.
    static let settlePasses = 4

    /// Ends watching and cancels any compile. The store calls this when a project is forgotten.
    public func stop() {
        isStopped = true
        watchTask?.cancel()
        debounceTask?.cancel()
        compileTask?.cancel()
        watchTask = nil
        watchedURLs = []
    }

    private func restartWatching() {
        let urls = plan.watchedURLs
        guard urls != watchedURLs else {
            return
        }
        watchTask?.cancel()
        watchedURLs = urls
        guard !urls.isEmpty else {
            watchTask = nil
            return
        }
        let changes = environment.changes(urls)
        watchTask = Task { [weak self] in
            for await _ in changes {
                self?.scheduleDebouncedCompile()
            }
        }
    }

    private func scheduleDebouncedCompile() {
        debounceTask?.cancel()
        let sleep = environment.sleep
        let debounce = environment.debounce
        debounceTask = Task { [weak self] in
            do {
                try await sleep(debounce)
            } catch {
                return
            }
            guard let self, !Task.isCancelled, !self.isStopped else {
                return
            }
            self.startCompile(reusingCache: true)
        }
    }

    private func startCompile(reusingCache: Bool) {
        debounceTask?.cancel()
        compileTask?.cancel()
        generation += 1
        let generation = generation
        let plan = plan
        let previous = lastCompilation
        let importer = environment.importer
        let locateProtoc = environment.locateProtoc
        if !plan.isEmpty {
            status = .compiling
        }
        compileTask = Task { [weak self] in
            let outcome: ProtoWorkspaceOutcome
            do {
                outcome = try await ProtoWorkspaceBuilder.build(
                    plan,
                    previous: previous,
                    reusingCache: reusingCache,
                    importer: importer,
                    locateProtoc: locateProtoc
                )
            } catch {
                return
            }
            guard let self, !Task.isCancelled, generation == self.generation else {
                return
            }
            self.apply(outcome)
        }
    }

    private func apply(_ outcome: ProtoWorkspaceOutcome) {
        registry = outcome.registry
        warnings = outcome.warnings
        lastCompilation = outcome.compilation
        switch outcome.status {
        case .empty:
            status = .empty
        case .ready:
            status = .ready(serviceCount: outcome.registry.services.count, compiledAt: environment.now())
        case .needsProtoc:
            status = .needsProtoc
        case .failed(let diagnostics):
            status = .failed(diagnostics)
        case .missingPaths(let paths):
            status = .missingPaths(paths)
        }
    }
}
