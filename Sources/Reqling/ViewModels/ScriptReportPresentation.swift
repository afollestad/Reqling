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
        /// What the script threw, and where.
        let error: String?
    }

    struct Test: Identifiable {
        let id: Int
        let name: String
        let result: ScriptTestResult
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

    init(_ report: ScriptReport) {
        var groups: [Group] = []
        var notes: [String] = []
        for phase in report.phases {
            if let reason = phase.skipReason {
                notes.append(reason.message)
            }
            if let error = phase.error {
                notes.append("\(phase.phase.title) scripts: \(error.message)")
            }
            for (index, level) in phase.levels.enumerated() where !level.tests.isEmpty || level.error != nil {
                groups.append(Group(
                    id: "\(phase.phase.rawValue)-\(index)",
                    title: "\(phase.phase.title) · \(Self.name(of: level))",
                    tests: level.tests.enumerated().map { index, test in
                        Test(id: index, name: test.name, result: test.result, message: test.message)
                    },
                    error: level.error.map(Self.describe)
                ))
            }
        }
        self.groups = groups
        self.notes = notes.reduce(into: []) { unique, note in
            if !unique.contains(note) {
                unique.append(note)
            }
        }
        console = Self.consoleText(report).map { TextDocument(text: $0, language: .plainText) }
        counts = report.testCounts
        hasFailures = report.hasFailures
        isUntrusted = report.phases.contains { $0.skipReason == .untrusted }
    }

    /// "Tests 2/3": passed of those that ran, since a skipped test neither passed nor failed.
    var tabTitle: String {
        let ran = counts.passed + counts.failed
        return ran == 0 ? "Tests" : "Tests \(counts.passed)/\(ran)"
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
/// exchange many times a second with the same report.
struct ScriptReportCache {
    private var entry: (report: ScriptReport, value: ScriptReportPresentation)?

    mutating func presentation(of report: ScriptReport?) -> ScriptReportPresentation? {
        guard let report, !report.isEmpty else {
            return nil
        }
        if let entry, entry.report == report {
            return entry.value
        }
        let value = ScriptReportPresentation(report)
        entry = (report, value)
        return value
    }
}
