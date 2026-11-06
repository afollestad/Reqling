import Foundation
import ReqlingScriptProtocol
import ReqlingTemplating

/// One run's scripts: what runs in each phase, taken when the run starts so an edit mid-run never changes it, and the
/// state the phases share — the variables as scripts left them, the request changes a pre-request script made, and
/// the report. The only interpreter of the helper's events.
///
/// Values scripts set for an environment or Global are committed to `CurrentValueStore` after each phase, whatever
/// its outcome, so what a script set before it threw, timed out, or was stopped still lands. A preview, which only
/// shows what a request would send, commits nothing.
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
    /// `nil` until the run has decided; `false` runs the request without its scripts.
    var isTrusted: Bool?
    private(set) var layers: VariableLayers
    private(set) var changes: [ScriptRequestChange] = []
    private(set) var report = ScriptReport()
    /// Every value a script made secret this run, which masking covers even after a later `unset` hides it from the
    /// layers.
    private(set) var secretValues: Set<String> = []
    private var pendingWrites: [VariableWrite] = []

    init(
        project: ProjectID,
        item: RequestItem,
        mode: Mode,
        scope: VariableScope,
        environments: VariableScope.Environments,
        levels: [ScriptPhase: [ScriptLevelSource]]
    ) {
        self.project = project
        self.item = item
        self.mode = mode
        self.environments = environments
        self.levels = levels
        environmentID = environments.active?.id ?? environments.defaultEnvironment.id
        layers = scope.layers
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

    /// Runs a phase in the helper, applying its events as they arrive. Cancelling the task awaiting this kills the
    /// helper.
    func run(
        _ phase: ScriptPhase,
        response: (snapshot: ScriptResponseSnapshot, blobs: [Data])?,
        runner: any ScriptRunning,
        timeLimit: Duration
    ) async -> PhaseOutcome {
        guard let phaseLevels = levels[phase], !phaseLevels.isEmpty else {
            return .finished
        }
        let input = ScriptRunnerInput(
            phase: phase,
            levels: phaseLevels,
            variables: layers,
            info: ScriptRunInfo(
                requestName: item.name,
                requestID: item.id.description,
                protocolName: item.kind.name.rawValue,
                environmentName: environments.active?.name ?? environments.defaultEnvironment.name,
                defaultEnvironmentName: environments.defaultEnvironment.name
            ),
            request: ScriptInputBuilder.request(kind),
            response: response?.snapshot,
            runtimeDirectory: ""
        )
        let execution = runner.run(input, blobs: response?.blobs ?? [], timeLimit: timeLimit)
        var phaseReport = ScriptPhaseReport(phase: phase, levels: levelReports(phase))
        await withTaskCancellationHandler {
            for await event in execution.events {
                apply(event, in: phase, to: &phaseReport)
            }
        } onCancel: {
            execution.cancel()
        }
        let termination = await execution.termination()
        var outcome: PhaseOutcome = phaseReport.levels.contains { $0.error != nil } ? .failed : .finished
        switch termination {
        case .finished:
            break
        case .timedOut:
            let seconds = Int(timeLimit / .seconds(1))
            phaseReport.error = ScriptError(
                name: "TimeoutError",
                message: "The \(phase.title.lowercased()) scripts didn't finish within \(seconds) s, the time limit in Settings ▸ Requests."
            )
            outcome = .failed
        case .cancelled:
            outcome = .cancelled
        case .failed(let message):
            phaseReport.error = ScriptError(message: message)
            outcome = .failed
        }
        report.phases.append(phaseReport)
        return outcome
    }

    /// Stores what the last phase set for an environment or Global as this Mac's current values. Writes for a project
    /// or environment deleted meanwhile are dropped, so a run can't bring them back.
    func commit(to library: ProjectLibrary) {
        let writes = pendingWrites
        pendingWrites = []
        guard mode == .run, !writes.isEmpty, let document = library.document(project) else {
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

    /// The report with every secret the run touched masked in what scripts printed, named, or threw.
    func maskedReport() -> ScriptReport {
        let redaction = SecretRedaction(secrets: allSecretValues)
        var masked = report
        for phase in masked.phases.indices {
            masked.phases[phase].console = masked.phases[phase].console.map { entry in
                ScriptConsoleEntry(level: entry.level, severity: entry.severity, text: redaction.apply(entry.text))
            }
            masked.phases[phase].error = masked.phases[phase].error.map { Self.masked($0, redaction) }
            for level in masked.phases[phase].levels.indices {
                masked.phases[phase].levels[level].error = masked.phases[phase].levels[level].error.map { Self.masked($0, redaction) }
                masked.phases[phase].levels[level].tests = masked.phases[phase].levels[level].tests.map { test in
                    ScriptTestReport(name: redaction.apply(test.name), result: test.result, message: test.message.map(redaction.apply))
                }
            }
        }
        return masked
    }

    private func apply(_ event: ScriptRunnerEvent, in phase: ScriptPhase, to phaseReport: inout ScriptPhaseReport) {
        switch event {
        case .variable(let write):
            let applied = layers.apply(write)
            if applied.isSecret, let value = applied.value {
                secretValues.insert(value)
            }
            if applied.scope != .local {
                pendingWrites.append(applied)
            }
            phaseReport.variableChanges.append(ScriptVariableChange(
                scope: applied.scope,
                key: applied.key,
                isUnset: applied.value == nil,
                isSecret: applied.isSecret
            ))
        case .request(let change) where phase == .preRequest:
            changes.append(change)
        case .console(let level, let severity, let text) where phaseReport.console.count <= ScriptLimits.standard.consoleEntries:
            phaseReport.console.append(ScriptConsoleEntry(level: level, severity: severity, text: text))
        case .test(let level, let name, let result, let message) where phaseReport.levels.indices.contains(level):
            phaseReport.levels[level].tests.append(ScriptTestReport(name: name, result: result, message: message))
        case .levelFailed(let level, let error) where phaseReport.levels.indices.contains(level):
            phaseReport.levels[level].error = error
        default:
            break
        }
    }

    private func levelReports(_ phase: ScriptPhase) -> [ScriptLevelReport] {
        (levels[phase] ?? []).map { ScriptLevelReport(kind: $0.kind, name: $0.name) }
    }

    private static func masked(_ error: ScriptError, _ redaction: SecretRedaction) -> ScriptError {
        var masked = error
        masked.message = redaction.apply(error.message)
        masked.stack = error.stack.map(redaction.apply)
        return masked
    }
}
