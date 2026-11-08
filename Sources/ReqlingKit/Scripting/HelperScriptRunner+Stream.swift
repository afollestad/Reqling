import Foundation
import ReqlingScriptProtocol
import Synchronization

/// A launched stream phase: its events as they arrive, a way to hand it each item without waiting, and how it ended.
public struct ScriptStreamExecution: Sendable {
    /// Ends once the helper has written its last event.
    public let events: AsyncStream<ScriptRunnerEvent>
    /// Hands the handlers an item and returns at once, however far behind they are, so the stream stays responsive.
    public let deliver: @Sendable (ScriptStreamItem) -> ScriptStreamDelivery
    /// The connection or call no longer takes what `rq.send` sends.
    public let closeSending: @Sendable () -> Void
    /// Drops what waits, returning how many items it held, and ends the phase once the call in hand finishes.
    public let stop: @Sendable () -> Int
    /// Ends the phase once every waiting item was handled.
    public let end: @Sendable () -> Void
    /// Resolves after every event was delivered and the process is gone.
    public let termination: @Sendable () async -> ScriptStreamTermination
    /// Kills the process, if it still runs; `termination` then reports `.cancelled`.
    public let cancel: @Sendable () -> Void

    public init(
        events: AsyncStream<ScriptRunnerEvent>,
        deliver: @escaping @Sendable (ScriptStreamItem) -> ScriptStreamDelivery,
        closeSending: @escaping @Sendable () -> Void,
        stop: @escaping @Sendable () -> Int,
        end: @escaping @Sendable () -> Void,
        termination: @escaping @Sendable () async -> ScriptStreamTermination,
        cancel: @escaping @Sendable () -> Void
    ) {
        self.events = events
        self.deliver = deliver
        self.closeSending = closeSending
        self.stop = stop
        self.end = end
        self.termination = termination
        self.cancel = cancel
    }

    /// A phase that never started: no events, and every item refused.
    public static func failed(_ message: String) -> ScriptStreamExecution {
        ScriptStreamExecution(
            events: AsyncStream { $0.finish() },
            deliver: { _ in .refused },
            closeSending: {},
            stop: { 0 },
            end: {},
            termination: { ScriptStreamTermination(reason: .failed(message), item: nil, abandoned: 0) },
            cancel: {}
        )
    }
}

/// What became of an item handed to a stream phase.
public enum ScriptStreamDelivery: Hashable, Sendable {
    /// It waits for the handlers, or is with them now; making room dropped this many older items that waited.
    case queued(dropped: Int)
    /// The phase is ending or over, so it reaches no handler.
    case refused
    /// No handler was registered for the stream, so nothing it receives is needed.
    case unneeded
}

/// How a stream phase's helper ended.
public struct ScriptStreamTermination: Hashable, Sendable {
    public var reason: ScriptTermination
    /// The item it was handling when it ended, which a time limit or crash names; `nil` when it ended in its top level
    /// or between calls.
    public var item: Int?
    /// Items that were waiting and never reached a handler, since the helper ended first.
    public var abandoned: Int

    public init(reason: ScriptTermination, item: Int?, abandoned: Int) {
        self.reason = reason
        self.item = item
        self.abandoned = abandoned
    }
}

extension HelperScriptRunner {
    /// Launches the helper for a stream phase, its input left open for items. The time limit runs while the helper
    /// works on its top level or an item, and never while it waits for one, so a quiet stream is never killed.
    public func stream(_ input: ScriptRunnerInput, timeLimit: Duration) -> ScriptStreamExecution {
        guard let executable, let runtimeDirectory else {
            return .failed(Self.missingMessage)
        }
        var input = input
        input.runtimeDirectory = runtimeDirectory.path
        guard let header = try? JSONEncoder().encode(input) else {
            return .failed(Self.encodingMessage)
        }
        let launch: ScriptLaunch
        do {
            launch = try ScriptLaunch(executable: executable)
        } catch {
            return .failed(Self.launchFailure(error))
        }
        let process = launch.process
        let deadline = ScriptDeadline(limit: timeLimit, sleep: sleep) {
            process.kill(.timedOut)
        }
        let driver = ScriptStreamDriver(
            window: ScriptStreamWindow(limit: streamWaitingLimit, byteLimit: streamWaitingByteLimit),
            input: launch.input,
            deadline: deadline
        )
        launch.input.write(frame: header)
        deadline.arm()
        let events = launch.readEvents { event in
            switch event {
            case .registered(let handlers):
                driver.registered(handlers: handlers)
            case .callFinished(let item):
                driver.finished(item: item)
            default:
                break
            }
        }
        let termination = Task {
            await launch.finished()
            let over = driver.over()
            return ScriptStreamTermination(reason: process.termination, item: over.item, abandoned: over.abandoned)
        }
        return ScriptStreamExecution(
            events: events,
            deliver: driver.deliver,
            closeSending: driver.closeSending,
            stop: driver.stop,
            end: driver.end,
            termination: { await termination.value },
            cancel: { process.kill(.cancelled) }
        )
    }
}

/// Carries out what a stream phase's window decides, under its lock, so writing an item and arming its time limit
/// can never be reordered against the call that finished before it. The helper's events reach it on their reading
/// thread, so the next item goes out without waiting for any actor.
final class ScriptStreamDriver: Sendable {
    private let window: Mutex<ScriptStreamWindow>
    private let input: ScriptInputPipe
    private let deadline: ScriptDeadline

    init(window: ScriptStreamWindow, input: ScriptInputPipe, deadline: ScriptDeadline) {
        self.window = Mutex(window)
        self.input = input
        self.deadline = deadline
    }

    func deliver(_ item: ScriptStreamItem) -> ScriptStreamDelivery {
        window.withLock { window in
            let (delivery, action) = window.deliver(item)
            perform(action)
            return delivery
        }
    }

    func registered(handlers: Int) {
        window.withLock { window in
            deadline.disarm()
            perform(window.registered(handlers: handlers))
        }
    }

    func finished(item: Int) {
        window.withLock { window in
            deadline.disarm()
            perform(window.finished(item: item))
        }
    }

    func stop() -> Int {
        window.withLock { window in
            let (dropped, action) = window.stop()
            perform(action)
            return dropped
        }
    }

    func end() {
        window.withLock { window in
            perform(window.end())
        }
    }

    func closeSending() {
        input.write(.sendingClosed)
    }

    /// The helper exited: what it had in hand, and how many items never reached it.
    func over() -> (item: Int?, abandoned: Int) {
        window.withLock { window in
            deadline.disarm()
            input.close()
            return window.over()
        }
    }

    private func perform(_ action: ScriptStreamWindow.Action) {
        switch action {
        case .none:
            break
        case .write(let item):
            deadline.arm()
            input.write(.item(item))
        case .closeInput:
            input.close()
        }
    }
}

/// The time limit on what the helper is doing now: its top level, or the call in hand. Armed only while it has work,
/// so a stream waiting for its next event is never killed for being quiet.
final class ScriptDeadline: Sendable {
    private struct State {
        /// Bumped by every arm and disarm, so a sleep that ends just as it's disarmed can't kill the next call early.
        var generation = 0
        var task: Task<Void, Never>?
    }

    private let state = Mutex(State())
    private let limit: Duration
    private let sleep: HelperScriptRunner.Sleep
    private let expire: @Sendable () -> Void

    init(limit: Duration, sleep: @escaping HelperScriptRunner.Sleep, expire: @escaping @Sendable () -> Void) {
        self.limit = limit
        self.sleep = sleep
        self.expire = expire
    }

    func arm() {
        state.withLock { state in
            state.task?.cancel()
            state.generation += 1
            let generation = state.generation
            state.task = Task { [self] in
                guard (try? await sleep(limit)) != nil, self.state.withLock({ $0.generation == generation }) else {
                    return
                }
                expire()
            }
        }
    }

    func disarm() {
        state.withLock { state in
            state.task?.cancel()
            state.task = nil
            state.generation += 1
        }
    }
}
