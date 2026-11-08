import Foundation
import ReqlingScriptProtocol
import Synchronization

/// Runs one phase of a request's scripts. A protocol, like `PKCS12ImportProbe`, so tests choose whether a real
/// process runs.
public protocol ScriptRunning: Sendable {
    func run(_ input: ScriptRunnerInput, blobs: [Data], timeLimit: Duration) -> ScriptExecution
    /// Starts a stream phase (`ScriptPhase.stream`): its top level runs at once, then each item `deliver` hands it
    /// reaches the handlers in turn. `timeLimit` bounds the top level, and each call on its own.
    func stream(_ input: ScriptRunnerInput, timeLimit: Duration) -> ScriptStreamExecution
}

/// One launched phase: its events as they arrive, a way to answer the requests its scripts send, how it ended, and a
/// way to stop it.
public struct ScriptExecution: Sendable {
    /// Ends once the helper has written its last event.
    public let events: AsyncStream<ScriptRunnerEvent>
    /// Answers a `ScriptRunnerEvent.fetch`, with the response's body for a `.response`; dropped once the helper is gone.
    public let reply: ScriptFetchReplying
    /// Resolves after every event was delivered and the process is gone.
    public let termination: @Sendable () async -> ScriptTermination
    /// Kills the process, if it still runs; `termination` then reports `.cancelled`.
    public let cancel: @Sendable () -> Void

    public init(
        events: AsyncStream<ScriptRunnerEvent>,
        reply: @escaping ScriptFetchReplying,
        termination: @escaping @Sendable () async -> ScriptTermination,
        cancel: @escaping @Sendable () -> Void
    ) {
        self.events = events
        self.reply = reply
        self.termination = termination
        self.cancel = cancel
    }

    /// A phase that never started, with no events.
    public static func failed(_ message: String) -> ScriptExecution {
        ScriptExecution(events: AsyncStream { $0.finish() }, reply: { _, _ in }, termination: { .failed(message) }, cancel: {})
    }
}

/// Writes a fetch's reply to the helper: the reply, then a `.response`'s body.
public typealias ScriptFetchReplying = @Sendable (ScriptFetchReply, Data) -> Void

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

    let executable: URL?
    let runtimeDirectory: URL?
    let sleep: Sleep
    /// How many items, and how many bytes of them, may wait for a stream phase's handlers before the oldest is dropped:
    /// `LiveEventBuffer`'s bounds, so a stream that outpaces its handlers costs no more than one that outpaces the window.
    let streamWaitingLimit: Int
    let streamWaitingByteLimit: Int

    /// `executable` and `runtimeDirectory` are `nil` when the app was built without them, which fails every phase
    /// rather than skipping it.
    public init(
        executable: URL?,
        runtimeDirectory: URL?,
        sleep: @escaping Sleep = { try await Task.sleep(for: $0) },
        streamWaitingLimit: Int = 2_000,
        streamWaitingByteLimit: Int = 32 * 1_024 * 1_024
    ) {
        self.executable = executable
        self.runtimeDirectory = runtimeDirectory
        self.sleep = sleep
        self.streamWaitingLimit = streamWaitingLimit
        self.streamWaitingByteLimit = streamWaitingByteLimit
    }

    static let missingMessage = "Reqling's script runner is missing. Reinstall Reqling."
    static let encodingMessage = "Reqling couldn't prepare the scripts to run."

    static func launchFailure(_ error: any Error) -> String {
        "Reqling couldn't start its script runner: \(error.localizedDescription)"
    }

    public func run(_ input: ScriptRunnerInput, blobs: [Data], timeLimit: Duration) -> ScriptExecution {
        guard let executable, let runtimeDirectory else {
            return .failed(Self.missingMessage)
        }
        var input = input
        input.runtimeDirectory = runtimeDirectory.path
        input.blobCount = blobs.count
        guard let header = try? JSONEncoder().encode(input) else {
            return .failed(Self.encodingMessage)
        }
        let launch: ScriptLaunch
        do {
            launch = try ScriptLaunch(executable: executable)
        } catch {
            return .failed(Self.launchFailure(error))
        }
        // Left open after the bodies, for the replies to the requests scripts send; closed once the helper is gone.
        let pipe = launch.input
        pipe.write(frame: header)
        for blob in blobs {
            pipe.write(frame: blob)
        }
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
            pipe.close()
            return process.termination
        }
        return ScriptExecution(
            events: events,
            reply: { pipe.write($0, body: $1) },
            termination: { await termination.value },
            cancel: { process.kill(.cancelled) }
        )
    }
}

/// One launch of the helper: its process, the pipes to it, and when it's done.
struct ScriptLaunch: Sendable {
    let process: ScriptProcess
    let input: ScriptInputPipe
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
        let input = standardInput.fileHandleForWriting
        output = standardOutput.fileHandleForReading
        // A helper that exits before reading everything must fail the write, not raise SIGPIPE in Reqling.
        _ = fcntl(input.fileDescriptor, F_SETNOSIGPIPE, 1)
        try process.run()
        self.process = ScriptProcess(process)
        self.input = ScriptInputPipe(input)
        self.exit = exit.stream
        reading = AsyncStream<Void>.makeStream()
    }

    /// Decodes events until the helper closes its output; a frame that can't be read ends the stream. `observe` sees
    /// each event first, on the reading thread, so a stream phase acts on a finished call without waiting on any actor.
    func readEvents(observe: (@Sendable (ScriptRunnerEvent) -> Void)? = nil) -> AsyncStream<ScriptRunnerEvent> {
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
                    observe?(event)
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

/// The helper's standard input. Frames are written in order off the caller's thread, so a helper that stops reading
/// can't hold it, and messages are encoded there too, never on the main actor. Writes after `close` are dropped.
final class ScriptInputPipe: Sendable {
    private let handle: FileHandle
    private let queue = DispatchQueue(label: "com.afollestad.reqling.script-input", qos: .userInitiated)
    private let isClosed = Mutex(false)

    init(_ handle: FileHandle) {
        self.handle = handle
    }

    func write(frame payload: Data) {
        enqueue { ScriptFraming.frame(payload) }
    }

    func write(_ message: ScriptRunnerMessage) {
        enqueue { (try? JSONEncoder().encode(message)).map(ScriptFraming.frame) }
    }

    /// A fetch's reply, and a `.response`'s body as the frame after it, written together so nothing comes between.
    func write(_ reply: ScriptFetchReply, body: Data) {
        enqueue {
            guard let header = try? JSONEncoder().encode(ScriptRunnerMessage.fetched(reply)) else {
                return nil
            }
            guard case .response = reply.outcome else {
                return ScriptFraming.frame(header)
            }
            return ScriptFraming.frame(header) + ScriptFraming.frame(body)
        }
    }

    /// Ends the helper's input once what was written before has gone out.
    func close() {
        queue.async { [self] in
            // Checked on the queue, so a write sent after the close is dropped rather than raced.
            guard isClosed.withLock({ closed in defer { closed = true }; return !closed }) else {
                return
            }
            try? handle.close()
        }
    }

    private func enqueue(_ frame: @escaping @Sendable () -> Data?) {
        queue.async { [self] in
            guard !isClosed.withLock({ $0 }), let frame = frame() else {
                return
            }
            try? handle.write(contentsOf: frame)
        }
    }
}

/// The running helper, and why it was stopped if Reqling stopped it. A kill names its reason first, so a time limit
/// and a cancel arriving together report the earlier one.
final class ScriptProcess: Sendable {
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
