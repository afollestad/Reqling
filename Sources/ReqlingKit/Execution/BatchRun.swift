import Foundation
import Observation
import ReqlingTemplating

/// What a folder or project run covers: a folder and everything inside it, or the whole project.
public struct BatchRunScope: Hashable, Sendable {
    public let projectID: ProjectID
    /// `nil` for the whole project.
    public let folderID: RequestNodeID?

    public init(projectID: ProjectID, folderID: RequestNodeID?) {
        self.projectID = projectID
        self.folderID = folderID
    }
}

/// What a folder or project run does, settled before it starts.
public struct BatchRunPlan: Hashable, Sendable {
    /// How long an event stream or WebSocket runs before the run moves on, unless the plan says otherwise.
    public static let defaultStreamSeconds = 10

    public enum Iterations: Hashable, Sendable {
        /// Every request, this many times over.
        case count(Int)
        /// Once per row, each column a variable for that pass.
        case data(source: DataSource, rows: [[String: String]])
    }

    public enum DataSource: Hashable, Sendable {
        /// Read from this file, which running again reads afresh.
        case file(URL)
        /// Given by an agent with the run.
        case inline
    }

    public var scope: BatchRunScope
    /// The environment every step resolves against, pinned when the run starts; `nil` takes the project's active one.
    public var environmentID: EnvironmentID?
    /// The requests to run, in sidebar order.
    public var requests: [RequestNodeID]
    public var iterations: Iterations
    public var stopsOnFailure: Bool
    /// Ends each event stream and WebSocket. gRPC calls keep their own deadline.
    public var streamLimit: StreamLimit
    /// One-run values that beat every environment and the data row, as MCP's `variables` give them.
    public var variableOverrides: [String: String]
    /// Stops the whole run after this long, as an agent's must before its tool times out; `nil` for none.
    public var timeLimit: Duration?

    public init(
        scope: BatchRunScope,
        environmentID: EnvironmentID? = nil,
        requests: [RequestNodeID],
        iterations: Iterations = .count(1),
        stopsOnFailure: Bool = false,
        streamLimit: StreamLimit = StreamLimit(maxDuration: .seconds(defaultStreamSeconds)),
        variableOverrides: [String: String] = [:],
        timeLimit: Duration? = nil
    ) {
        self.scope = scope
        self.environmentID = environmentID
        self.requests = requests
        self.iterations = iterations
        self.stopsOnFailure = stopsOnFailure
        self.streamLimit = streamLimit
        self.variableOverrides = variableOverrides
        self.timeLimit = timeLimit
    }

    public var iterationCount: Int {
        switch iterations {
        case .count(let count): max(count, 1)
        case .data(_, let rows): rows.count
        }
    }

    /// The data row of `iteration`; empty for a counted run.
    func row(_ iteration: Int) -> [String: String] {
        guard case .data(_, let rows) = iterations, rows.indices.contains(iteration) else {
            return [:]
        }
        return rows[iteration]
    }
}

/// How one request's run in one iteration went.
public enum BatchStepResult: String, Hashable, Sendable {
    case passed
    /// `RunOutcomeKind.failed`: an error status, a transport or script error, or a failed test.
    case failed
    /// A pre-request script skipped it (`rq.execution.skipRequest`).
    case skipped
    /// Stopped, replaced by another run of the request, already running, or gone: neither passed nor failed.
    case interrupted
}

/// One request's run in one iteration.
public struct BatchRunStep: Hashable, Sendable {
    public let iteration: Int
    public let requestID: RequestNodeID
    public let requestName: String
    /// `nil` when nothing reached the history.
    public let summary: RunSummary?
    public let result: BatchStepResult
    /// Why it failed or was interrupted.
    public let message: String?

    public init(iteration: Int, requestID: RequestNodeID, requestName: String, summary: RunSummary?, result: BatchStepResult, message: String?) {
        self.iteration = iteration
        self.requestID = requestID
        self.requestName = requestName
        self.summary = summary
        self.result = result
        self.message = message
    }
}

/// How often each result came up.
public struct BatchStepCounts: Hashable, Sendable {
    public var passed = 0
    public var failed = 0
    public var skipped = 0
    public var interrupted = 0

    public init(passed: Int = 0, failed: Int = 0, skipped: Int = 0, interrupted: Int = 0) {
        self.passed = passed
        self.failed = failed
        self.skipped = skipped
        self.interrupted = interrupted
    }

    public var total: Int {
        passed + failed + skipped + interrupted
    }

    mutating func add(_ result: BatchStepResult) {
        switch result {
        case .passed: passed += 1
        case .failed: failed += 1
        case .skipped: skipped += 1
        case .interrupted: interrupted += 1
        }
    }
}

/// One request's results across every iteration.
public struct BatchRequestTally: Hashable, Sendable {
    public var counts = BatchStepCounts()
    public var tests = ScriptTestCounts()
    /// The iterations it failed in, from 0.
    public var failedIterations: [Int] = []

    public init(counts: BatchStepCounts = BatchStepCounts(), tests: ScriptTestCounts = ScriptTestCounts(), failedIterations: [Int] = []) {
        self.counts = counts
        self.tests = tests
        self.failedIterations = failedIterations
    }
}

/// Why a run ended. An iteration a script ends early (`setNextRequest(null)`, or a request it names that isn't in the
/// run) isn't the run's end: the next iteration starts.
public enum BatchRunEnd: Hashable, Sendable {
    case finished
    case stoppedOnFailure
    /// The person or the agent stopped it.
    case stopped
    case timeLimit
    case projectRemoved
    case environmentRemoved
}

/// A folder or project run as the sidebar's bar and an agent see it.
public struct BatchRun: Hashable, Sendable {
    /// The most steps that didn't pass a run keeps one by one; past this, only their count grows.
    public static let notableStepLimit = 1_000

    public enum State: Hashable, Sendable {
        case running
        case ended(BatchRunEnd)
    }

    public let plan: BatchRunPlan
    /// The folder's or project's name when the run started.
    public let scopeName: String
    public let environmentID: EnvironmentID
    public let environmentName: String
    public var state: State
    /// From 0.
    public var iteration: Int
    /// The request running now; `nil` between steps and once the run ends.
    public var currentRequest: RequestNodeID?
    public var counts: BatchStepCounts
    public var tallies: [RequestNodeID: BatchRequestTally]
    /// Every step that didn't pass, in order, up to `notableStepLimit`.
    public var notableSteps: [BatchRunStep]
    public var omittedNotableSteps: Int
    /// What the person or agent should know beyond the counts, such as scripts not running.
    public var notes: [String]

    public init(
        plan: BatchRunPlan,
        scopeName: String,
        environmentID: EnvironmentID,
        environmentName: String,
        state: State = .running,
        iteration: Int = 0,
        currentRequest: RequestNodeID? = nil,
        counts: BatchStepCounts = BatchStepCounts(),
        tallies: [RequestNodeID: BatchRequestTally] = [:],
        notableSteps: [BatchRunStep] = [],
        omittedNotableSteps: Int = 0,
        notes: [String] = []
    ) {
        self.plan = plan
        self.scopeName = scopeName
        self.environmentID = environmentID
        self.environmentName = environmentName
        self.state = state
        self.iteration = iteration
        self.currentRequest = currentRequest
        self.counts = counts
        self.tallies = tallies
        self.notableSteps = notableSteps
        self.omittedNotableSteps = omittedNotableSteps
        self.notes = notes
    }

    public var isRunning: Bool {
        state == .running
    }

    mutating func add(_ step: BatchRunStep) {
        counts.add(step.result)
        var tally = tallies[step.requestID] ?? BatchRequestTally()
        tally.counts.add(step.result)
        if let tests = step.summary?.tests {
            tally.tests.passed += tests.passed
            tally.tests.failed += tests.failed
            tally.tests.skipped += tests.skipped
        }
        if step.result == .failed {
            tally.failedIterations.append(step.iteration)
        }
        tallies[step.requestID] = tally
        guard step.result != .passed else {
            return
        }
        if notableSteps.count < Self.notableStepLimit {
            notableSteps.append(step)
        } else {
            omittedNotableSteps += 1
        }
    }
}

/// What a sidebar row shows for the current run: a request's results across every iteration, or a folder's rolled up
/// from the requests inside it.
public struct BatchItemStatus: Hashable, Sendable {
    public enum Phase: Hashable, Sendable {
        /// In the run, not reached yet.
        case pending
        case running
        case passed
        case failed
        case skipped
        case interrupted
    }

    public var phase: Phase
    public var tests: ScriptTestCounts
    /// The iterations it ran in, and passed; `0` for a folder.
    public var iterationsRun: Int
    public var iterationsPassed: Int
    /// The iterations it failed in, from 0; a folder's lists none.
    public var failedIterations: [Int]

    public init(
        phase: Phase = .pending,
        tests: ScriptTestCounts = ScriptTestCounts(),
        iterationsRun: Int = 0,
        iterationsPassed: Int = 0,
        failedIterations: [Int] = []
    ) {
        self.phase = phase
        self.tests = tests
        self.iterationsRun = iterationsRun
        self.iterationsPassed = iterationsPassed
        self.failedIterations = failedIterations
    }

    /// A request's status from its tally: any failure fails it, then any pass passes it.
    init(_ tally: BatchRequestTally, isRunning: Bool) {
        let counts = tally.counts
        let phase: Phase = if isRunning {
            .running
        } else if counts.failed > 0 {
            .failed
        } else if counts.passed > 0 {
            .passed
        } else if counts.skipped > 0 {
            .skipped
        } else if counts.interrupted > 0 {
            .interrupted
        } else {
            .pending
        }
        self.init(
            phase: phase,
            tests: tally.tests,
            iterationsRun: counts.total,
            iterationsPassed: counts.passed,
            failedIterations: tally.failedIterations
        )
    }

    /// A folder's status from the requests inside it, in the same precedence, running first.
    init(rollingUp statuses: [BatchItemStatus]) {
        let phases = Set(statuses.map(\.phase))
        let order: [Phase] = [.running, .failed, .passed, .skipped, .interrupted]
        var tests = ScriptTestCounts()
        for status in statuses {
            tests.passed += status.tests.passed
            tests.failed += status.tests.failed
            tests.skipped += status.tests.skipped
        }
        self.init(phase: order.first(where: phases.contains) ?? .pending, tests: tests)
    }
}

/// One sidebar row's status, observed on its own.
@MainActor
@Observable
final class BatchStatusCell {
    var status = BatchItemStatus()
}

/// A run that has started: `finished()` waits for how it ended.
public struct BatchRunHandle: Sendable {
    let task: Task<BatchRun, Never>

    /// Waits for the run to end. Cancelling the task awaiting this stops the run, the request in flight included, as
    /// an agent's cancelled or timed-out call must.
    public func finished() async -> BatchRun {
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }
}

/// Why a folder or project run didn't start.
public enum BatchRunRefusal: Error, Equatable, Sendable, LocalizedError {
    case alreadyRunning
    case projectUnavailable
    case environmentUnavailable
    case nothingToRun
    /// The person dismissed the trust question, so nothing ran.
    case trustDismissed
    /// The caller stopped waiting while the trust question was open.
    case cancelled
    /// The data file couldn't be read again.
    case data(IterationDataError)

    public var errorDescription: String? {
        switch self {
        case .alreadyRunning: "Another folder or project run is going; stop it first."
        case .projectUnavailable: "The project is not available."
        case .environmentUnavailable: "The environment no longer exists."
        case .nothingToRun: "There are no requests to run."
        case .trustDismissed: "The run didn't start, since the question about the project's scripts was dismissed."
        case .cancelled: "The run was cancelled before it started."
        case .data(let error): error.message
        }
    }
}

extension BatchRun {
    /// The note a run carries when the project's scripts didn't run.
    public static let untrustedNote = "Scripts didn't run: not trusted on this Mac."
}
