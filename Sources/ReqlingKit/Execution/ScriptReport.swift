import ReqlingScriptProtocol
import ReqlingTemplating

/// What a run's scripts did: each phase's tests, console, and errors, already masked, for the response pane, the run
/// history, and MCP. Variable and cookie changes are listed without their values, so neither a secret, a session
/// cookie, nor a stashed body reaches the history.
public struct ScriptReport: Hashable, Sendable, Codable {
    public var phases: [ScriptPhaseReport]

    public init(phases: [ScriptPhaseReport] = []) {
        self.phases = phases
    }

    public func phase(_ phase: ScriptPhase) -> ScriptPhaseReport? {
        phases.first { $0.phase == phase }
    }

    public var testCounts: ScriptTestCounts {
        var counts = ScriptTestCounts()
        for test in phases.flatMap(\.levels).flatMap(\.tests) {
            switch test.result {
            case .passed: counts.passed += 1
            case .failed: counts.failed += 1
            case .skipped: counts.skipped += 1
            }
        }
        return counts
    }

    /// A failed test, or a script that threw, timed out, or couldn't run. Scripts that didn't run because the project
    /// isn't trusted, or the request failed, are no failure of the scripts.
    public var hasFailures: Bool {
        phases.contains(where: \.hasFailures)
    }

    /// Whether any phase ran or meant to, which decides whether there is anything to show.
    public var isEmpty: Bool {
        phases.isEmpty
    }

    /// A script made a value secret for the run alone (`rq.variables`), which nothing keeps once the run ends.
    public var madeRunLocalSecrets: Bool {
        phases.contains { phase in
            phase.variableChanges.contains { $0.scope == .local && $0.isSecret && !$0.isUnset }
        }
    }
}

public struct ScriptTestCounts: Hashable, Sendable, Codable {
    public var passed = 0
    public var failed = 0
    public var skipped = 0

    public init(passed: Int = 0, failed: Int = 0, skipped: Int = 0) {
        self.passed = passed
        self.failed = failed
        self.skipped = skipped
    }

    public var total: Int {
        passed + failed + skipped
    }
}

public struct ScriptPhaseReport: Hashable, Sendable, Codable {
    public var phase: ScriptPhase
    public var levels: [ScriptLevelReport]
    public var console: [ScriptConsoleEntry]
    /// The phase as a whole failed: it timed out, the runner crashed, or it couldn't start.
    public var error: ScriptError?
    /// Why the phase's scripts didn't run, when they didn't.
    public var skipReason: ScriptSkipReason?
    public var variableChanges: [ScriptVariableChange]
    public var cookieChanges: [ScriptCookieChange]
    /// Only the newest console entries were kept: by the history, or by a stream phase as it ran.
    public var isConsoleTruncated: Bool
    /// A stream phase's handling of what its stream received; `nil` for the other phases.
    public var stream: ScriptStreamReport?

    public init(
        phase: ScriptPhase,
        levels: [ScriptLevelReport] = [],
        console: [ScriptConsoleEntry] = [],
        error: ScriptError? = nil,
        skipReason: ScriptSkipReason? = nil,
        variableChanges: [ScriptVariableChange] = [],
        cookieChanges: [ScriptCookieChange] = [],
        isConsoleTruncated: Bool = false,
        stream: ScriptStreamReport? = nil
    ) {
        self.phase = phase
        self.levels = levels
        self.console = console
        self.error = error
        self.skipReason = skipReason
        self.variableChanges = variableChanges
        self.cookieChanges = cookieChanges
        self.isConsoleTruncated = isConsoleTruncated
        self.stream = stream
    }

    /// As the synthesized decoder would, except that `cookieChanges` may be missing: runs recorded before scripts could
    /// change cookies have none, and a run that fails to decode drops out of the history.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        phase = try container.decode(ScriptPhase.self, forKey: .phase)
        levels = try container.decode([ScriptLevelReport].self, forKey: .levels)
        console = try container.decode([ScriptConsoleEntry].self, forKey: .console)
        error = try container.decodeIfPresent(ScriptError.self, forKey: .error)
        skipReason = try container.decodeIfPresent(ScriptSkipReason.self, forKey: .skipReason)
        variableChanges = try container.decode([ScriptVariableChange].self, forKey: .variableChanges)
        cookieChanges = try container.decodeIfPresent([ScriptCookieChange].self, forKey: .cookieChanges) ?? []
        isConsoleTruncated = try container.decode(Bool.self, forKey: .isConsoleTruncated)
        stream = try container.decodeIfPresent(ScriptStreamReport.self, forKey: .stream)
    }

    public var hasFailures: Bool {
        error != nil || levels.contains { $0.error != nil || $0.tests.contains { $0.result == .failed } }
    }

    /// The first failure, as one line: which script, where, and what.
    public var failureSummary: String? {
        if let error {
            return error.message
        }
        guard let level = levels.first(where: { $0.error != nil }), let error = level.error else {
            return nil
        }
        let item = if let stream, let failed = level.failedItem { " on \(stream.itemKind.rawValue) \(failed)" } else { "" }
        let place = error.line.map { " at line \($0)" } ?? ""
        let name = error.name.map { "\($0): " } ?? ""
        return "The \(phase.title.lowercased()) script of \(level.title) failed\(item)\(place): \(name)\(error.message)"
    }
}

/// What a stream phase did with what its stream received, beyond its tests and console. An item that reached no
/// handler is counted by why, so the results can say.
public struct ScriptStreamReport: Hashable, Sendable, Codable {
    /// What the stream received, as results name it.
    public var itemKind: ScriptStreamItemKind
    /// Items handed to the handlers and finished with.
    public var handledCount: Int
    /// Items that reached no handler because the phase ended first: the stream was stopped or reached a bound, or the
    /// handlers stopped at `failedItem`.
    public var skippedCount: Int
    /// Items that reached no handler because the handlers fell behind, and the oldest waiting were dropped.
    public var droppedCount: Int
    /// The item a time limit or crash stopped the handlers on; nothing after it reached them.
    public var failedItem: Int?
    /// Reqling quit while the stream scripts ran.
    public var isInterrupted: Bool

    public init(
        itemKind: ScriptStreamItemKind,
        handledCount: Int = 0,
        skippedCount: Int = 0,
        droppedCount: Int = 0,
        failedItem: Int? = nil,
        isInterrupted: Bool = false
    ) {
        self.itemKind = itemKind
        self.handledCount = handledCount
        self.skippedCount = skippedCount
        self.droppedCount = droppedCount
        self.failedItem = failedItem
        self.isInterrupted = isInterrupted
    }
}

/// What a stream receives: an event stream's events, or a WebSocket's or gRPC call's messages. Its raw value is the
/// noun results use.
public enum ScriptStreamItemKind: String, Hashable, Sendable, Codable {
    case event
    case message
}

/// Why a phase's scripts didn't run.
public enum ScriptSkipReason: String, Hashable, Sendable, Codable {
    /// The project's scripts aren't trusted on this Mac.
    case untrusted
    /// The request failed, so there was no response to run post-response scripts on.
    case requestFailed
    /// Reqling quit before the phase could run or finish.
    case quit
    /// A pre-request script skipped the request, so there was no response.
    case requestSkipped

    public var message: String {
        switch self {
        case .untrusted: "Scripts are off for this project."
        case .requestFailed: "The request failed, so post-response scripts didn't run."
        case .requestSkipped: "A pre-request script skipped the request, so post-response scripts didn't run."
        case .quit: "Reqling quit before the post-response scripts finished."
        }
    }
}

public struct ScriptLevelReport: Hashable, Sendable, Codable {
    public var kind: ScriptLevelKind
    public var name: String
    public var tests: [ScriptTestReport]
    /// The level's error; in a stream phase, its first handler's that threw, on `failedItem`.
    public var error: ScriptError?
    /// The item a stream handler first threw on; `nil` when the error was the top level's.
    public var failedItem: Int?
    /// How many of a stream phase's calls the level's handlers threw in, `error`'s included.
    public var failedCallCount: Int?

    public init(
        kind: ScriptLevelKind,
        name: String,
        tests: [ScriptTestReport] = [],
        error: ScriptError? = nil,
        failedItem: Int? = nil,
        failedCallCount: Int? = nil
    ) {
        self.kind = kind
        self.name = name
        self.tests = tests
        self.error = error
        self.failedItem = failedItem
        self.failedCallCount = failedCallCount
    }

    /// As a sentence names it: `the project`, `folder “Users”`, `the request`.
    public var title: String {
        switch kind {
        case .project: "the project"
        case .folder: "folder “\(name)”"
        case .request: "the request"
        }
    }
}

/// One test's result. In a stream phase, every run of a test of one name in one level is one report: failed when any
/// run failed, carrying the first failure's message, so a stream's results stay one row per test however long it runs.
public struct ScriptTestReport: Hashable, Sendable, Codable {
    public var name: String
    public var result: ScriptTestResult
    public var message: String?
    /// How a stream phase's runs of the test went; `nil` outside one.
    public var tally: ScriptTestCounts?
    /// The item the test first failed on.
    public var firstFailedItem: Int?

    public init(name: String, result: ScriptTestResult, message: String? = nil, tally: ScriptTestCounts? = nil, firstFailedItem: Int? = nil) {
        self.name = name
        self.result = result
        self.message = message
        self.tally = tally
        self.firstFailedItem = firstFailedItem
    }
}

public struct ScriptConsoleEntry: Hashable, Sendable, Codable {
    /// The level's index in its phase's `levels`.
    public var level: Int
    public var severity: ScriptConsoleSeverity
    public var text: String

    public init(level: Int, severity: ScriptConsoleSeverity, text: String) {
        self.level = level
        self.severity = severity
        self.text = text
    }
}

/// A variable a script set or unset, without its value.
public struct ScriptVariableChange: Hashable, Sendable, Codable {
    public var scope: VariableWriteScope
    public var key: String
    public var isUnset: Bool
    public var isSecret: Bool

    public init(scope: VariableWriteScope, key: String, isUnset: Bool, isSecret: Bool) {
        self.scope = scope
        self.key = key
        self.isUnset = isUnset
        self.isSecret = isSecret
    }
}

/// A cookie a script set or removed, without its value, so a session token never reaches the history.
public struct ScriptCookieChange: Hashable, Sendable, Codable {
    public var name: String
    public var domain: String
    public var path: String
    public var isRemoved: Bool

    public init(name: String, domain: String, path: String, isRemoved: Bool) {
        self.name = name
        self.domain = domain
        self.path = path
        self.isRemoved = isRemoved
    }
}

extension ScriptPhase {
    /// As people write it: "Pre-request", "Stream", "Post-response".
    public var title: String {
        switch self {
        case .preRequest: "Pre-request"
        case .stream: "Stream"
        case .postResponse: "Post-response"
        }
    }
}
