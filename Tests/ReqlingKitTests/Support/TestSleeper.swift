import Foundation
import Synchronization

/// A sleep the test controls, for code that takes an injected one: each call is recorded, then returns at once or
/// waits for `wake()`, and throws once its task is cancelled either way.
final class TestSleeper: Sendable {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct State {
        var requested: [Duration] = []
        var waiters: [Waiter] = []
    }

    /// Whether sleeps return at once, rather than waiting for `wake()`.
    let returnsAtOnce: Bool
    /// Each duration as it is asked for, so a test can wait for a sleep to start: one that waits is announced only
    /// once `wake()` would end it.
    let requests: AsyncStream<Duration>
    private let requested: AsyncStream<Duration>.Continuation
    private let state = Mutex(State())

    init(returnsAtOnce: Bool) {
        self.returnsAtOnce = returnsAtOnce
        (requests, requested) = AsyncStream.makeStream()
    }

    /// Every duration asked for, in order.
    var durations: [Duration] {
        state.withLock { $0.requested }
    }

    func sleep(_ duration: Duration) async throws {
        state.withLock { $0.requested.append(duration) }
        guard !returnsAtOnce else {
            requested.yield(duration)
            try Task.checkCancellation()
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                // Checked under the lock, so a cancel that lands before the waiter is added still ends it.
                let isCancelled = state.withLock { state in
                    if !Task.isCancelled {
                        state.waiters.append(Waiter(id: id, continuation: continuation))
                    }
                    return Task.isCancelled
                }
                if isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    requested.yield(duration)
                }
            }
        } onCancel: {
            let waiter = state.withLock { state in
                state.waiters.firstIndex { $0.id == id }.map { state.waiters.remove(at: $0) }
            }
            waiter?.continuation.resume(throwing: CancellationError())
        }
    }

    /// Ends every sleep waiting now.
    func wake() {
        let waiters = state.withLock { state in
            defer { state.waiters = [] }
            return state.waiters
        }
        for waiter in waiters {
            waiter.continuation.resume()
        }
    }
}
