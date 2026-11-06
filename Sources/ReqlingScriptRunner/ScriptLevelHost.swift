import Foundation
import JavaScriptCore
import ReqlingScriptProtocol

/// Runs one level's script in its own `JSContext`: evaluates the runtime, then the script wrapped in an async function
/// (`wrapperPrefix`), so top-level `await` and `return` work as in Postman, then drains its timers until the script
/// and every test it started have settled.
///
/// Microtasks need no driving here: JavaScriptCore runs them whenever a call from Swift into JavaScript returns, which
/// is after the script's evaluation and after every timer callback. A level is done once its script settled and no
/// test is pending; timers still waiting then are dropped, as a script that wants them awaits them.
final class ScriptLevelHost {
    /// On the script's first line, so line numbers stay the script's own; only line 1's columns shift by its length.
    static let wrapperPrefix = "__rq.runLevel(async function () {"

    let index: Int
    let level: ScriptLevelSource
    let context: JSContext
    unowned let phase: ScriptPhaseRunner
    let timers = ScriptTimers()
    /// Where the script's own frames point in stack traces, telling them from the runtime's.
    let sourceURL: URL
    /// An exception nothing caught: a syntax error, or a throw in a timer callback.
    private var uncaught: ScriptError?
    /// Set when the script's promise settles: `.success` or why it failed.
    private var settlement: Result<Void, ScriptError>?

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
        context.evaluateScript(Self.wrapperPrefix + level.source + "\n})", withSourceURL: sourceURL)
        let failure = drain()
        timers.removeAll()
        return failure
    }

    /// Fires timers until the level is done, or until nothing is left that could finish it.
    private func drain() -> ScriptError? {
        while true {
            if let uncaught {
                abandonPendingTests()
                return uncaught
            }
            if let settlement, pendingTestCount == 0 {
                return settlement.failure
            }
            guard let next = timers.next() else {
                abandonPendingTests()
                return settlement.map(\.failure) ?? ScriptError(
                    name: "Error",
                    message: "The script awaited something that never finished."
                )
            }
            let wait = next.dueAt - ScriptTimers.now
            if wait > 0 {
                Thread.sleep(forTimeInterval: wait)
            }
            timers.fire(next.id)
        }
    }

    func settle(_ error: JSValue) {
        guard settlement == nil else {
            return
        }
        settlement = error.isUndefined ? .success(()) : .failure(scriptError(from: error))
    }

    private var pendingTestCount: Int {
        Int(context.objectForKeyedSubscript("__rq")?.invokeMethod("pendingTestCount", withArguments: [])?.toInt32() ?? 0)
    }

    /// Fails each test still waiting on a promise, so a level that ends early never drops one silently.
    private func abandonPendingTests() {
        context.objectForKeyedSubscript("__rq")?.invokeMethod("abandonPendingTests", withArguments: [])
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
            column: location.flatMap { location in location.column.map { location.line == 1 ? max(1, $0 - Self.wrapperPrefix.count) : $0 } },
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
