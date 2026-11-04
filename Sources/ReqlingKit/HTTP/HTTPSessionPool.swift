import Foundation
import Synchronization

/// One executor's sessions, one per TLS policy (server verification on or off), all sharing one cookie jar.
///
/// A request leases its session for its whole life. Invalidating a session between handing it out and creating the
/// task raises `NSGenericException` ("Task created in a session that has been invalidated") and aborts the app, so a
/// session replaced (its policy's fingerprint changed) or retired by `invalidate()` closes only when its last lease
/// ends. After `invalidate()`, nothing is leased: a new session would keep a forgotten project's cookie jar alive.
final class HTTPSessionPool: Sendable {
    private struct Entry {
        let session: URLSession
        let fingerprint: Data
        var leases = 0
        /// Replaced or invalidated; it closes when `leases` reaches zero.
        var isRetired = false
        /// Retired by `invalidate()`, so closing cancels instead of letting requests finish.
        var cancelsOnClose = false
    }

    private struct State {
        var entries: [ObjectIdentifier: Entry] = [:]
        /// The session currently handed out for each policy, keyed by whether the server is verified.
        var current: [Bool: ObjectIdentifier] = [:]
        var isInvalidated = false
    }

    private let makeConfiguration: @Sendable () -> URLSessionConfiguration
    private let cookies: HTTPCookieStorage?
    private let state = Mutex(State())

    init(configuration: @escaping @Sendable () -> URLSessionConfiguration) {
        makeConfiguration = configuration
        cookies = configuration().httpCookieStorage
    }

    var isInvalidated: Bool {
        state.withLock { $0.isInvalidated }
    }

    /// The session for a policy, leased until `release`; `nil` once the pool is invalidated.
    func lease(verifiesServer: Bool, fingerprint: Data) -> URLSession? {
        let (leased, replaced) = state.withLock { state -> (URLSession?, URLSession?) in
            guard !state.isInvalidated else {
                return (nil, nil)
            }
            var replaced: URLSession?
            if let id = state.current[verifiesServer], var entry = state.entries[id] {
                if entry.fingerprint == fingerprint {
                    entry.leases += 1
                    state.entries[id] = entry
                    return (entry.session, nil)
                }
                entry.isRetired = true
                if entry.leases == 0 {
                    state.entries[id] = nil
                    replaced = entry.session
                } else {
                    state.entries[id] = entry
                }
            }
            let configuration = makeConfiguration()
            configuration.httpCookieStorage = cookies
            let session = URLSession(configuration: configuration)
            state.entries[ObjectIdentifier(session)] = Entry(session: session, fingerprint: fingerprint, leases: 1)
            state.current[verifiesServer] = ObjectIdentifier(session)
            return (session, replaced)
        }
        replaced?.finishTasksAndInvalidate()
        return leased
    }

    func release(_ session: URLSession) {
        let closing = state.withLock { state -> Entry? in
            let id = ObjectIdentifier(session)
            guard var entry = state.entries[id] else {
                return nil
            }
            entry.leases -= 1
            guard entry.leases == 0, entry.isRetired else {
                state.entries[id] = entry
                return nil
            }
            state.entries[id] = nil
            return entry
        }
        guard let closing else {
            return
        }
        if closing.cancelsOnClose {
            closing.session.invalidateAndCancel()
        } else {
            closing.session.finishTasksAndInvalidate()
        }
    }

    /// Cancels every request and closes every session. Busy sessions cancel their tasks now and close on their last
    /// release; a task created after this cancels itself through `isInvalidated` (see `ExchangeDelegate`).
    func invalidate() {
        let (idle, busy) = state.withLock { state -> ([URLSession], [URLSession]) in
            state.isInvalidated = true
            state.current = [:]
            var idle: [URLSession] = []
            var busy: [URLSession] = []
            for (id, var entry) in state.entries {
                if entry.leases == 0 {
                    state.entries[id] = nil
                    idle.append(entry.session)
                } else {
                    entry.isRetired = true
                    entry.cancelsOnClose = true
                    state.entries[id] = entry
                    busy.append(entry.session)
                }
            }
            return (idle, busy)
        }
        for session in idle {
            session.invalidateAndCancel()
        }
        for session in busy {
            session.getAllTasks { tasks in
                for task in tasks {
                    task.cancel()
                }
            }
        }
    }
}
