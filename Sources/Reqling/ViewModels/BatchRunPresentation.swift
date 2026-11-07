import Foundation
import ReqlingKit

/// A sidebar row's badge for the current or last folder or project run, derived from its `BatchItemStatus`.
struct BatchBadgePresentation: Equatable {
    enum Symbol: Equatable {
        case progress
        case image(String)
    }

    enum Tint: Equatable {
        case passed
        case failed
        case secondary
        case tertiary
    }

    let symbol: Symbol
    let tint: Tint
    /// "2/3": tests passed of those that ran, or, for a request without tests that ran more than once, iterations passed.
    let count: String?
    /// What the badge means, for its tooltip and VoiceOver.
    let description: String

    /// `nil` for a row with nothing to show: one the run never reached, once it has ended.
    init?(_ status: BatchItemStatus, isRunGoing: Bool, isFolder: Bool) {
        let tests = status.tests
        let testsLine = tests.total > 0 ? " \(tests.passed) of \(tests.total) tests passed." : ""
        switch status.phase {
        case .pending:
            guard isRunGoing else {
                return nil
            }
            symbol = .image("circle.dotted")
            tint = .tertiary
            description = "Not run yet."
        case .running:
            symbol = .progress
            tint = .secondary
            description = "Running."
        case .passed:
            symbol = .image("checkmark.circle.fill")
            tint = .passed
            description = (isFolder ? "Every request in it that ran passed." : Self.passed(status)) + testsLine
        case .failed:
            symbol = .image("xmark.circle.fill")
            tint = .failed
            description = (isFolder ? "A request in it failed." : Self.failed(status)) + testsLine
        case .skipped:
            symbol = .image("arrow.uturn.forward.circle")
            tint = .secondary
            description = isFolder ? "Its requests were skipped." : "A script skipped it."
        case .interrupted:
            symbol = .image("minus.circle")
            tint = .secondary
            description = isFolder ? "Its requests were interrupted." : "Interrupted: stopped, replaced by another run, or already running."
        }
        if tests.total > 0 {
            count = "\(tests.passed)/\(tests.total)"
        } else if !isFolder, status.iterationsRun > 1 {
            count = "\(status.iterationsPassed)/\(status.iterationsRun)"
        } else {
            count = nil
        }
    }

    private static func passed(_ status: BatchItemStatus) -> String {
        guard status.iterationsRun > 1 else {
            return "Passed."
        }
        return status.iterationsPassed == status.iterationsRun
            ? "Passed in all \(status.iterationsRun) iterations."
            : "Passed in \(status.iterationsPassed) of \(status.iterationsRun) iterations."
    }

    private static func failed(_ status: BatchItemStatus) -> String {
        guard status.iterationsRun > 1 else {
            return "Failed."
        }
        let noun = status.failedIterations.count == 1 ? "iteration" : "iterations"
        return "Failed in \(noun) \(iterationList(status.failedIterations)) of \(status.iterationsRun)."
    }

    /// "2", "2 and 5", "2, 5, and 9", or "2, 5, 9, and 120 more", counting from 1; a run can make 10,000 iterations.
    static func iterationList(_ iterations: [Int]) -> String {
        let shown = iterations.prefix(3).map { String($0 + 1) }
        let rest = iterations.count - shown.count
        if rest > 0 {
            return shown.joined(separator: ", ") + ", and \(rest) more"
        }
        switch shown.count {
        case 0, 1: return shown.first ?? ""
        case 2: return "\(shown[0]) and \(shown[1])"
        default: return shown.dropLast().joined(separator: ", ") + ", and " + (shown.last ?? "")
        }
    }
}

/// The sidebar's bar for the current or last folder or project run.
struct BatchBarPresentation: Equatable {
    /// "Running Auth" or "Ran Auth".
    let title: String
    let environment: String
    /// Where a running run is ("Iteration 2 of 3 · Login"), or how an ended one ended.
    let progress: String
    /// "5 passed · 1 failed".
    let counts: String
    let notes: [String]
    let isRunning: Bool

    /// `currentName` is the running request's name as it is now, which a rename mid-run changes.
    init(run: BatchRun, currentName: String?) {
        isRunning = run.isRunning
        title = "\(run.isRunning ? "Running" : "Ran") \(run.scopeName)"
        environment = run.environmentName
        let iterations = run.plan.iterationCount
        switch run.state {
        case .running:
            let iteration = iterations > 1 ? "Iteration \(run.iteration + 1) of \(iterations)" : nil
            progress = [iteration, currentName].compactMap(\.self).joined(separator: " · ")
        case .ended(let end):
            progress = Self.describe(end, iterations: iterations)
        }
        var parts: [String] = []
        for (count, label) in [(run.counts.passed, "passed"), (run.counts.failed, "failed"), (run.counts.skipped, "skipped")] where count > 0 {
            parts.append("\(count) \(label)")
        }
        if run.counts.interrupted > 0 {
            parts.append("\(run.counts.interrupted) interrupted")
        }
        counts = parts.isEmpty ? (run.isRunning ? "Starting…" : "Nothing ran") : parts.joined(separator: " · ")
        notes = run.notes
    }

    /// What VoiceOver says when the run ends.
    var announcement: String {
        "\(title): \(counts). \(progress)."
    }

    private static func describe(_ end: BatchRunEnd, iterations: Int) -> String {
        switch end {
        case .finished: iterations > 1 ? "Finished \(iterations) iterations" : "Finished"
        case .stoppedOnFailure: "Stopped at a failure"
        case .stopped: "Stopped"
        case .timeLimit: "Stopped at its time limit"
        case .projectRemoved: "Stopped: the project was removed"
        case .environmentRemoved: "Stopped: its environment was removed"
        }
    }
}
