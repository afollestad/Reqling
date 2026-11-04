import Foundation
@testable import ReqlingKit
import Synchronization
import XCTest

/// A sleep that returns only when the test calls `advance()`, and throws when its task is cancelled, so debounce
/// tests control time without a clock.
final class ManualSleeper: Sendable {
    private struct State {
        var pending: [UUID: CheckedContinuation<Void, any Error>] = [:]
        var cancelledBeforeStart: Set<UUID> = []
        var cancelled = 0
        var onStart: [XCTestExpectation] = []
        var onEverySleep: (@Sendable () -> Void)?
    }

    private let state = Mutex(State())

    /// What a starting sleep must do once outside the lock.
    private struct Start {
        var cancelled = false
        var expectation: XCTestExpectation?
        var action: (@Sendable () -> Void)?
    }

    /// Fulfills `expectation` when the next sleep begins.
    func expectSleep(_ expectation: XCTestExpectation) {
        state.withLock { $0.onStart.append(expectation) }
    }

    /// Runs `action` as each later sleep begins, until set to `nil`.
    func onEverySleep(_ action: (@Sendable () -> Void)?) {
        state.withLock { $0.onEverySleep = action }
    }

    /// Ends every pending sleep.
    func advance() {
        let continuations = state.withLock { state in
            defer { state.pending.removeAll() }
            return Array(state.pending.values)
        }
        continuations.forEach { $0.resume() }
    }

    var cancelledCount: Int {
        state.withLock { $0.cancelled }
    }

    func sleep(_: Duration) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let start = state.withLock { state -> Start in
                    if state.cancelledBeforeStart.remove(id) != nil {
                        return Start(cancelled: true)
                    }
                    state.pending[id] = continuation
                    return Start(expectation: state.onStart.isEmpty ? nil : state.onStart.removeFirst(), action: state.onEverySleep)
                }
                if start.cancelled {
                    continuation.resume(throwing: CancellationError())
                }
                start.expectation?.fulfill()
                start.action?()
            }
        } onCancel: {
            let continuation = state.withLock { state in
                state.cancelled += 1
                guard let continuation = state.pending.removeValue(forKey: id) else {
                    state.cancelledBeforeStart.insert(id)
                    return CheckedContinuation<Void, any Error>?.none
                }
                return continuation
            }
            continuation?.resume(throwing: CancellationError())
        }
    }
}

/// Hands out change streams the test feeds by hand, recording what each workspace asked to watch.
@MainActor
final class ChangeFeed {
    private(set) var watched: [[URL]] = []
    private var continuations: [AsyncStream<Void>.Continuation] = []
    /// A class, so the `@Sendable` termination handler can share it; a bare `Mutex` cannot be captured.
    private final class Counter: Sendable {
        let value = Mutex(0)
    }

    private let terminations = Counter()

    func stream(watching urls: [URL]) -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self)
        continuation.onTermination = { [terminations] _ in
            terminations.value.withLock { $0 += 1 }
        }
        watched.append(urls)
        continuations.append(continuation)
        return stream
    }

    /// Reports a change on the newest stream.
    func send() {
        continuations.last?.yield()
    }

    var terminationCount: Int {
        terminations.value.withLock { $0 }
    }
}
