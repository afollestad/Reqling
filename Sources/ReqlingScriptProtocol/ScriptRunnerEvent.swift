import ReqlingTemplating

/// What the helper reports as a phase runs, one frame each, written the moment it happens: a value a script sets
/// before it throws, or before the helper is killed at its time limit, still reaches Reqling.
public enum ScriptRunnerEvent: Hashable, Sendable, Codable {
    case levelStarted(level: Int)
    /// A `set` or `unset`, its secret flag already settled (`VariableLayers.apply`).
    case variable(VariableWrite)
    /// A pre-request script's change to a header or query parameter for this run.
    case request(ScriptRequestChange)
    /// A cookie a script set or removed, in either phase, already checked (`ScriptCookieSetting`).
    case cookie(ScriptCookieWrite)
    case console(level: Int, severity: ScriptConsoleSeverity, text: String)
    case test(level: Int, name: String, result: ScriptTestResult, message: String?)
    /// The level threw, or a timer or promise it started did, or its promise never settled.
    case levelFailed(level: Int, error: ScriptError)
    case levelFinished(level: Int)
    /// A script asked to skip the request, or named what a folder or project run does next. Written only when that
    /// changes, so a loop calling it writes once.
    case flow(ScriptFlowRequest)
    /// Every level ran; the helper exits next.
    case done
}

/// What `rq.execution` asks of the run.
public enum ScriptFlowRequest: Hashable, Sendable, Codable {
    /// Don't send the request; only a pre-request script can ask.
    case skipRequest
    /// The request a folder or project run runs next, by name or ID; `nil` ends the iteration.
    case setNextRequest(String?)
}

/// One change a pre-request script makes to a header (or gRPC metadata entry) or query parameter.
public struct ScriptRequestChange: Hashable, Sendable, Codable {
    public enum Operation: String, Hashable, Sendable, Codable {
        /// Replaces the first entry with the name, dropping any others, or adds one.
        case upsert
        case add
        /// Drops every entry with the name.
        case remove
    }

    public enum Target: String, Hashable, Sendable, Codable {
        case header
        case query
    }

    public var operation: Operation
    public var target: Target
    public var name: String
    /// `nil` for `remove`.
    public var value: String?

    public init(operation: Operation, target: Target, name: String, value: String?) {
        self.operation = operation
        self.target = target
        self.name = name
        self.value = value
    }

    /// Whether `candidate` names the same entry: headers ignore case, as HTTP does; query parameters don't.
    public func matches(_ candidate: String) -> Bool {
        target == .header ? candidate.caseInsensitiveCompare(name) == .orderedSame : candidate == name
    }
}

public enum ScriptConsoleSeverity: String, Hashable, Sendable, Codable, CaseIterable {
    case log
    case info
    case warn
    case error
    case debug
}

public enum ScriptTestResult: String, Hashable, Sendable, Codable {
    case passed
    case failed
    case skipped
}

/// Why a level failed, as JavaScript described it. `line` and `column` are in the script's own text.
public struct ScriptError: Error, Hashable, Sendable, Codable {
    public var name: String?
    public var message: String
    public var line: Int?
    public var column: Int?
    public var stack: String?

    public init(name: String? = nil, message: String, line: Int? = nil, column: Int? = nil, stack: String? = nil) {
        self.name = name
        self.message = message
        self.line = line
        self.column = column
        self.stack = stack
    }
}

extension ScriptRequestChange {
    /// Applies the change to rows of any shape, so the helper's view of the request and the request Reqling sends
    /// change alike.
    public func apply<Row>(
        to rows: inout [Row],
        name: (Row) -> String,
        setValue: (inout Row, String) -> Void,
        make: (String, String) -> Row
    ) {
        switch operation {
        case .add:
            rows.append(make(self.name, value ?? ""))
        case .remove:
            rows.removeAll { matches(name($0)) }
        case .upsert:
            guard let first = rows.firstIndex(where: { matches(name($0)) }) else {
                rows.append(make(self.name, value ?? ""))
                return
            }
            setValue(&rows[first], value ?? "")
            var index = rows.count - 1
            while index > first {
                if matches(name(rows[index])) {
                    rows.remove(at: index)
                }
                index -= 1
            }
        }
    }
}
