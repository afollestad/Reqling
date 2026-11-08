import Foundation
import ReqlingScriptProtocol
import ReqlingTemplating

/// One run's scripts: what runs in each phase, taken when the run starts so an edit mid-run never changes it, and the
/// state the phases share — the variables as scripts left them, the request changes a pre-request script made, and
/// the report. The only interpreter of the helper's events.
///
/// Values scripts set for an environment or Global, and the cookies they set or remove, are committed after each phase
/// (to `CurrentValueStore` and the project's jar), whatever its outcome, so what a script set before it threw, timed
/// out, or was stopped still lands; a stream phase commits as its calls finish (`ScriptSession+Stream.swift`).
/// Pre-request cookies so land before the request is prepared, and URLSession sends them. A preview, which only shows
/// what a request would send, commits nothing.
@MainActor
final class ScriptSession {
    enum Mode {
        case run
        case preview
    }

    enum PhaseOutcome: Equatable {
        case finished
        /// A level threw, or the phase timed out, crashed, or couldn't start.
        case failed
        case cancelled
    }

    let project: ProjectID
    let item: RequestItem
    let mode: Mode
    let environmentID: EnvironmentID
    let environments: VariableScope.Environments
    /// The scripts each phase runs, outermost level first; a phase with none is absent.
    let levels: [ScriptPhase: [ScriptLevelSource]]
    let secretSink: ScriptSecretSink?
    /// Which pass of a folder or project run this is, and how many it makes, as `rq.info` reports them.
    let iteration: Int
    let iterationCount: Int
    /// `nil` until the run has decided; `false` runs the request without its scripts.
    var isTrusted: Bool?
    /// A pre-request script asked not to send the request (`rq.execution.skipRequest`).
    private(set) var isSkipRequested = false
    /// What a folder or project run runs next, as a script last named it (`rq.execution.setNextRequest`); a run of the
    /// request on its own ignores it.
    private(set) var nextRequest: ScriptNextRequest?
    private(set) var layers: VariableLayers {
        didSet {
            layersRevision += 1
            shownCache = nil
        }
    }
    /// Bumps with every change to `layers`, so what resolves against them (a live connection's sends) knows to refresh.
    private(set) var layersRevision = 0
    private(set) var changes: [ScriptRequestChange] = []
    private(set) var report = ScriptReport() {
        didSet { shownCache = nil }
    }
    /// Every value a script made secret this run, or an earlier step of its folder or project run made secret for that
    /// run, which masking covers even after a later `unset` hides it from the layers.
    private(set) var secretValues: Set<String> = [] {
        didSet { shownCache = nil }
    }
    /// `shownReport` as last masked: an open stream's partial exchange reads it on every publish, and masking the whole
    /// report each time would grow with its console.
    private var shownCache: ScriptReport??
    private var pendingWrites: [VariableWrite] = []
    /// What scripts set or removed in the jar that `commit` hasn't applied yet.
    private(set) var pendingCookieWrites: [ScriptCookieWrite] = []
    /// The stream phase, once the run's stream has opened.
    var stream: ScriptStreamRun?
    /// The project's jar, through `RequestRunner.cookieJar(for:creating:)`; `creating` only to commit.
    private let cookieJar: @MainActor (_ creating: Bool) -> ProjectCookieJar?
    /// Sends the requests scripts send (`ScriptSession+Fetches.swift`); without one, each fails.
    let fetchPerformer: ScriptFetchPerformer?

    init(
        project: ProjectID,
        item: RequestItem,
        mode: Mode,
        scope: VariableScope,
        environments: VariableScope.Environments,
        levels: [ScriptPhase: [ScriptLevelSource]],
        secretSink: ScriptSecretSink?,
        iteration: Int = 0,
        iterationCount: Int = 1,
        carriedSecrets: Set<String> = [],
        cookieJar: @escaping @MainActor (_ creating: Bool) -> ProjectCookieJar?,
        fetchPerformer: ScriptFetchPerformer? = nil
    ) {
        self.project = project
        self.cookieJar = cookieJar
        self.fetchPerformer = fetchPerformer
        self.item = item
        self.mode = mode
        self.environments = environments
        self.levels = levels
        self.secretSink = secretSink
        self.iteration = iteration
        self.iterationCount = iterationCount
        environmentID = environments.active?.id ?? environments.defaultEnvironment.id
        layers = scope.layers
        // An earlier step's secrets mask this run's output even after a script here unsets them.
        secretValues = carriedSecrets
    }

    func hasScripts(_ phase: ScriptPhase) -> Bool {
        !(levels[phase]?.isEmpty ?? true)
    }

    /// The scripts that would run, as the trust prompt lists them.
    var files: [String] {
        ScriptPhase.allCases.flatMap { levels[$0] ?? [] }.map(\.path)
    }

    /// The request as scripts left it: the template with their header and query changes.
    var kind: RequestKind {
        item.kind.applying(changes)
    }

    /// What the request resolves against once scripts have run.
    var scope: VariableScope {
        VariableScope(layers: layers, environments: environments)
    }

    /// Every secret the run may have touched, for masking what it shows.
    var allSecretValues: Set<String> {
        layers.allSecretValues.union(secretValues)
    }

    /// Notes that a phase's scripts didn't run, and why.
    func skip(_ phase: ScriptPhase, reason: ScriptSkipReason) {
        guard hasScripts(phase), report.phase(phase) == nil else {
            return
        }
        report.phases.append(ScriptPhaseReport(phase: phase, levels: levelReports(phase), skipReason: reason))
    }

    /// Runs a phase in the helper, applying its events as they arrive. Its report is in `report` from the start, as a
    /// stream phase's is, so the requests its scripts send can log their lines as they finish. Cancelling the task
    /// awaiting this kills the helper.
    func run(
        _ phase: ScriptPhase,
        response: (snapshot: ScriptResponseSnapshot, blobs: [Data])?,
        runner: any ScriptRunning,
        timeLimit: Duration
    ) async -> PhaseOutcome {
        guard let phaseLevels = levels[phase], !phaseLevels.isEmpty else {
            return .finished
        }
        let input = input(phase, levels: phaseLevels, response: response?.snapshot)
        let execution = runner.run(input, blobs: response?.blobs ?? [], timeLimit: timeLimit)
        let index = beginPhase(ScriptPhaseReport(phase: phase, levels: levelReports(phase)))
        let log: @MainActor (ScriptConsoleEntry) -> Void = { [weak self] entry in
            self?.updatePhase(at: index) { $0.console.append(entry) }
        }
        let fetches = fetchQueue(reply: execution.reply, log: log)
        await withTaskCancellationHandler {
            for await event in execution.events {
                switch event {
                case .fetch(let id, let level, let fetch):
                    fetches.add(ScriptFetchQueue.Pending(id: id, level: level, fetch: fetch, group: level))
                case .levelFinished(let level), .levelFailed(let level, _):
                    updatePhase(at: index) { apply(event, in: phase, to: &$0) }
                    endFetches(fetches, group: level, log: log)
                default:
                    updatePhase(at: index) { apply(event, in: phase, to: &$0) }
                }
            }
        } onCancel: {
            execution.cancel()
        }
        closeFetches(fetches, log: log)
        let termination = await execution.termination()
        var outcome: PhaseOutcome = report.phases[index].levels.contains { $0.error != nil } ? .failed : .finished
        switch termination {
        case .finished:
            break
        case .timedOut:
            let seconds = Int(timeLimit / .seconds(1))
            updatePhase(at: index) { phaseReport in
                phaseReport.error = ScriptError(
                    name: "TimeoutError",
                    message: "The \(phase.title.lowercased()) scripts didn't finish within \(seconds) s, the time limit in Settings ▸ Requests."
                )
            }
            outcome = .failed
        case .cancelled:
            outcome = .cancelled
        case .failed(let message):
            updatePhase(at: index) { $0.error = ScriptError(message: message) }
            outcome = .failed
        }
        secretSink?.collect(secretValues)
        return outcome
    }

    /// Stores what the last phase set for an environment or Global as this Mac's current values, and applies the
    /// cookies it set or removed to the project's jar. Writes for a project or environment deleted meanwhile are
    /// dropped, so a run can't bring them back.
    func commit(to library: ProjectLibrary) {
        let writes = pendingWrites
        let cookieWrites = pendingCookieWrites
        pendingWrites = []
        pendingCookieWrites = []
        guard mode == .run else {
            return
        }
        if !cookieWrites.isEmpty {
            cookieJar(true)?.apply(cookieWrites)
        }
        guard !writes.isEmpty, let document = library.document(project) else {
            return
        }
        var changes: [CurrentValueScope: [String: CurrentVariable?]] = [:]
        for write in writes {
            let scope: CurrentValueScope
            switch write.scope {
            case .environment: scope = .environment(project, environmentID)
            case .defaultEnvironment: scope = .environment(project, document.defaultEnvironment.id)
            case .global: scope = .global
            case .local: continue
            }
            if case .environment(_, let environment) = scope, document.environment(environment) == nil {
                continue
            }
            let value: CurrentVariable = write.value.map { .value(TemplateVariable(value: $0, isSecret: write.isSecret)) } ?? .unset
            changes[scope, default: [:]][write.key] = .some(value)
        }
        for (scope, values) in changes {
            library.currentValues.apply(values, in: scope)
        }
    }

    /// `maskedReport()`, or `nil` while no phase has anything to say.
    var shownReport: ScriptReport? {
        if let shownCache {
            return shownCache
        }
        let shown = report.isEmpty ? nil : maskedReport()
        shownCache = .some(shown)
        return shown
    }

    /// The report with every secret the run touched masked in what scripts printed, named, or threw.
    func maskedReport() -> ScriptReport {
        let redaction = SecretRedaction(secrets: allSecretValues)
        var masked = report
        for phase in masked.phases.indices {
            for entry in masked.phases[phase].console.indices {
                masked.phases[phase].console[entry].text = redaction.apply(masked.phases[phase].console[entry].text)
            }
            masked.phases[phase].error = masked.phases[phase].error.map { Self.masked($0, redaction) }
            for level in masked.phases[phase].levels.indices {
                masked.phases[phase].levels[level].error = masked.phases[phase].levels[level].error.map { Self.masked($0, redaction) }
                for test in masked.phases[phase].levels[level].tests.indices {
                    masked.phases[phase].levels[level].tests[test].name = redaction.apply(masked.phases[phase].levels[level].tests[test].name)
                    masked.phases[phase].levels[level].tests[test].message = masked.phases[phase].levels[level].tests[test].message
                        .map(redaction.apply)
                }
            }
        }
        return masked
    }

    /// What the helper runs for `phase`, as the session stands now.
    func input(
        _ phase: ScriptPhase,
        levels: [ScriptLevelSource],
        response: ScriptResponseSnapshot?,
        stream: ScriptStreamSetup? = nil
    ) -> ScriptRunnerInput {
        ScriptRunnerInput(
            phase: phase,
            levels: levels,
            variables: layers,
            info: ScriptRunInfo(
                requestName: item.name,
                requestID: item.id.description,
                protocolName: item.kind.name.rawValue,
                environmentName: environmentName,
                defaultEnvironmentName: environments.defaultEnvironment.name,
                iteration: iteration,
                iterationCount: iterationCount
            ),
            request: ScriptInputBuilder.request(kind),
            response: response,
            stream: stream,
            // Taken now: after the request, the jar already holds its response's `Set-Cookie`s.
            cookies: projectCookies(),
            runtimeDirectory: ""
        )
    }

    private func apply(_ event: ScriptRunnerEvent, in phase: ScriptPhase, to phaseReport: inout ScriptPhaseReport) {
        switch event {
        case .variable(let write):
            phaseReport.variableChanges.append(absorb(write))
        case .request(let change) where phase == .preRequest:
            changes.append(change)
        case .cookie(let write) where phaseReport.cookieChanges.count < ScriptLimits.standard.cookieWrites:
            phaseReport.cookieChanges.append(absorb(write))
        case .console(let level, let severity, let text) where phaseReport.console.count <= ScriptLimits.standard.consoleEntries:
            phaseReport.console.append(ScriptConsoleEntry(level: level, severity: severity, text: text))
        case .test(let level, let name, let result, let message) where phaseReport.levels.indices.contains(level):
            phaseReport.levels[level].tests.append(ScriptTestReport(name: name, result: result, message: message))
        case .levelFailed(let level, let error) where phaseReport.levels.indices.contains(level):
            phaseReport.levels[level].error = error
        case .flow(.skipRequest) where phase == .preRequest:
            isSkipRequested = true
        case .flow(.setNextRequest(let request)):
            setNextRequest(request)
        default:
            break
        }
    }

    /// Applies a value a script set: to the layers later phases see, to what masking covers, and, for an environment
    /// or Global, to what `commit` stores. What the report lists of it, without its value.
    func absorb(_ write: VariableWrite) -> ScriptVariableChange {
        let applied = layers.apply(write)
        if applied.isSecret, let value = applied.value {
            secretValues.insert(value)
        }
        if applied.scope != .local {
            pendingWrites.append(applied)
        }
        return ScriptVariableChange(scope: applied.scope, key: applied.key, isUnset: applied.value == nil, isSecret: applied.isSecret)
    }

    /// Queues a cookie a script set or removed for `commit`. What the report lists of it, without its value.
    func absorb(_ write: ScriptCookieWrite) -> ScriptCookieChange {
        pendingCookieWrites.append(write)
        let identity = write.identity
        return ScriptCookieChange(name: identity.name, domain: identity.domain, path: identity.path, isRemoved: write.isRemoval)
    }

    func setNextRequest(_ request: String?) {
        nextRequest = request.map(ScriptNextRequest.request) ?? .stop
    }

    /// Changes the report of the phase at `index`.
    func updatePhase(at index: Int, _ change: (inout ScriptPhaseReport) -> Void) {
        change(&report.phases[index])
    }

    /// Adds a phase's report as it starts, for a phase that reports as it runs; its index for `updatePhase`.
    func beginPhase(_ phase: ScriptPhaseReport) -> Int {
        report.phases.append(phase)
        return report.phases.count - 1
    }

    /// Every cookie in the project's jar, which holds none before the project sends anything.
    func projectCookies() -> [ScriptCookie] {
        projectCookieJar?.cookies(in: nil) ?? []
    }

    /// The project's jar, `nil` before the project sends anything.
    var projectCookieJar: ProjectCookieJar? {
        cookieJar(false)
    }

    /// Applies the cookies scripts set or removed to the jar now rather than after the phase, so a request they send
    /// carries them, as the scripts see it. A preview's never are.
    func commitCookies() {
        guard mode == .run, !pendingCookieWrites.isEmpty else {
            return
        }
        cookieJar(true)?.apply(pendingCookieWrites)
        pendingCookieWrites = []
    }

    /// Holds cookies a preview's request received as though a script set them: the scripts' later reads see them, as
    /// a run's would, while the preview's `commit`, which keeps nothing, drops them.
    func holdPreviewCookies(_ cookies: [ScriptCookie]) {
        guard mode == .preview else {
            return
        }
        pendingCookieWrites += cookies.map(ScriptCookieWrite.set)
    }

    /// The environment's name, as `rq.info` reports it.
    var environmentName: String {
        environments.active?.name ?? environments.defaultEnvironment.name
    }

    func levelReports(_ phase: ScriptPhase) -> [ScriptLevelReport] {
        (levels[phase] ?? []).map { ScriptLevelReport(kind: $0.kind, name: $0.name) }
    }

    private static func masked(_ error: ScriptError, _ redaction: SecretRedaction) -> ScriptError {
        var masked = error
        masked.message = redaction.apply(error.message)
        masked.stack = error.stack.map(redaction.apply)
        return masked
    }
}

/// What a script named for a folder or project run to run next.
enum ScriptNextRequest: Hashable, Sendable {
    /// A request's name or ID.
    case request(String)
    /// `null`: end the iteration.
    case stop
}
