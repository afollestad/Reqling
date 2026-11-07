import MCP
import ReqlingScriptProtocol

/// What a run's scripts did, as the execution and history tools return it: test results, the console, errors, and
/// why scripts didn't run, each naming its phase and script. The report is already masked; `mask` covers what the run
/// couldn't know, as everywhere else in the output.
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
        let errors = report.phases.flatMap { phase in
            phase.levels.compactMap { level in level.error.map { error(error: $0, phase: phase.phase, script: level.title, mask: mask) } }
                + (phase.error.map { [error(error: $0, phase: phase.phase, script: nil, mask: mask)] } ?? [])
        }
        if !errors.isEmpty {
            description["scriptErrors"] = .array(errors)
        }
        var notes: [String] = []
        for reason in report.phases.compactMap(\.skipReason) where !notes.contains(note(reason)) {
            notes.append(note(reason))
        }
        if !notes.isEmpty {
            description["scriptNotes"] = .array(notes.map(Value.string))
        }
        return description
    }

    static func testSummary(_ counts: ScriptTestCounts) -> Value {
        ["passed": .int(counts.passed), "failed": .int(counts.failed), "skipped": .int(counts.skipped)]
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

    private static func error(error: ScriptError, phase: ScriptPhase, script: String?, mask: (String) -> String) -> Value {
        var described: [String: Value] = ["phase": .string(phase.rawValue), "message": .string(mask(error.message))]
        described["script"] = script.map(Value.string)
        described["name"] = error.name.map(Value.string)
        described["line"] = error.line.map(Value.int)
        described["column"] = error.column.map(Value.int)
        return .object(described)
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
    /// secrets Reqling no longer holds can't be masked, so its response is withheld instead.
    @MainActor
    static func describeRecorded(_ exchange: RequestExchange, mask: @escaping (String) -> String, runner: RequestRunner) -> [String: Value] {
        if let secrets = runner.scriptSecrets.secrets(of: exchange.id) {
            let redaction = SecretRedaction(secrets: secrets)
            return describe(exchange, mask: { mask(redaction.apply($0)) })
        }
        var description = describe(exchange, mask: mask)
        guard exchange.scriptReport?.madeRunLocalSecrets == true else {
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
        description["withheld"] = .string("This run's scripts made values secret for that run only, which Reqling no longer "
            + "holds, so its response can't be masked and is left out. Send the request again to read one.")
        return description
    }
}
