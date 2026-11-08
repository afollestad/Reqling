import Foundation
import ReqlingKit
import ReqlingScriptProtocol

/// A run's script report as the Tests tab and a failed run show it: results grouped by phase and script, why scripts
/// didn't run or stopped, and the console as one text, which `CodeViewerPane` lays out however long it grows.
struct ScriptReportPresentation {
    struct Group: Identifiable {
        let id: String
        /// The phase and script: "Pre-request · Folder “Users”".
        let title: String
        let tests: [Test]
        /// What the script threw, and where; a stream script's first, with the event or message it threw on.
        let error: String?
        /// How many of a stream script's calls threw: "Threw for 3 events".
        let errorDetail: String?
    }

    struct Test: Identifiable {
        let id: Int
        let name: String
        let result: ScriptTestResult
        /// How a test a stream script ran on many events went: "Passed 498 of 500".
        let tally: String?
        /// Why it failed; for a stream script's, the first failure's, with the event or message it failed on.
        let message: String?
    }

    let groups: [Group]
    /// Why a phase's scripts didn't run, or stopped as a whole.
    let notes: [String]
    let console: TextDocument?
    let counts: ScriptTestCounts
    let hasFailures: Bool
    /// The project's scripts didn't run because it isn't trusted on this Mac.
    let isUntrusted: Bool

    /// `console` is the report's console as `consoleDocument` lays it out, when the caller already has it.
    init(_ report: ScriptReport, console: TextDocument?? = nil) {
        var groups: [Group] = []
        var notes: [String] = []
        for phase in report.phases {
            if let reason = phase.skipReason {
                notes.append(reason.message)
            }
            if let error = phase.error {
                notes.append("\(phase.phase.title) scripts: \(error.message)")
            }
            notes += phase.stream.map(Self.notes) ?? []
            let noun = phase.stream?.itemKind.rawValue
            for (index, level) in phase.levels.enumerated() where !level.tests.isEmpty || level.error != nil {
                groups.append(Group(
                    id: "\(phase.phase.rawValue)-\(index)",
                    title: "\(phase.phase.title) · \(Self.name(of: level))",
                    tests: level.tests.enumerated().map { index, test in Self.test(test, id: index, noun: noun) },
                    error: level.error.map { Self.item(level.failedItem, noun) + Self.describe($0) },
                    errorDetail: level.failedCallCount.flatMap { $0 > 1 ? "Threw for \(Self.count($0, noun ?? "item"))" : nil }
                ))
            }
        }
        self.groups = groups
        self.notes = notes.reduce(into: []) { unique, note in
            if !unique.contains(note) {
                unique.append(note)
            }
        }
        self.console = console ?? Self.consoleDocument(report)
        counts = report.testCounts
        hasFailures = report.hasFailures
        isUntrusted = report.phases.contains { $0.skipReason == .untrusted }
    }

    /// The report's console as the Tests tab shows it.
    static func consoleDocument(_ report: ScriptReport) -> TextDocument? {
        consoleText(report).map { TextDocument(text: $0, language: .plainText) }
    }

    /// "Tests 2/3": passed of those that ran, since a skipped test neither passed nor failed.
    var tabTitle: String {
        let ran = counts.passed + counts.failed
        return ran == 0 ? "Tests" : "Tests \(counts.passed)/\(ran)"
    }

    private static func test(_ test: ScriptTestReport, id: Int, noun: String?) -> Test {
        var message = test.message
        if let failed = test.firstFailedItem {
            message = message.map { item(failed, noun) + $0 } ?? "Failed first at \(noun ?? "item") \(failed)"
        }
        let ran = test.tally.map { $0.passed + $0.failed } ?? 0
        let tally = ran > 1 ? test.tally.map { "Passed \($0.passed) of \(ran)" } : nil
        return Test(id: id, name: test.name, result: test.result, tally: tally, message: message)
    }

    /// "Event 17: ", leading what happened on that item; empty with none.
    private static func item(_ item: Int?, _ noun: String?) -> String {
        guard let item, let noun else {
            return ""
        }
        return "\(noun.prefix(1).uppercased() + noun.dropFirst()) \(item): "
    }

    /// Why a stream script's events or messages reached no handler.
    private static func notes(_ stream: ScriptStreamReport) -> [String] {
        let noun = stream.itemKind.rawValue
        var notes: [String] = []
        if stream.droppedCount > 0 {
            notes.append("Stream scripts fell behind, so \(count(stream.droppedCount, noun)) reached no handler.")
        }
        if stream.isInterrupted {
            notes.append("Reqling quit before the stream scripts finished.")
        } else if stream.skippedCount > 0, let failed = stream.failedItem {
            notes.append("The stream scripts stopped at \(noun) \(failed), so \(count(stream.skippedCount, "later \(noun)")) reached no handler.")
        } else if stream.skippedCount > 0 {
            notes.append("The stream ended before its handlers caught up, so \(count(stream.skippedCount, noun)) reached no handler.")
        }
        return notes
    }

    /// "1 event", "12 events".
    private static func count(_ count: Int, _ noun: String) -> String {
        "\(count) \(noun)\(count == 1 ? "" : "s")"
    }

    private static func name(of level: ScriptLevelReport) -> String {
        switch level.kind {
        case .project: "Project"
        case .folder: "Folder “\(level.name)”"
        case .request: "Request"
        }
    }

    private static func describe(_ error: ScriptError) -> String {
        let name = error.name.map { "\($0): " } ?? ""
        let place = error.line.map { " (line \($0))" } ?? ""
        return name + error.message + place
    }

    /// Each phase's output, headed by its phase when both printed; a severity other than `log` leads its line.
    private static func consoleText(_ report: ScriptReport) -> String? {
        let phases = report.phases.filter { !$0.console.isEmpty }
        guard !phases.isEmpty else {
            return nil
        }
        var lines: [String] = []
        for phase in phases {
            if phases.count > 1 {
                lines.append("// \(phase.phase.title)")
            }
            if phase.isConsoleTruncated {
                lines.append("// Only the newest output was kept.")
            }
            for entry in phase.console {
                lines.append(entry.severity == .log ? entry.text : "[\(entry.severity.rawValue)] \(entry.text)")
            }
        }
        return lines.joined(separator: "\n")
    }
}

/// A response pane's `ScriptReportPresentation` memo, keyed on the report it shaped: an open stream republishes its
/// exchange many times a second with the same report. Its console is kept on its own while it stays the same, since a
/// stream script's report changes with each call it finishes, and a new console document would lay out again.
struct ScriptReportCache {
    /// What the console is laid out from, in a report.
    private struct ConsoleKey: Equatable {
        let phase: ScriptPhase
        let console: [ScriptConsoleEntry]
        let isTruncated: Bool
    }

    private var entry: (report: ScriptReport, value: ScriptReportPresentation)?
    private var console: (key: [ConsoleKey], document: TextDocument?)?

    mutating func presentation(of report: ScriptReport?) -> ScriptReportPresentation? {
        guard let report, !report.isEmpty else {
            return nil
        }
        if let entry, entry.report == report {
            return entry.value
        }
        let key = report.phases.map { ConsoleKey(phase: $0.phase, console: $0.console, isTruncated: $0.isConsoleTruncated) }
        let document = console.flatMap { $0.key == key ? $0.document : nil } ?? ScriptReportPresentation.consoleDocument(report)
        console = (key, document)
        let value = ScriptReportPresentation(report, console: .some(document))
        entry = (report, value)
        return value
    }
}
