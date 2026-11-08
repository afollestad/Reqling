import MCP
import ReqlingScriptProtocol

/// What a run's scripts did, as the execution and history tools return it: test results, the console, errors, the
/// variables and cookies they changed (never with values), what stream scripts handled, and why scripts didn't run,
/// each naming its phase and script. A stream phase's test is one entry with its `counts` across calls. The report is
/// already masked; `mask` covers what the run couldn't know, as everywhere else in the output.
extension MCPExecutionTools {
    /// Console text kept in tool output: the newest entries within this many bytes.
    static let consoleLimit = 64 * 1_024

    static func scripts(_ report: ScriptReport, mask: (String) -> String) -> [String: Value] {
        var description: [String: Value] = [:]
        let counts = report.testCounts
        if counts.total > 0 {
            description["testSummary"] = testSummary(counts)
            description["tests"] = .array(report.phases.flatMap { phase in
                phase.levels.flatMap { level in
                    level.tests.map { test in
                        var described: [String: Value] = [
                            "phase": .string(phase.phase.rawValue),
                            "script": .string(level.title),
                            "name": .string(mask(test.name)),
                            "result": .string(test.result.rawValue)
                        ]
                        described["message"] = test.message.map { .string(mask($0)) }
                        described["counts"] = test.tally.map(testSummary)
                        described["firstFailedAt"] = test.firstFailedItem.map(Value.int)
                        return .object(described)
                    }
                }
            })
        }
        let (console, isCut) = console(report, mask: mask)
        if !console.isEmpty {
            description["console"] = .array(console)
        }
        if isCut {
            description["consoleTruncated"] = true
        }
        let errors = errors(report, mask: mask)
        if !errors.isEmpty {
            description["scriptErrors"] = .array(errors)
        }
        if let stream = report.phase(.stream)?.stream {
            description["streamScripts"] = streamScripts(stream)
        }
        description.merge(changes(report, mask: mask)) { $1 }
        var notes: [String] = []
        for reason in report.phases.compactMap(\.skipReason) where !notes.contains(note(reason)) {
            notes.append(note(reason))
        }
        if report.phase(.stream)?.stream?.isInterrupted == true {
            notes.append("Reqling quit before the stream scripts finished.")
        }
        if !notes.isEmpty {
            description["scriptNotes"] = .array(notes.map(Value.string))
        }
        return description
    }

    /// The variables and cookies the scripts set or removed, named but never with their values.
    private static func changes(_ report: ScriptReport, mask: (String) -> String) -> [String: Value] {
        let variables = report.phases.flatMap { phase in
            phase.variableChanges.map { change -> Value in
                [
                    "phase": .string(phase.phase.rawValue),
                    "scope": .string(change.scope.rawValue),
                    "name": .string(mask(change.key)),
                    "unset": .bool(change.isUnset),
                    "secret": .bool(change.isSecret)
                ]
            }
        }
        let cookies = report.phases.flatMap { phase in
            phase.cookieChanges.map { change -> Value in
                [
                    "phase": .string(phase.phase.rawValue),
                    "name": .string(mask(change.name)),
                    "domain": .string(mask(change.domain)),
                    "path": .string(mask(change.path)),
                    "removed": .bool(change.isRemoved)
                ]
            }
        }
        var description: [String: Value] = [:]
        if !variables.isEmpty {
            description["variableChanges"] = .array(variables)
        }
        if !cookies.isEmpty {
            description["cookieChanges"] = .array(cookies)
        }
        return description
    }

    static func testSummary(_ counts: ScriptTestCounts) -> Value {
        ["passed": .int(counts.passed), "failed": .int(counts.failed), "skipped": .int(counts.skipped)]
    }

    /// How many events or messages the stream scripts' handlers got, and how many reached none: `skipped` when the
    /// stream ended or the scripts stopped (`stoppedAt`) first, `dropped` when the handlers fell behind.
    private static func streamScripts(_ stream: ScriptStreamReport) -> Value {
        var described: [String: Value] = ["items": .string("\(stream.itemKind.rawValue)s"), "handled": .int(stream.handledCount)]
        described["skipped"] = stream.skippedCount > 0 ? .int(stream.skippedCount) : nil
        described["dropped"] = stream.droppedCount > 0 ? .int(stream.droppedCount) : nil
        described["stoppedAt"] = stream.failedItem.map(Value.int)
        return .object(described)
    }

    /// The newest entries within `consoleLimit`, oldest first, and whether any were left out here or by the history.
    private static func console(_ report: ScriptReport, mask: (String) -> String) -> (entries: [Value], isCut: Bool) {
        var kept: [Value] = []
        var budget = consoleLimit
        var isCut = report.phases.contains(where: \.isConsoleTruncated)
        entries: for phase in report.phases.reversed() {
            for entry in phase.console.reversed() {
                let text = mask(entry.text)
                budget -= text.utf8.count
                guard budget >= 0 else {
                    isCut = true
                    break entries
                }
                let script = phase.levels.indices.contains(entry.level) ? phase.levels[entry.level].title : nil
                var described: [String: Value] = [
                    "phase": .string(phase.phase.rawValue),
                    "severity": .string(entry.severity.rawValue),
                    "text": .string(text)
                ]
                described["script"] = script.map(Value.string)
                kept.append(.object(described))
            }
        }
        return (kept.reversed(), isCut)
    }

    /// Each level's error, then the phase's own, with the stream item it happened on and how many calls threw.
    private static func errors(_ report: ScriptReport, mask: (String) -> String) -> [Value] {
        report.phases.flatMap { phase in
            let levels = phase.levels.compactMap { level in
                level.error.map { error in
                    var described = self.error(error: error, phase: phase.phase, script: level.title, mask: mask)
                    described["item"] = level.failedItem.map(Value.int)
                    described["count"] = level.failedCallCount.map(Value.int)
                    return Value.object(described)
                }
            }
            let own = phase.error.map { error in
                var described = self.error(error: error, phase: phase.phase, script: nil, mask: mask)
                described["item"] = phase.stream?.failedItem.map(Value.int)
                return Value.object(described)
            }
            return levels + (own.map { [$0] } ?? [])
        }
    }

    private static func error(error: ScriptError, phase: ScriptPhase, script: String?, mask: (String) -> String) -> [String: Value] {
        var described: [String: Value] = ["phase": .string(phase.rawValue), "message": .string(mask(error.message))]
        described["script"] = script.map(Value.string)
        described["name"] = error.name.map(Value.string)
        described["line"] = error.line.map(Value.int)
        described["column"] = error.column.map(Value.int)
        return described
    }

    /// Why scripts didn't run, worded for an agent, who can't change the project's trust.
    private static func note(_ reason: ScriptSkipReason) -> String {
        switch reason {
        case .untrusted:
            "The project's scripts didn't run: they aren't trusted on this Mac. Only the person at the Mac can trust them, in Reqling."
        case .requestFailed, .quit, .requestSkipped:
            reason.message
        }
    }

    /// What of a withheld run's result stays: its status and sizes, and nothing a server or script could have echoed.
    private static let withheldKeeps: [String: Set<String>] = [
        "response": ["status", "durationMs", "byteCount", "protocol", "tlsVersion"],
        "call": ["rpc", "kind", "sentCount", "receivedCount", "durationMs", "status"],
        "connection": ["subprotocol", "sentCount", "receivedCount", "durationMs", "end"]
    ]

    /// A recorded run as `get_last_response` and `get_run` return it, masked with `mask` (the project's secrets) and
    /// the values the run's scripts made secret, which Reqling keeps until it quits. A run whose scripts made run-local
    /// secrets, or that held ones an earlier step of its folder or project run made, can't be masked once Reqling no
    /// longer holds them, so its response is withheld instead.
    @MainActor
    static func describeRecorded(_ exchange: RequestExchange, mask: @escaping (String) -> String, runner: RequestRunner) -> [String: Value] {
        if let secrets = runner.scriptSecrets.secrets(of: exchange.id) {
            let redaction = SecretRedaction(secrets: secrets)
            return describe(exchange, mask: { mask(redaction.apply($0)) })
        }
        var description = describe(exchange, mask: mask)
        let made = exchange.scriptReport?.madeRunLocalSecrets == true
        guard made || exchange.heldRunLocalSecrets == true else {
            return description
        }
        for (key, kept) in withheldKeeps {
            guard case .object(var payload)? = description[key] else {
                continue
            }
            payload = payload.filter { kept.contains($0.key) }
            if case .object(var status)? = payload["status"] {
                status["message"] = nil
                payload["status"] = .object(status)
            }
            description[key] = .object(payload)
        }
        let cause = made
            ? "This run's scripts made values secret for that run only"
            : "This run used values an earlier request of its folder or project run made secret for that run only"
        description["withheld"] = .string("\(cause), which Reqling no longer holds, so its response can't be masked and is left "
            + "out. Send the request again to read one.")
        return description
    }
}
