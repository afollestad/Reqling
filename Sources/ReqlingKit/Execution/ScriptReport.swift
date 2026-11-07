import ReqlingScriptProtocol
import ReqlingTemplating

/// What a run's scripts did: each phase's tests, console, and errors, already masked, for the response pane, the run
/// history, and MCP. Variable changes are listed without their values, so neither a secret nor a stashed body reaches
/// the history.
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
    /// The history kept only the newest console entries.
    public var isConsoleTruncated: Bool

    public init(
        phase: ScriptPhase,
        levels: [ScriptLevelReport] = [],
        console: [ScriptConsoleEntry] = [],
        error: ScriptError? = nil,
        skipReason: ScriptSkipReason? = nil,
        variableChanges: [ScriptVariableChange] = [],
        isConsoleTruncated: Bool = false
    ) {
        self.phase = phase
        self.levels = levels
        self.console = console
        self.error = error
        self.skipReason = skipReason
        self.variableChanges = variableChanges
        self.isConsoleTruncated = isConsoleTruncated
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
        let place = error.line.map { " at line \($0)" } ?? ""
        let name = error.name.map { "\($0): " } ?? ""
        return "The \(phase.title.lowercased()) script of \(level.title) failed\(place): \(name)\(error.message)"
    }
}

/// Why a phase's scripts didn't run.
public enum ScriptSkipReason: String, Hashable, Sendable, Codable {
    /// The project's scripts aren't trusted on this Mac.
    case untrusted
    /// The request failed, so there was no response to run post-response scripts on.
    case requestFailed
    /// Reqling quit before the phase could run or finish.
    case quit

    public var message: String {
        switch self {
        case .untrusted: "Scripts are off for this project."
        case .requestFailed: "The request failed, so post-response scripts didn't run."
        case .quit: "Reqling quit before the post-response scripts finished."
        }
    }
}

public struct ScriptLevelReport: Hashable, Sendable, Codable {
    public var kind: ScriptLevelKind
    public var name: String
    public var tests: [ScriptTestReport]
    public var error: ScriptError?

    public init(kind: ScriptLevelKind, name: String, tests: [ScriptTestReport] = [], error: ScriptError? = nil) {
        self.kind = kind
        self.name = name
        self.tests = tests
        self.error = error
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

public struct ScriptTestReport: Hashable, Sendable, Codable {
    public var name: String
    public var result: ScriptTestResult
    public var message: String?

    public init(name: String, result: ScriptTestResult, message: String? = nil) {
        self.name = name
        self.result = result
        self.message = message
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

extension ScriptPhase {
    /// As people write it: "Pre-request", "Post-response".
    public var title: String {
        switch self {
        case .preRequest: "Pre-request"
        case .postResponse: "Post-response"
        }
    }
}
