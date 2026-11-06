import Foundation
import ReqlingScriptProtocol
import Synchronization

/// Runs one phase of a request's scripts. A protocol, like `PKCS12ImportProbe`, so tests choose whether a real
/// process runs.
public protocol ScriptRunning: Sendable {
    func run(_ input: ScriptRunnerInput, blobs: [Data], timeLimit: Duration) -> ScriptExecution
}

/// One launched phase: its events as they arrive, how it ended, and a way to stop it.
public struct ScriptExecution: Sendable {
    /// Ends once the helper has written its last event.
    public let events: AsyncStream<ScriptRunnerEvent>
    /// Resolves after every event was delivered and the process is gone.
    public let termination: @Sendable () async -> ScriptTermination
    /// Kills the process, if it still runs; `termination` then reports `.cancelled`.
    public let cancel: @Sendable () -> Void

    public init(
        events: AsyncStream<ScriptRunnerEvent>,
        termination: @escaping @Sendable () async -> ScriptTermination,
        cancel: @escaping @Sendable () -> Void
    ) {
        self.events = events
        self.termination = termination
        self.cancel = cancel
    }

    /// A phase that never started, with no events.
    public static func failed(_ message: String) -> ScriptExecution {
        ScriptExecution(events: AsyncStream { $0.finish() }, termination: { .failed(message) }, cancel: {})
    }
}

/// How a phase's helper ended.
public enum ScriptTermination: Hashable, Sendable {
    /// Every level ran.
    case finished
    case timedOut
    case cancelled
    /// The helper couldn't start, crashed, or stopped before finishing.
    case failed(String)
}

/// Runs scripts in the `ReqlingScriptRunner` helper, so JavaScriptCore runs without a public way to stop it: the helper
/// is killed at the time limit, and a runaway script's memory or a crash ends the helper, never Reqling. The input
/// and the helper's exit statuses are the shared types in `ReqlingScriptProtocol`.
///
/// The helper gets an empty environment, and its standard error goes nowhere, so nothing it prints can block it.
public final class HelperScriptRunner: ScriptRunning {
    /// Waits out a time limit; injected so a test decides when one expires.
    public typealias Sleep = @Sendable (Duration) async throws -> Void

    private let executable: URL?
    private let runtimeDirectory: URL?
    private let sleep: Sleep

    /// `executable` and `runtimeDirectory` are `nil` when the app was built without them, which fails every phase
    /// rather than skipping it.
    public init(executable: URL?, runtimeDirectory: URL?, sleep: @escaping Sleep = { try await Task.sleep(for: $0) }) {
        self.executable = executable
        self.runtimeDirectory = runtimeDirectory
        self.sleep = sleep
    }

    static let missingMessage = "Reqling's script runner is missing. Reinstall Reqling."

    public func run(_ input: ScriptRunnerInput, blobs: [Data], timeLimit: Duration) -> ScriptExecution {
        guard let executable, let runtimeDirectory else {
            return .failed(Self.missingMessage)
        }
        var input = input
        input.runtimeDirectory = runtimeDirectory.path
        guard let header = try? JSONEncoder().encode(input) else {
            return .failed("Reqling couldn't prepare the scripts to run.")
        }
        let launch: Launch
        do {
            launch = try Launch(executable: executable)
        } catch {
            return .failed("Reqling couldn't start its script runner: \(error.localizedDescription)")
        }
        launch.send([ScriptFraming.frame(header)] + blobs.map(ScriptFraming.frame))
        let events = launch.readEvents()
        let process = launch.process
        let sleep = self.sleep
        let deadline = Task {
            guard (try? await sleep(timeLimit)) != nil else {
                return
            }
            process.kill(.timedOut)
        }
        let termination = Task {
            await launch.finished()
            deadline.cancel()
            return process.termination
        }
        return ScriptExecution(
            events: events,
            termination: { await termination.value },
            cancel: { process.kill(.cancelled) }
        )
    }
}

/// One launch of the helper: its process, the pipes to it, and when it's done.
private struct Launch: Sendable {
    let process: ScriptProcess
    private let input: FileHandle
    private let output: FileHandle
    private let exit: AsyncStream<Void>
    private let reading: (stream: AsyncStream<Void>, continuation: AsyncStream<Void>.Continuation)

    init(executable: URL) throws {
        let process = Process()
        process.executableURL = executable
        process.environment = [:]
        let standardInput = Pipe()
        let standardOutput = Pipe()
        process.standardInput = standardInput
        process.standardOutput = standardOutput
        process.standardError = FileHandle.nullDevice
        let exit = AsyncStream<Void>.makeStream()
        process.terminationHandler = { _ in
            exit.continuation.finish()
        }
        input = standardInput.fileHandleForWriting
        output = standardOutput.fileHandleForReading
        // A helper that exits before reading everything must fail the write, not raise SIGPIPE in Reqling.
        _ = fcntl(input.fileDescriptor, F_SETNOSIGPIPE, 1)
        try process.run()
        self.process = ScriptProcess(process)
        self.exit = exit.stream
        reading = AsyncStream<Void>.makeStream()
    }

    /// Writes the frames off this thread, so a helper that stops reading cannot hold the caller, then closes its input.
    func send(_ frames: [Data]) {
        let input = input
        DispatchQueue.global(qos: .userInitiated).async {
            for frame in frames {
                try? input.write(contentsOf: frame)
            }
            try? input.close()
        }
    }

    /// Decodes events until the helper closes its output; a frame that can't be read ends the stream.
    func readEvents() -> AsyncStream<ScriptRunnerEvent> {
        let events = AsyncStream<ScriptRunnerEvent>.makeStream()
        let output = output
        let process = process
        let reading = reading.continuation
        DispatchQueue.global(qos: .userInitiated).async {
            var frames = ScriptFraming.Reader()
            let decoder = JSONDecoder()
            reading: while true {
                let data = output.availableData
                guard !data.isEmpty, let complete = frames.append(data) else {
                    break reading
                }
                for frame in complete {
                    guard let event = try? decoder.decode(ScriptRunnerEvent.self, from: frame) else {
                        continue
                    }
                    if event == .done {
                        process.markDone()
                    }
                    events.continuation.yield(event)
                }
            }
            events.continuation.finish()
            reading.finish()
        }
        return events.stream
    }

    /// Returns once the process has exited and its output has been read to the end.
    func finished() async {
        for await _ in exit {}
        for await _ in reading.stream {}
    }
}

/// The running helper, and why it was stopped if Reqling stopped it. A kill names its reason first, so a time limit
/// and a cancel arriving together report the earlier one.
private final class ScriptProcess: Sendable {
    private struct State {
        var stopReason: ScriptTermination?
        var sawDone = false
    }

    private let process: Process
    private let state = Mutex(State())

    init(_ process: Process) {
        self.process = process
    }

    func markDone() {
        state.withLock { $0.sawDone = true }
    }

    func kill(_ reason: ScriptTermination) {
        let first = state.withLock { state in
            guard state.stopReason == nil else {
                return false
            }
            state.stopReason = reason
            return true
        }
        // Never once it has exited: its process ID may already belong to another process.
        if first, process.isRunning {
            Darwin.kill(process.processIdentifier, SIGKILL)
        }
    }

    /// Read only once the process has exited.
    var termination: ScriptTermination {
        let state = state.withLock { $0 }
        if let reason = state.stopReason, process.terminationReason == .uncaughtSignal || !state.sawDone {
            return reason
        }
        switch (process.terminationReason, process.terminationStatus) {
        case (.exit, ScriptRunnerExit.success) where state.sawDone:
            return .finished
        case (.exit, ScriptRunnerExit.badInput):
            return .failed("Reqling's script runner couldn't read what to run.")
        case (.exit, ScriptRunnerExit.missingRuntime):
            return .failed("Reqling's script runtime is missing. Reinstall Reqling.")
        case (.exit, ScriptRunnerExit.noContext):
            return .failed("JavaScriptCore couldn't start the scripts.")
        case (.exit, let status):
            return .failed("The script runner stopped early, with status \(status).")
        case (_, let signal):
            return .failed("The script runner crashed (signal \(signal)).")
        }
    }
}
