import Foundation
import ReqlingKit
import Synchronization

@testable import Reqling

/// Answers every search with a preset result and records the overrides it was asked about.
final class StubProtocLocator: ProtocLocating {
    private struct State {
        var result: Result<ProtocInstallation?, StubLocateError> = .success(nil)
        var overridePaths: [String?] = []
    }

    private let state = Mutex(State())

    init(_ result: Result<ProtocInstallation?, StubLocateError> = .success(nil)) {
        state.withLock { $0.result = result }
    }

    var result: Result<ProtocInstallation?, StubLocateError> {
        get { state.withLock { $0.result } }
        set { state.withLock { $0.result = newValue } }
    }

    /// The `overridePath` of every search, in order.
    var overridePaths: [String?] {
        state.withLock { $0.overridePaths }
    }

    func locate(overridePath: String?) async throws -> ProtocInstallation? {
        try state.withLock { state in
            state.overridePaths.append(overridePath)
            return try state.result.get()
        }
    }
}

/// Stands in for `ProtocLocatorError`, whose initializer `ReqlingKit` keeps internal.
struct StubLocateError: LocalizedError, Hashable {
    let message: String

    var errorDescription: String? {
        message
    }
}

/// Reports `phases`, then holds the install open until `finish(_:)` or cancellation, so a test sees it in progress.
final class StubProtocInstaller: ProtocInstalling {
    private struct State {
        var pending: CheckedContinuation<ProtocInstallation, any Error>?
        var installCount = 0
        var wasCancelled = false
    }

    let phases: [ProtocInstallPhase]
    private let state = Mutex(State())

    init(phases: [ProtocInstallPhase] = []) {
        self.phases = phases
    }

    var installCount: Int {
        state.withLock { $0.installCount }
    }

    var isWaiting: Bool {
        state.withLock { $0.pending != nil }
    }

    var wasCancelled: Bool {
        state.withLock { $0.wasCancelled }
    }

    func install(progress: @escaping @Sendable (ProtocInstallPhase) -> Void) async throws -> ProtocInstallation {
        state.withLock { $0.installCount += 1 }
        for phase in phases {
            progress(phase)
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                // Checked under the lock the cancellation handler takes, so a cancel landing before this is stored
                // still resumes it.
                state.withLock { state in
                    if Task.isCancelled {
                        state.wasCancelled = true
                        continuation.resume(throwing: CancellationError())
                    } else {
                        state.pending = continuation
                    }
                }
            }
        } onCancel: {
            let pending = state.withLock { state in
                state.wasCancelled = true
                return state.pending.take()
            }
            pending?.resume(throwing: CancellationError())
        }
    }

    func finish(_ result: Result<ProtocInstallation, ProtocInstallError>) {
        let pending = state.withLock { $0.pending.take() }
        pending?.resume(with: result.mapError { $0 as any Error })
    }
}

/// Installations as the locator would report them.
enum ProtocFixtures {
    static let homebrew = ProtocInstallation(
        executable: URL(fileURLWithPath: "/opt/homebrew/bin/protoc"),
        source: .homebrew,
        version: "33.1",
        includeDirectory: URL(fileURLWithPath: "/opt/homebrew/include")
    )

    static let managed = ProtocInstallation(
        executable: URL(fileURLWithPath: "/tmp/Tools/protoc/\(ProtocRelease.pinned.version)/bin/protoc"),
        source: .managed,
        version: ProtocRelease.pinned.version,
        includeDirectory: nil
    )
}

/// A `ProtocToolingModel` over stubs, counting the recompiles it asks for.
@MainActor
final class ProtocToolingFixture {
    let locator: StubProtocLocator
    let installer: StubProtocInstaller
    private(set) var recompileCount = 0
    private(set) var model: ProtocToolingModel!

    init(
        locator: StubProtocLocator = StubProtocLocator(),
        installer: StubProtocInstaller = StubProtocInstaller(),
        settings: SettingsStore,
        system: any SystemIntegration
    ) {
        self.locator = locator
        self.installer = installer
        model = ProtocToolingModel(locator: locator, installer: installer, settings: settings, system: system) { [weak self] in
            self?.recompileCount += 1
        }
    }
}
