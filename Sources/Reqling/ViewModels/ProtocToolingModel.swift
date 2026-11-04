import Foundation
import Observation
import ReqlingKit

/// Which protoc the app would compile with, and the install of Reqling's own, shared by Settings ▸ gRPC and every
/// project's settings so an install started in one shows its progress in the other.
///
/// Searching is on demand (a page appearing, an override saved, an install finishing) rather than at launch: it runs
/// `protoc --version`, and workspaces already locate protoc themselves before each compile.
@MainActor
@Observable
final class ProtocToolingModel {
    enum Detection: Equatable {
        /// No search has finished yet.
        case unknown
        case found(ProtocInstallation)
        case missing
        /// The Settings override names something that is not a working protoc. The locator reports it rather than
        /// falling back, so a typo never silently compiles with another protoc.
        case invalidOverride(String)
    }

    enum InstallState: Equatable {
        case idle
        /// `nil` until the installer reports its first phase.
        case installing(ProtocInstallPhase?)
        case failed(String)
    }

    private(set) var detection: Detection = .unknown
    private(set) var installState: InstallState = .idle
    /// The override field's text. Saved only through `commitOverridePath()`, so a half-typed path never triggers a
    /// recompile of every project.
    var overridePathDraft: String
    /// The protoc release `install()` puts in place.
    let installVersion: String

    @ObservationIgnored private let locator: any ProtocLocating
    @ObservationIgnored private let installer: any ProtocInstalling
    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let system: any SystemIntegration
    /// `ProtoWorkspaceStore.recompileAll()` in the app. A changed override or a new install reaches no file watcher,
    /// so every workspace must be told.
    @ObservationIgnored private let recompileWorkspaces: @MainActor () -> Void
    /// Bumped per search, so a slower earlier search cannot overwrite a newer one's answer.
    @ObservationIgnored private var locateGeneration = 0
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var installTask: Task<Void, Never>?
    @ObservationIgnored private var progressTask: Task<Void, Never>?
    /// Bumped per install, so a phase delivered after an install ended cannot resurrect its progress.
    @ObservationIgnored private var installGeneration = 0

    init(
        locator: any ProtocLocating,
        installer: any ProtocInstalling,
        settings: SettingsStore,
        system: any SystemIntegration,
        installVersion: String = ProtocRelease.pinned.version,
        recompileWorkspaces: @escaping @MainActor () -> Void
    ) {
        self.locator = locator
        self.installer = installer
        self.settings = settings
        self.system = system
        self.installVersion = installVersion
        self.recompileWorkspaces = recompileWorkspaces
        overridePathDraft = settings.settings.protocPath ?? ""
    }

    var overridePath: String? {
        settings.settings.protocPath
    }

    var isInstalling: Bool {
        if case .installing = installState {
            return true
        }
        return false
    }

    /// Whether the found protoc is the one `install()` would put in place, so the action reads Reinstall.
    var hasCurrentManagedInstall: Bool {
        if case .found(let installation) = detection {
            return installation.source == .managed && installation.version == installVersion
        }
        return false
    }

    // MARK: - Locating

    /// Searches again with the saved override. A cancelled search (its page went away) leaves the last answer.
    func refresh() async {
        locateGeneration += 1
        let generation = locateGeneration
        let result: Detection
        do {
            result = try await locator.locate(overridePath: settings.settings.protocPath).map(Detection.found) ?? .missing
        } catch is CancellationError {
            return
        } catch {
            result = .invalidOverride(error.localizedDescription)
        }
        guard generation == locateGeneration else {
            return
        }
        detection = result
    }

    private func startRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            await self?.refresh()
        }
    }

    // MARK: - Override

    /// Saves the draft as the override when it differs, then recompiles every project with whatever it names.
    func commitOverridePath() {
        let trimmed = overridePathDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let path = trimmed.isEmpty ? nil : trimmed
        overridePathDraft = path ?? ""
        guard path != settings.settings.protocPath else {
            return
        }
        settings.update { $0.protocPath = path }
        recompileWorkspaces()
        startRefresh()
    }

    func chooseOverridePath() {
        guard let url = system.chooseFile(prompt: "Use protoc", allowedTypes: []) else {
            return
        }
        overridePathDraft = url.path
        commitOverridePath()
    }

    func clearOverridePath() {
        overridePathDraft = ""
        commitOverridePath()
    }

    // MARK: - Installing

    /// Downloads and installs the pinned protoc. Success recompiles every project and searches again, since an
    /// override, if set, still wins over the new install.
    func install() {
        guard !isInstalling else {
            return
        }
        installGeneration += 1
        let generation = installGeneration
        installState = .installing(nil)
        // An ordered stream rather than a main-actor hop per phase, which could land out of order.
        let (phases, continuation) = AsyncStream.makeStream(of: ProtocInstallPhase.self, bufferingPolicy: .bufferingNewest(1))
        progressTask = Task { [weak self] in
            for await phase in phases {
                self?.show(phase, generation: generation)
            }
        }
        let installer = installer
        installTask = Task { [weak self] in
            let result: Result<ProtocInstallation, any Error>
            do {
                result = .success(try await installer.install { continuation.yield($0) })
            } catch {
                result = .failure(error)
            }
            continuation.finish()
            self?.finishInstall(result, generation: generation, wasCancelled: Task.isCancelled)
        }
    }

    func cancelInstall() {
        installTask?.cancel()
    }

    /// Installs as `install()` does and waits for the outcome, for an agent's `install_protoc`; an install already
    /// running is awaited rather than started again, so its progress shows in Settings either way.
    func installAndWait() async throws -> ProtocInstallation {
        install()
        while let task = installTask {
            await task.value
        }
        if case .failed(let message) = installState {
            throw MCPToolError(message)
        }
        await refresh()
        guard case .found(let installation) = detection else {
            throw MCPToolError("The install didn't finish, so no protoc is available.")
        }
        return installation
    }

    private func show(_ phase: ProtocInstallPhase, generation: Int) {
        guard generation == installGeneration, isInstalling else {
            return
        }
        installState = .installing(phase)
    }

    private func finishInstall(_ result: Result<ProtocInstallation, any Error>, generation: Int, wasCancelled: Bool) {
        guard generation == installGeneration else {
            return
        }
        progressTask?.cancel()
        progressTask = nil
        installTask = nil
        switch result {
        case .success:
            installState = .idle
            recompileWorkspaces()
            startRefresh()
        case .failure(let error):
            // URLSession reports a cancelled transfer as its own error rather than `CancellationError`.
            let isCancellation = wasCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled
            installState = isCancellation ? .idle : .failed(error.localizedDescription)
        }
    }
}

/// The search `ProtocToolingModel` runs, so tests decide what is found without touching the Mac's protoc.
protocol ProtocLocating: Sendable {
    func locate(overridePath: String?) async throws -> ProtocInstallation?
}

/// The install `ProtocToolingModel` runs, so tests drive phases, failure, and cancellation without downloading.
protocol ProtocInstalling: Sendable {
    func install(progress: @escaping @Sendable (ProtocInstallPhase) -> Void) async throws -> ProtocInstallation
}

extension ProtocLocator: ProtocLocating {}

extension ProtocInstaller: ProtocInstalling {}
