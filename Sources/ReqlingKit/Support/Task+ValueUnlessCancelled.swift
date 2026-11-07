import Synchronization

/// `task`'s value, or `nil` as soon as the task awaiting this is cancelled, leaving `task` running for anyone else
/// waiting on it. Awaiting `Task.value` can't itself be cancelled, so a caller waiting on a shared question (a trust
/// prompt) would otherwise be held until someone answered it.
func valueUnlessCancelled<T: Sendable>(of task: Task<T?, Never>) async -> T? {
    let gate = ResumeOnce<T?>()
    return await withTaskCancellationHandler {
        await withCheckedContinuation { continuation in
            gate.install(continuation)
            Task {
                gate.resume(await task.value)
            }
        }
    } onCancel: {
        gate.resume(nil)
    }
}

/// Resumes one continuation with the first value offered, whether that arrives before the continuation is installed
/// or after.
private final class ResumeOnce<T: Sendable>: Sendable {
    private enum State {
        case waiting(CheckedContinuation<T, Never>?)
        case early(T)
        case settled
    }

    private let state = Mutex(State.waiting(nil))

    func install(_ continuation: CheckedContinuation<T, Never>) {
        let early = state.withLock { state -> State? in
            guard case .early = state else {
                state = .waiting(continuation)
                return nil
            }
            defer { state = .settled }
            return state
        }
        if case .early(let value) = early {
            continuation.resume(returning: value)
        }
    }

    func resume(_ value: T) {
        let continuation = state.withLock { state -> CheckedContinuation<T, Never>? in
            switch state {
            case .waiting(let continuation?):
                state = .settled
                return continuation
            case .waiting(nil):
                state = .early(value)
                return nil
            case .early, .settled:
                return nil
            }
        }
        continuation?.resume(returning: value)
    }
}
