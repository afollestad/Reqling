import Foundation
import Observation
import ReqlingScriptProtocol
import ReqlingTemplating

/// Runs a folder's or project's requests one after another, in sidebar order, a number of times or once per data row,
/// through `RequestRunner.run`, so each step is recorded, masked, and shown as a Send is. One run at a time, shared by
/// the window and agents, so either sees and can stop the other's.
///
/// Each step awaits the one before it, so what a script saves as an environment's current value reaches the next.
/// `rq.variables` values carry within an iteration through the step's `BatchStepContext`, and reset when the next
/// starts. Trust is settled once, before the first step; steps never ask (`RunOptions.mayPromptForTrust` stays off),
/// and read the project's trust as it stands when each starts, so revoking it mid-run takes effect.
///
/// Badges each observe one `BatchStatusCell` through `status(for:)`, so a step redraws only the rows it changes.
@MainActor
@Observable
public final class BatchRunner {
    /// The run going now, or the last one until it's dismissed or another starts: what the sidebar's bar shows.
    public internal(set) var run: BatchRun?
    /// From the moment a run is asked for, its trust question included, until it ends: what keeps another from starting.
    public private(set) var isRunning = false
    /// Whether there's a run to report, going or ended; it changes only when one starts, is shown, or is dismissed, so
    /// what reads it doesn't redraw on every step as a read of `run` would.
    public private(set) var hasReport = false
    /// Bumped each time the rows' statuses are replaced (a run starts, is shown, or is dismissed), so a badge reading
    /// `status(for:)` follows the new set.
    public internal(set) var generation = 0
    /// Bumped each time a request first fails in the current run, for the sidebar's "Failed in Last Run" filter.
    public internal(set) var failureRevision = 0

    @ObservationIgnored let runner: RequestRunner
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored var cells: [RequestNodeID: BatchStatusCell] = [:]
    /// Each folder in the run, with the requests inside it that the run runs.
    @ObservationIgnored var folderMembers: [RequestNodeID: [RequestNodeID]] = [:]
    /// Each request's folders within the run's scope.
    @ObservationIgnored var requestFolders: [RequestNodeID: [RequestNodeID]] = [:]
    @ObservationIgnored var requestNames: [RequestNodeID: String] = [:]
    @ObservationIgnored var failures: Set<RequestNodeID> = []
    @ObservationIgnored private var loop: Task<BatchRun, Never>?
    @ObservationIgnored private var timer: Task<Void, Never>?
    /// Why the run is stopping, once `stop()` or the time limit asked it to.
    @ObservationIgnored private var stopReason: BatchRunEnd?
    @ObservationIgnored private var current: (key: RunKey, step: BatchStepContext)?

    public init(runner: RequestRunner, sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.runner = runner
        self.sleep = sleep
    }

    /// A sidebar row's status in the current or last run; `nil` for one the run doesn't cover.
    public func status(for item: RequestNodeID) -> BatchItemStatus? {
        // Read first, so a badge follows a new run's cells even when it had none before.
        _ = generation
        return cells[item]?.status
    }

    /// The requests that failed in any iteration of the current or last run.
    public var failedRequests: Set<RequestNodeID> {
        _ = failureRevision
        return failures
    }

    /// Starts `plan`, once trust is settled: a run the person starts asks whether the project's scripts may run, when
    /// that isn't decided yet, listing every script the run would run. Returns as the first step starts.
    public func begin(_ plan: BatchRunPlan, mayPromptForTrust: Bool) async throws(BatchRunRefusal) -> BatchRunHandle {
        try await begin(plan, mayPromptForTrust: mayPromptForTrust, scriptSecrets: nil)
    }

    /// `scriptSecrets` gathers what every step's scripts make secret, for an agent's output.
    func begin(_ plan: BatchRunPlan, mayPromptForTrust: Bool, scriptSecrets: ScriptSecretSink?) async throws(BatchRunRefusal) -> BatchRunHandle {
        guard !isRunning else {
            throw .alreadyRunning
        }
        // Reserved before the trust question, so a second start can't slip in while it's open.
        isRunning = true
        let initial: BatchRun
        do throws(BatchRunRefusal) {
            initial = try await prepare(plan, mayPromptForTrust: mayPromptForTrust)
        } catch {
            isRunning = false
            throw error
        }
        stopReason = nil
        run = initial
        hasReport = true
        if let limit = initial.plan.timeLimit {
            let sleep = sleep
            timer = Task { [weak self] in
                do {
                    try await sleep(limit)
                } catch {
                    return
                }
                self?.stopAtTimeLimit()
            }
        }
        let task = Task {
            await self.execute(initial, scriptSecrets: scriptSecrets)
        }
        loop = task
        return BatchRunHandle(task: task)
    }

    /// Stops the run as Stop in the editor stops a request: the one running now ends, a stream's post-response scripts
    /// still running on what arrived, and no other starts.
    public func stop() {
        guard run?.isRunning == true else {
            return
        }
        stopReason = stopReason ?? .stopped
        if let current {
            runner.cancel(current.key.requestID, in: current.key.projectID)
        }
    }

    /// Runs the last run's plan again, as a run the person started: a data file is read afresh, and an agent's time
    /// limit is dropped.
    public func rerun() async throws(BatchRunRefusal) -> BatchRunHandle {
        guard !isRunning else {
            throw .alreadyRunning
        }
        guard var plan = run?.plan else {
            throw .nothingToRun
        }
        plan.timeLimit = nil
        if case .data(.file(let url), _) = plan.iterations {
            do throws(IterationDataError) {
                plan.iterations = .data(source: .file(url), rows: try await IterationData.read(url))
            } catch {
                throw .data(error)
            }
        }
        return try await begin(plan, mayPromptForTrust: true)
    }

    /// Clears the last run's report and badges; does nothing while a run is going.
    public func dismiss() {
        guard !isRunning else {
            return
        }
        run = nil
        hasReport = false
        replaceStatuses(cells: [:], folderMembers: [:], requestFolders: [:])
    }

    /// Shows `run` as though it had run, without running anything, for screenshots and snapshots: its tallies and
    /// current request give each row its badge.
    public func show(_ run: BatchRun) {
        guard !isRunning, let document = runner.library.document(run.plan.scope.projectID) else {
            return
        }
        self.run = run
        hasReport = true
        prepareStatuses(for: run.plan.requests, scope: run.plan.scope, in: document)
        failures = Set(run.tallies.filter { $0.value.counts.failed > 0 }.keys)
        failureRevision += 1
        for request in run.plan.requests {
            refreshStatus(of: request)
        }
    }

    // MARK: - Starting

    private func prepare(_ plan: BatchRunPlan, mayPromptForTrust: Bool) async throws(BatchRunRefusal) -> BatchRun {
        var plan = plan
        let project = plan.scope.projectID
        guard let document = runner.library.document(project) else {
            throw .projectUnavailable
        }
        var seen: Set<RequestNodeID> = []
        plan.requests = plan.requests.filter { document.request($0) != nil && seen.insert($0).inserted }
        guard !plan.requests.isEmpty, plan.iterationCount > 0 else {
            throw .nothingToRun
        }
        let notes = try await settleTrust(for: plan.requests.compactMap(document.request), in: document, mayPromptForTrust: mayPromptForTrust)
        // The trust question may have been open a while; start from the project as it is now.
        guard let current = runner.library.document(project) else {
            throw .projectUnavailable
        }
        let environment: RequestEnvironment? = if let id = plan.environmentID {
            current.environment(id)
        } else {
            runner.workspace.activeEnvironment(in: current)
        }
        guard let environment else {
            throw .environmentUnavailable
        }
        plan.environmentID = environment.id
        plan.requests = plan.requests.filter { current.request($0) != nil }
        guard !plan.requests.isEmpty else {
            throw .nothingToRun
        }
        requestNames = Dictionary(uniqueKeysWithValues: plan.requests.compactMap { id in current.request(id).map { (id, $0.name) } })
        prepareStatuses(for: plan.requests, scope: plan.scope, in: current)
        failures = []
        failureRevision += 1
        let scopeName = plan.scope.folderID.flatMap { current.folder($0)?.name } ?? current.name
        return BatchRun(plan: plan, scopeName: scopeName, environmentID: environment.id, environmentName: environment.name, notes: notes)
    }

    /// Asks once whether the project's scripts may run, when that isn't decided and any planned request has scripts.
    /// Returns the note the run carries when they won't run.
    private func settleTrust(
        for items: [RequestItem],
        in document: ProjectDocument,
        mayPromptForTrust: Bool
    ) async throws(BatchRunRefusal) -> [String] {
        var seen: Set<String> = []
        let files = items.flatMap { item in
            ScriptPhase.allCases.flatMap { document.scriptLevels(of: item, phase: $0).map(\.path) }
        }.filter { seen.insert($0).inserted }
        guard !files.isEmpty else {
            return []
        }
        var trust = runner.workspace.projectState(document.id).scriptTrust
        if trust == .unknown {
            let answer = await runner.askTrust(project: document.id, files: files, options: RunOptions(mayPromptForTrust: mayPromptForTrust))
            if Task.isCancelled {
                throw .cancelled
            }
            if answer == nil, mayPromptForTrust, runner.trustDecider != nil {
                throw .trustDismissed
            }
            trust = answer == true ? .trusted : .declined
        }
        return trust == .trusted ? [] : [BatchRun.untrustedNote]
    }

    // MARK: - Running

    /// What follows a step.
    private enum Advance {
        case next
        case jump(Int)
        case endIteration
        case endRun(BatchRunEnd)
    }

    /// The `rq.variables` values a step leaves for the next one in its iteration, with every value earlier steps made
    /// secret.
    private struct Carried {
        var locals: [String: TemplateVariable] = [:]
        var secrets: Set<String> = []
    }

    private func execute(_ initial: BatchRun, scriptSecrets: ScriptSecretSink?) async -> BatchRun {
        let plan = initial.plan
        var end = BatchRunEnd.finished
        iterations: for iteration in 0..<plan.iterationCount {
            run?.iteration = iteration
            var carried = Carried()
            var index = 0
            while index < plan.requests.count {
                let request = plan.requests[index]
                index += 1
                let advance = await step(request, iteration: iteration, of: initial, carried: &carried, scriptSecrets: scriptSecrets)
                switch advance {
                case .next:
                    continue
                case .jump(let position):
                    index = position
                case .endIteration:
                    continue iterations
                case .endRun(let reason):
                    end = reason
                    break iterations
                }
            }
        }
        // A stop that lands on the last step ends the run before any later step could notice it.
        if end == .finished, let reason = stopReason ?? (Task.isCancelled ? .stopped : nil) {
            end = reason
        }
        return finish(end, initial: initial)
    }

    /// Runs one request, unless the run is stopping, or the project, its pinned environment, or the request is gone,
    /// or the request is already running; then says what comes next.
    private func step(
        _ request: RequestNodeID,
        iteration: Int,
        of initial: BatchRun,
        carried: inout Carried,
        scriptSecrets: ScriptSecretSink?
    ) async -> Advance {
        let plan = initial.plan
        let project = plan.scope.projectID
        if let reason = stopReason ?? (Task.isCancelled ? .stopped : nil) {
            return .endRun(reason)
        }
        guard let document = runner.library.document(project) else {
            return .endRun(.projectRemoved)
        }
        guard document.environment(initial.environmentID) != nil else {
            return .endRun(.environmentRemoved)
        }
        guard let item = document.request(request) else {
            record(interrupted: request, iteration: iteration, message: "The request no longer exists.")
            return .next
        }
        requestNames[request] = item.name
        guard !runner.isInFlight(request, in: project) else {
            record(interrupted: request, iteration: iteration, message: "It was already running, so the run left it alone.")
            return .next
        }
        let step = BatchStepContext(
            iteration: iteration,
            iterationCount: plan.iterationCount,
            iterationData: plan.row(iteration),
            locals: carried.locals,
            carriedSecrets: carried.secrets
        )
        let exchange = await runStep(step, request: request, plan: plan, environment: initial.environmentID, scriptSecrets: scriptSecrets)
        guard step.wasRecorded, !step.wasCancelled, !Task.isCancelled else {
            let summary = step.wasRecorded ? RunSummary(exchange) : nil
            record(interrupted: request, iteration: iteration, message: interruption(of: step, in: project), summary: summary)
            return .next
        }
        record(exchange, request: request, iteration: iteration)
        carried = Carried(locals: step.locals, secrets: step.carriedSecrets)
        if plan.stopsOnFailure, exchange.outcomeKind == .failed {
            return .endRun(.stoppedOnFailure)
        }
        return advance(after: step.nextRequest, in: plan)
    }

    private func interruption(of step: BatchStepContext, in project: ProjectID) -> String {
        if step.wasCancelled || Task.isCancelled {
            return "Stopped."
        }
        return runner.library.document(project) == nil ? "The project was removed." : "Another run of this request replaced it."
    }

    /// Where a script's `setNextRequest` sends the iteration; a request the run doesn't hold ends it, with a note.
    private func advance(after next: ScriptNextRequest?, in plan: BatchRunPlan) -> Advance {
        switch next {
        case nil:
            return .next
        case .stop:
            return .endIteration
        case .request(let target):
            if let position = Self.position(of: target, in: plan.requests, names: requestNames) {
                return .jump(position)
            }
            note("No request “\(target)” is in this run, so the iteration that named it ended there.")
            return .endIteration
        }
    }

    private func runStep(
        _ step: BatchStepContext,
        request: RequestNodeID,
        plan: BatchRunPlan,
        environment: EnvironmentID,
        scriptSecrets: ScriptSecretSink?
    ) async -> RequestExchange {
        let project = plan.scope.projectID
        current = (RunKey(request, in: project), step)
        run?.currentRequest = request
        refreshStatus(of: request)
        var options = RunOptions(environmentID: environment, variableOverrides: plan.variableOverrides, streamLimit: plan.streamLimit)
        options.scriptSecrets = scriptSecrets
        options.batchStep = step
        let exchange = await runner.run(request, in: project, options: options)
        current = nil
        run?.currentRequest = nil
        return exchange
    }

    /// Where a script's `setNextRequest` points: a request in the run by ID, else the first by name.
    private static func position(of target: String, in requests: [RequestNodeID], names: [RequestNodeID: String]) -> Int? {
        requests.firstIndex { $0.description == target.lowercased() } ?? requests.firstIndex { names[$0] == target }
    }

    private func stopAtTimeLimit() {
        guard run?.isRunning == true else {
            return
        }
        stopReason = .timeLimit
        current?.step.wasCancelled = true
        // A request's own timeout can outlast what's left of an agent's, so the step in flight stops now.
        loop?.cancel()
    }

    private func finish(_ end: BatchRunEnd, initial: BatchRun) -> BatchRun {
        timer?.cancel()
        timer = nil
        loop = nil
        stopReason = nil
        run?.state = .ended(end)
        run?.currentRequest = nil
        isRunning = false
        return run ?? initial
    }

}
