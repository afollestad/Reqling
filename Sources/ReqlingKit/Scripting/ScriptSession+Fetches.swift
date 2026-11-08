import Foundation
import ReqlingScriptProtocol

/// The requests a run's scripts send (`rq.sendRequest`, `rq.runRequest`). Each `ScriptRunnerEvent.fetch` joins its
/// phase's `ScriptFetchQueue`, which sends it through the performer `RequestRunner` gives the session
/// (`RequestRunner+ScriptFetches.swift`), at most `fetchConcurrency` at once, then logs its line in the console and
/// replies to the helper with the response and the jar as the scripts should now see it.
///
/// The helper's time limit keeps running while a request is out. A level, or a stream's call, waits for its requests
/// unless it ends early, as on an uncaught throw: what it left out is cancelled once the helper says it ended. What's
/// still out when the phase ends, killed at its limit or not, is cancelled too. The console notes each.
extension ScriptSession {
    /// How many of a phase's requests are out at once; the rest wait their turn, so a script sending a hundred never
    /// holds a hundred bodies in Reqling at once.
    static let fetchConcurrency = 6

    /// A queue for one phase's requests, replying through `reply` after logging each one's line through `log`.
    func fetchQueue(reply: @escaping ScriptFetchReplying, log: @escaping @MainActor (ScriptConsoleEntry) -> Void) -> ScriptFetchQueue {
        ScriptFetchQueue(
            limit: Self.fetchConcurrency,
            perform: { [weak self] fetch in
                guard let self, let fetchPerformer else {
                    return ScriptFetchCompletion(outcome: .failed("Reqling can't send this script's requests."))
                }
                return await fetchPerformer(fetch, self)
            },
            finish: { [weak self] pending, completion in
                guard let self else {
                    return
                }
                log(Self.line(for: pending, completion))
                reply(ScriptFetchReply(id: pending.id, outcome: completion.outcome, cookies: scriptsJar()), completion.body)
            }
        )
    }

    /// Cancels what a level or stream call left out when it ended, noting each.
    func endFetches(_ queue: ScriptFetchQueue, group: Int, log: (ScriptConsoleEntry) -> Void) {
        queue.end(group).forEach { log(Self.unfinished($0)) }
    }

    /// Ends a phase's requests, noting each that never finished.
    func closeFetches(_ queue: ScriptFetchQueue, log: (ScriptConsoleEntry) -> Void) {
        queue.close().forEach { log(Self.unfinished($0)) }
    }

    private static func unfinished(_ pending: ScriptFetchQueue.Pending) -> ScriptConsoleEntry {
        ScriptConsoleEntry(level: pending.level, severity: .warn, text: "→ \(label(of: pending.fetch)) didn't finish before its script ended.")
    }

    /// The project's jar as the scripts should now see it (`ScriptFetchReply.cookies`).
    func scriptsJar() -> [ScriptCookie] {
        scriptsCookieJar()?.cookies(in: nil) ?? []
    }

    /// The project's jar with the changes scripts reported that `commit` hasn't applied yet on top, in a copy when
    /// there are any. A preview's never are applied, so its scripts see theirs while the real jar never takes them.
    func scriptsCookieJar() -> ProjectCookieJar? {
        let held = projectCookieJar
        guard !pendingCookieWrites.isEmpty, let storage = URLSessionConfiguration.ephemeral.httpCookieStorage else {
            return held
        }
        for cookie in held?.cookies(in: nil) ?? [] {
            if let stored = cookie.httpCookie {
                storage.setCookie(stored)
            }
        }
        let copy = ProjectCookieJar(storage: storage)
        copy.apply(pendingCookieWrites)
        return copy
    }

    /// One request's line: what went out, then its status and time, or why nothing came back.
    static func line(for pending: ScriptFetchQueue.Pending, _ completion: ScriptFetchCompletion) -> ScriptConsoleEntry {
        let label = completion.sent ?? label(of: pending.fetch)
        switch completion.outcome {
        case .response(let response):
            let status = [String(response.code), response.status].filter { !$0.isEmpty }.joined(separator: " ")
            let time = Int(response.responseTime.rounded())
            return ScriptConsoleEntry(level: pending.level, severity: .info, text: "→ \(label) · \(status) · \(time) ms")
        case .failed(let message):
            return ScriptConsoleEntry(level: pending.level, severity: .error, text: "→ \(label) failed: \(message)")
        }
    }

    /// A request as the script named it, for a line about one Reqling never built.
    static func label(of fetch: ScriptFetch) -> String {
        switch fetch {
        case .send(let request): "\(request.method) \(request.url)"
        case .run(let request, _): "“\(request)”"
        }
    }
}

/// Sends a request a script asked for, as the session stands when it starts.
typealias ScriptFetchPerformer = @MainActor (ScriptFetch, ScriptSession) async -> ScriptFetchCompletion

/// What became of one request a script sent.
struct ScriptFetchCompletion: Sendable {
    /// What went out, as its line names it, secrets masked: `POST https://…`, or `“Login” POST https://…`; `nil`
    /// when nothing was built, and the line names the request as the script did.
    var sent: String?
    var outcome: ScriptFetchReply.Outcome
    /// A response's body, as cut for the scripts.
    var body = Data()
}

/// One phase's requests in flight, started in the order they were sent, at most `limit` at once. Closing it cancels
/// what's out, so a request finishing after its phase ended replies to no one.
@MainActor
final class ScriptFetchQueue {
    struct Pending {
        let id: Int
        let level: Int
        let fetch: ScriptFetch
        /// What ends it: its level in a one-shot phase, or in a stream phase the item whose call sent it, or
        /// `topLevel`.
        let group: Int
    }

    /// A stream phase's top level's group.
    static let topLevel = -1

    private let limit: Int
    private let perform: @MainActor (ScriptFetch) async -> ScriptFetchCompletion
    private let finish: @MainActor (Pending, ScriptFetchCompletion) -> Void
    private var running: [Int: (pending: Pending, task: Task<Void, Never>)] = [:]
    private var waiting: [Pending] = []
    private var isClosed = false

    init(
        limit: Int,
        perform: @escaping @MainActor (ScriptFetch) async -> ScriptFetchCompletion,
        finish: @escaping @MainActor (Pending, ScriptFetchCompletion) -> Void
    ) {
        self.limit = limit
        self.perform = perform
        self.finish = finish
    }

    func add(_ pending: Pending) {
        guard !isClosed else {
            return
        }
        waiting.append(pending)
        startWaiting()
    }

    /// Cancels what `group` has out and drops what it has waiting, as the helper no longer waits on them; returns
    /// both, in the order they were sent.
    func end(_ group: Int) -> [Pending] {
        let ended = (running.values.map(\.pending) + waiting).filter { $0.group == group }.sorted { $0.id < $1.id }
        for pending in ended {
            running.removeValue(forKey: pending.id)?.task.cancel()
        }
        waiting.removeAll { $0.group == group }
        startWaiting()
        return ended
    }

    /// Cancels what's out and drops what waits; returns both, in the order they were sent.
    func close() -> [Pending] {
        isClosed = true
        let unfinished = (running.values.map(\.pending) + waiting).sorted { $0.id < $1.id }
        for entry in running.values {
            entry.task.cancel()
        }
        running.removeAll()
        waiting.removeAll()
        return unfinished
    }

    private func startWaiting() {
        while running.count < limit, !waiting.isEmpty {
            let next = waiting.removeFirst()
            let perform = perform
            running[next.id] = (next, Task { [weak self] in
                let completion = await perform(next.fetch)
                self?.completed(next, completion)
            })
        }
    }

    private func completed(_ pending: Pending, _ completion: ScriptFetchCompletion) {
        guard !isClosed, running.removeValue(forKey: pending.id) != nil else {
            return
        }
        finish(pending, completion)
        startWaiting()
    }
}
