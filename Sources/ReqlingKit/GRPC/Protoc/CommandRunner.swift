import Foundation
import Synchronization

/// How a finished command exited and what it printed.
public struct CommandResult: Hashable, Sendable {
    public let exitCode: Int32
    public let standardOutput: Data
    public let standardError: Data

    public init(exitCode: Int32, standardOutput: Data = Data(), standardError: Data = Data()) {
        self.exitCode = exitCode
        self.standardOutput = standardOutput
        self.standardError = standardError
    }

    public var standardOutputText: String {
        Self.text(standardOutput)
    }

    public var standardErrorText: String {
        Self.text(standardError)
    }

    /// Latin-1 accepts every byte, so output that is not valid UTF-8 still reaches the diagnostics instead of vanishing.
    private static func text(_ data: Data) -> String {
        String(bytes: data, encoding: .utf8) ?? String(bytes: data, encoding: .isoLatin1) ?? ""
    }
}

public enum CommandError: Error, Hashable, Sendable, LocalizedError {
    case launchFailed(executable: String, reason: String)
    case timedOut(executable: String, after: Duration)

    public var errorDescription: String? {
        switch self {
        case .launchFailed(let executable, let reason):
            "Could not run \(executable): \(reason)"
        case .timedOut(let executable, let after):
            "\(executable) did not finish within \(after.components.seconds) seconds."
        }
    }
}

/// Runs the external tools gRPC support needs (`protoc`, `ditto`). A protocol so tests stub every launch they do not
/// mean to make.
public protocol CommandRunning: Sendable {
    /// Runs `executable` directly, never through a shell, so arguments need no quoting and cannot be reinterpreted.
    ///
    /// A non-zero exit is a result, not an error. Throws `CommandError` when the process cannot start or outlives
    /// `timeout`, and `CancellationError` when the calling task is cancelled; both terminate the process first.
    func run(_ executable: URL, arguments: [String], currentDirectory: URL?, timeout: Duration) async throws -> CommandResult
}

/// `CommandRunning` through `Process`, draining both pipes as output arrives so a chatty tool never blocks on a full
/// pipe.
public struct ProcessCommandRunner: CommandRunning {
    /// How long a terminated process gets to exit before `SIGKILL`, so a tool that ignores `SIGTERM` cannot hold a
    /// timeout or cancellation open.
    public static let terminationGrace: Duration = .seconds(2)

    private let sleep: @Sendable (Duration) async throws -> Void

    /// `sleep` drives the timeout and the termination grace period, so a test can expire them without waiting.
    public init(sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.sleep = sleep
    }

    @concurrent
    public func run(_ executable: URL, arguments: [String], currentDirectory: URL?, timeout: Duration) async throws -> CommandResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let currentDirectory {
            process.currentDirectoryURL = currentDirectory
        }
        let execution = Execution(process: process, name: executable.lastPathComponent, timeout: timeout, sleep: sleep)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                execution.start(continuation)
            }
        } onCancel: {
            execution.interrupt(.cancelled)
        }
    }
}

/// One launch's shared state. The termination handler and both pipe handlers report on their own queues; the
/// continuation resumes once the process has exited and, unless it was interrupted, both pipes reached EOF.
private final class Execution: Sendable {
    enum Interruption {
        case cancelled
        case timedOut(Duration)
    }

    private struct State {
        var continuation: CheckedContinuation<CommandResult, any Error>?
        var interruption: Interruption?
        /// Set before `Process.run`, so a termination handler that fires before `run` returns still counts.
        var launched = false
        var exitCode: Int32?
        var output = Data()
        var error = Data()
        var openPipes = 2
        var timer: Task<Void, Never>?
    }

    private let process: Process
    private let name: String
    private let timeout: Duration
    private let sleep: @Sendable (Duration) async throws -> Void
    private let outputPipe = Pipe()
    private let errorPipe = Pipe()
    private let state = Mutex(State())

    init(process: Process, name: String, timeout: Duration, sleep: @escaping @Sendable (Duration) async throws -> Void) {
        self.process = process
        self.name = name
        self.timeout = timeout
        self.sleep = sleep
    }

    func start(_ continuation: CheckedContinuation<CommandResult, any Error>) {
        // Cancellation can land before the continuation exists; never launch in that case.
        let alreadyInterrupted = state.withLock { state -> Bool in
            state.continuation = continuation
            state.launched = state.interruption == nil
            return !state.launched
        }
        if alreadyInterrupted {
            finish()
            return
        }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        process.terminationHandler = { [weak self] process in
            self?.update { $0.exitCode = process.terminationStatus }
        }
        drain(outputPipe) { $0.output.append($1) }
        drain(errorPipe) { $0.error.append($1) }
        do {
            try process.run()
        } catch {
            stopDraining()
            let continuation = state.withLock { state in
                defer { state.continuation = nil }
                return state.continuation
            }
            continuation?.resume(throwing: CommandError.launchFailed(executable: name, reason: error.localizedDescription))
            return
        }
        // Timed from launch, not from the call, so a slow spawn does not eat into the tool's time.
        let timer = Task { [sleep, timeout, weak self] in
            do {
                try await sleep(timeout)
            } catch {
                return
            }
            self?.interrupt(.timedOut(timeout))
        }
        let (interruptedDuringLaunch, alreadyFinished) = state.withLock { state in
            state.timer = timer
            return (state.interruption != nil, state.continuation == nil)
        }
        // A tool fast enough to finish before this point would otherwise leave the timer sleeping out the timeout.
        if alreadyFinished {
            timer.cancel()
        }
        // An interruption while `run` was spawning found nothing to terminate yet.
        if interruptedDuringLaunch {
            terminate()
        }
    }

    /// Also ends a wait for EOF after a normal exit, when a grandchild still holds the pipes.
    func interrupt(_ interruption: Interruption) {
        let needsTermination = state.withLock { state -> Bool in
            guard state.interruption == nil else {
                return false
            }
            state.interruption = interruption
            return state.launched && state.exitCode == nil
        }
        if needsTermination {
            terminate()
        }
        finish()
    }

    /// `SIGTERM`, then `SIGKILL` once the grace period passes without an exit.
    private func terminate() {
        guard process.isRunning else {
            return
        }
        process.terminate()
        Task { [sleep, weak self] in
            try? await sleep(ProcessCommandRunner.terminationGrace)
            self?.kill()
        }
    }

    private func kill() {
        guard state.withLock({ $0.exitCode == nil }), process.isRunning else {
            return
        }
        _ = Darwin.kill(process.processIdentifier, SIGKILL)
    }

    private func drain(_ pipe: Pipe, into store: @escaping @Sendable (inout State, Data) -> Void) {
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                self?.update { $0.openPipes -= 1 }
            } else {
                self?.update { store(&$0, data) }
            }
        }
    }

    private func stopDraining() {
        for pipe in [outputPipe, errorPipe] {
            pipe.fileHandleForReading.readabilityHandler = nil
            try? pipe.fileHandleForReading.close()
        }
    }

    private func update(_ change: (inout State) -> Void) {
        state.withLock { change(&$0) }
        finish()
    }

    /// Resumes once the process has exited and both pipes are drained. An interrupted process resumes on exit alone:
    /// a grandchild that inherited the pipes, such as one a wrapper script started without `exec`, can hold them
    /// open long after.
    private func finish() {
        let resumption = state.withLock { state -> (CheckedContinuation<CommandResult, any Error>, Result<CommandResult, any Error>)? in
            guard let continuation = state.continuation else {
                return nil
            }
            if state.launched {
                guard state.exitCode != nil, state.interruption != nil || state.openPipes == 0 else {
                    return nil
                }
            }
            state.continuation = nil
            state.timer?.cancel()
            switch state.interruption {
            case .cancelled:
                return (continuation, .failure(CancellationError()))
            case .timedOut(let duration):
                return (continuation, .failure(CommandError.timedOut(executable: name, after: duration)))
            case nil:
                let result = CommandResult(exitCode: state.exitCode ?? -1, standardOutput: state.output, standardError: state.error)
                return (continuation, .success(result))
            }
        }
        guard let (continuation, result) = resumption else {
            return
        }
        if state.withLock({ $0.launched }) {
            stopDraining()
        }
        continuation.resume(with: result)
    }
}
