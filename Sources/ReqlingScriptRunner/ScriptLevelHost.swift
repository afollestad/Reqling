import Foundation
import JavaScriptCore
import ReqlingScriptProtocol

/// Runs one level's script in its own `JSContext`: evaluates the runtime, then the script wrapped in an async function
/// (`ScriptWrapper`), so top-level `await` and `return` work as in Postman, then drains its timers and the replies to
/// its requests until the script and everything it started have settled.
///
/// Microtasks need no driving here: JavaScriptCore runs them whenever a call from Swift into JavaScript returns, which
/// is after the script's evaluation, after every timer callback, and after each reply is handed over. A level is done
/// once its script settled and no test or request is pending; timers still waiting then are dropped, as a script that
/// wants them awaits them. A pending request keeps it going, though, as Postman's callback form never awaits one.
///
/// In a stream phase the host outlives its top level: `handle` calls the handlers it registered with each item, and
/// drains the same way, so each call ends once its handlers settle, its timers dropped too.
final class ScriptLevelHost {
    let index: Int
    let level: ScriptLevelSource
    let context: JSContext
    unowned let phase: ScriptPhaseRunner
    let timers = ScriptTimers()
    /// Where the script's own frames point in stack traces, telling them from the runtime's.
    let sourceURL: URL
    /// An exception nothing caught: a syntax error, or a throw in a timer callback.
    private var uncaught: ScriptError?
    /// Set when the script's promise settles, or a handler call's: `.success` or why it failed.
    private var settlement: Result<Void, ScriptError>?
    /// The first handler that failed in the call in hand.
    private var callError: ScriptError?
    /// The level's requests still out (`ScriptPhaseRunner.fetch`).
    private var pendingFetches: Set<Int> = []
    /// Each answered request's body, which its response decodes only when a script reads it. Kept as long as the level:
    /// a stream script's top level may keep a response its handlers read later.
    private var fetchBodies: [Int: Data] = [:]

    init(index: Int, level: ScriptLevelSource, context: JSContext, phase: ScriptPhaseRunner) {
        self.index = index
        self.level = level
        self.context = context
        self.phase = phase
        sourceURL = URL(string: "reqling:///" + (level.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "script.js"))
            ?? URL(fileURLWithPath: "/script.js")
    }

    /// Why the level failed, or `nil` when its script and tests all finished.
    func run() -> ScriptError? {
        context.exceptionHandler = { [unowned self] _, exception in
            if uncaught == nil, let exception {
                uncaught = scriptError(from: exception)
            }
        }
        installNatives()
        for (name, source) in phase.runtime.sources {
            context.evaluateScript(source, withSourceURL: URL(string: "reqling-runtime:///\(name)"))
            if let failure = uncaught {
                return ScriptError(name: "Error", message: "Reqling's script runtime failed to load: \(failure.message)")
            }
        }
        context.evaluateScript(ScriptWrapper.wrap(level.source), withSourceURL: sourceURL)
        let failure = drain(neverFinished: "The script awaited something that never finished.")
        timers.removeAll()
        forgetPendingFetches()
        // Handlers register only here: one registered from a handler would run on some items and not others.
        runtimeCall("closeRegistration")
        return failure
    }

    /// How many handlers the level's stream script registered.
    var handlerCount: Int {
        Int(runtimeCall("handlerCount", ["event"])?.toInt32() ?? 0) + Int(runtimeCall("handlerCount", ["message"])?.toInt32() ?? 0)
    }

    /// Whether the level has a handler for `item`.
    func handles(_ item: ScriptStreamItem) -> Bool {
        (runtimeCall("handlerCount", [Self.handlerKind(of: item)])?.toInt32() ?? 0) > 0
    }

    /// Calls the level's handlers for `item`, in the order they registered, each awaited before the next; the first
    /// that threw or rejected, or why the call never finished.
    func handle(_ item: ScriptStreamItem) -> ScriptError? {
        uncaught = nil
        settlement = nil
        callError = nil
        runtimeCall("runCall", [Self.handlerKind(of: item), Self.description(of: item)])
        let failure = drain(neverFinished: "A handler awaited something that never finished.")
        timers.removeAll()
        forgetPendingFetches()
        return failure ?? callError
    }

    func handlerFailed(_ error: JSValue) {
        if callError == nil {
            callError = scriptError(from: error)
        }
    }

    /// Which handlers take `item`, as the runtime lists them: `rq.onEvent`'s or `rq.onMessage`'s.
    private static func handlerKind(of item: ScriptStreamItem) -> String {
        if case .event = item.content {
            return "event"
        }
        return "message"
    }

    /// What `runtime.js` builds the handlers' argument from, keyed by `shape`; absent values are `null`.
    private static func description(of item: ScriptStreamItem) -> [String: Any] {
        switch item.content {
        case .event(let event):
            [
                "shape": "event", "id": ScriptResponseAccess.nullable(event.id), "event": ScriptResponseAccess.nullable(event.event),
                "data": event.data, "retry": ScriptResponseAccess.nullable(event.retry)
            ]
        case .socketMessage(let message):
            [
                "shape": "socket", "direction": message.direction, "text": ScriptResponseAccess.nullable(message.text),
                "base64": ScriptResponseAccess.nullable(message.base64)
            ]
        case .grpcMessage(let json):
            ["shape": "grpc", "json": json]
        }
    }

    @discardableResult
    private func runtimeCall(_ name: String, _ arguments: [Any] = []) -> JSValue? {
        context.objectForKeyedSubscript("__rq")?.invokeMethod(name, withArguments: arguments)
    }

    /// Fires timers and hands over replies until the level or call is done, or until nothing is left that could
    /// finish it.
    private func drain(neverFinished: String) -> ScriptError? {
        while true {
            if let uncaught {
                abandonPendingTests()
                return uncaught
            }
            if let settlement, pendingTestCount == 0, pendingFetches.isEmpty {
                return settlement.failure
            }
            let next = timers.next()
            guard next != nil || !pendingFetches.isEmpty else {
                abandonPendingTests()
                return settlement.map(\.failure) ?? ScriptError(name: "Error", message: neverFinished)
            }
            if pendingFetches.isEmpty, let next {
                let wait = next.dueAt - ScriptTimers.now
                if wait > 0 {
                    Thread.sleep(forTimeInterval: wait)
                }
                timers.fire(next.id)
                continue
            }
            if !receiveReplies(waitingUntil: next?.dueAt), let next, next.dueAt <= ScriptTimers.now {
                timers.fire(next.id)
            }
        }
    }

    /// Waits for replies until `deadline`, when the next timer is due, and hands over what arrived; false when none did
    /// by then. Once the input has closed, every request still out fails, as no reply can come.
    private func receiveReplies(waitingUntil deadline: TimeInterval?) -> Bool {
        let replies = phase.inbox.takeReplies(waitingUntil: deadline)
        if !replies.isEmpty {
            // After a callback throws, the level is over: what else arrived stays unanswered, as a later timer does.
            for reply in replies where uncaught == nil {
                receive(reply)
            }
            return true
        }
        guard phase.inbox.isClosed else {
            return false
        }
        for id in pendingFetches.sorted() {
            phase.fetchSettled(id, jar: nil)
            finishFetch(id, response: NSNull(), error: "Reqling stopped answering the script's requests.")
        }
        return true
    }

    /// Starts waiting on a request the level sent.
    func expectFetch(_ id: Int) {
        pendingFetches.insert(id)
    }

    /// The body of an answered request; empty for one the level never got.
    func fetchBody(_ id: Int) -> Data {
        fetchBodies[id] ?? Data()
    }

    /// Hands a reply to the script that waits on it. The cookies it carries land first, so the script's next read
    /// already sees what the response stored.
    private func receive(_ reply: ScriptInbox.Reply) {
        guard pendingFetches.contains(reply.reply.id) else {
            return
        }
        phase.fetchSettled(reply.reply.id, jar: reply.reply.cookies)
        switch reply.reply.outcome {
        case .response(let response):
            fetchBodies[reply.reply.id] = reply.body
            finishFetch(reply.reply.id, response: Self.description(of: response), error: NSNull())
        case .failed(let message):
            finishFetch(reply.reply.id, response: NSNull(), error: message)
        }
    }

    /// Settles the request in the runtime: its promise, or a Postman callback, which runs inside this call, so one that
    /// throws fails the level as a timer callback that throws does.
    private func finishFetch(_ id: Int, response: Any, error: Any) {
        pendingFetches.remove(id)
        runtimeCall("finishFetch", [id, response, error])
    }

    /// Drops what a level or call left out when it ended, such as on an uncaught throw: their replies have no one to
    /// answer.
    private func forgetPendingFetches() {
        guard !pendingFetches.isEmpty else {
            return
        }
        phase.inbox.forget(pendingFetches)
        for id in pendingFetches {
            phase.fetchSettled(id, jar: nil)
        }
        runtimeCall("forgetFetches", [Array(pendingFetches)])
        pendingFetches.removeAll()
    }

    /// What `runtime.js` builds a request's `IncomingResponse` from.
    private static func description(of response: ScriptHTTPResponse) -> [String: Any] {
        [
            "code": response.code, "status": response.status, "headers": ScriptResponseAccess.rows(response.headers),
            "size": response.size, "truncated": response.truncated, "responseTime": response.responseTime
        ]
    }

    func settle(_ error: JSValue) {
        guard settlement == nil else {
            return
        }
        settlement = error.isUndefined ? .success(()) : .failure(scriptError(from: error))
    }

    private var pendingTestCount: Int {
        Int(runtimeCall("pendingTestCount")?.toInt32() ?? 0)
    }

    /// Fails each test still waiting on a promise, so a level that ends early never drops one silently.
    private func abandonPendingTests() {
        runtimeCall("abandonPendingTests")
    }

    /// An error from JavaScript, located in the script's own text: the first stack frame in the script, or the error's
    /// own line when it was thrown there (a syntax error has no stack). A throw from the runtime itself, such as an
    /// unsupported call, so points at the line in the script that made the call.
    func scriptError(from value: JSValue) -> ScriptError {
        guard value.isObject else {
            return ScriptError(name: nil, message: value.toString() ?? "An error was thrown.")
        }
        let name = string(value, "name")
        let message = string(value, "message") ?? value.toString() ?? "An error was thrown."
        // A runaway recursion's stack has thousands of frames; a few dozen locate it.
        let stack = string(value, "stack").map { ScriptReporter.trimmed($0, to: 4_096) }
        var location = stack.flatMap(scriptLocation(inStack:))
        if location == nil, string(value, "sourceURL") == sourceURL.absoluteString,
           let line = int(value, "line") {
            location = (line, int(value, "column"))
        }
        return ScriptError(
            name: name,
            message: message,
            line: location?.line,
            column: location.flatMap { location in location.column.map { ScriptWrapper.column($0, line: location.line) } },
            stack: stack
        )
    }

    /// The line and column of the first frame in `stack` that is in the script.
    private func scriptLocation(inStack stack: String) -> (line: Int, column: Int?)? {
        let prefix = sourceURL.absoluteString + ":"
        for frame in stack.split(separator: "\n") {
            guard let range = frame.range(of: prefix) else {
                continue
            }
            let numbers = frame[range.upperBound...].split(separator: ":").compactMap { Int($0) }
            if let line = numbers.first {
                return (line, numbers.dropFirst().first)
            }
        }
        return nil
    }

    private func string(_ value: JSValue, _ key: String) -> String? {
        guard let property = value.objectForKeyedSubscript(key), !property.isUndefined, !property.isNull else {
            return nil
        }
        return property.toString()
    }

    private func int(_ value: JSValue, _ key: String) -> Int? {
        guard let property = value.objectForKeyedSubscript(key), property.isNumber else {
            return nil
        }
        return Int(property.toInt32())
    }
}

private extension Result where Failure == ScriptError {
    var failure: ScriptError? {
        if case .failure(let error) = self {
            return error
        }
        return nil
    }
}
