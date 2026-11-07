import Foundation
import ReqlingScriptProtocol

/// A run's scripts around its request: deciding trust, running the pre-request phase before the request is prepared,
/// and the post-response phase on what came back, then attaching the masked report before the run is recorded.
/// `ScriptSession` holds what the phases share.
extension RequestRunner {
    /// One run's scripts, or `nil` when none would run for `item`.
    func scriptSession(for item: RequestItem, in project: ProjectID, options: RunOptions, mode: ScriptSession.Mode) -> ScriptSession? {
        guard let document = library.document(project) else {
            return nil
        }
        var levels: [ScriptPhase: [ScriptLevelSource]] = [:]
        for phase in ScriptPhase.allCases {
            let phaseLevels = document.scriptLevels(of: item, phase: phase)
            if !phaseLevels.isEmpty {
                levels[phase] = phaseLevels
            }
        }
        guard !levels.isEmpty, let environment = runEnvironment(in: document, project: project, options: options) else {
            return nil
        }
        library.reloadSecretsIfUnread(for: project)
        let scope = VariableScope(
            global: library.globalEnvironment,
            document: document,
            activeEnvironmentID: environment.id,
            currentValues: library.currentValues.snapshot(for: project),
            overrides: options.variableOverrides
        )
        return ScriptSession(
            project: project,
            item: item,
            mode: mode,
            scope: scope,
            environments: VariableScope.Environments(
                global: library.globalEnvironment,
                defaultEnvironment: document.defaultEnvironment,
                active: document.isDefaultEnvironment(environment.id) ? nil : environment
            ),
            levels: levels,
            secretSink: options.scriptSecrets
        )
    }

    /// Runs `request`'s pre-request scripts for something that only shows or fetches what it would send (a preview, an
    /// introspection, a reflection lookup), so it matches what a send builds. Nothing they set is kept and nothing is
    /// recorded; `nil` when no scripts would run. Scripts that fail or are stopped throw, as they stop a run.
    func previewScripts(_ request: RequestNodeID, in project: ProjectID, options: RunOptions) async throws(RunFailure) -> ScriptSession? {
        guard let item = item(request, in: project, options: options),
              let session = scriptSession(for: item, in: project, options: options, mode: .preview) else {
            return nil
        }
        if let failure = await runPreRequestScripts(session, key: nil, options: options) {
            throw failure
        }
        return session
    }

    var scriptTimeLimit: Duration {
        .seconds(settings.settings.scriptTimeLimitSeconds)
    }

    /// Settles whether the session's scripts run. A project asks once, and every run waiting meanwhile shares the
    /// answer; a dismissed question runs without scripts this time and asks again next time. Untrusted, each phase
    /// with scripts is reported as skipped, so the response says why nothing ran.
    func resolveTrust(_ session: ScriptSession, options: RunOptions) async -> Bool {
        if let decided = session.isTrusted {
            return decided
        }
        let trusted: Bool
        switch workspace.projectState(session.project).scriptTrust {
        case .trusted:
            trusted = true
        case .declined:
            trusted = false
        case .unknown:
            trusted = await askTrust(for: session, options: options)
        }
        session.isTrusted = trusted
        if !trusted {
            for phase in ScriptPhase.allCases {
                session.skip(phase, reason: .untrusted)
            }
        }
        return trusted
    }

    private func askTrust(for session: ScriptSession, options: RunOptions) async -> Bool {
        guard options.mayPromptForTrust, let trustDecider, let name = library.document(session.project)?.name else {
            return false
        }
        let project = session.project
        let prompt = trustPrompts[project] ?? Task {
            await trustDecider.decideScriptTrust(projectName: name, files: session.files)
        }
        trustPrompts[project] = prompt
        let answer = await prompt.value
        if trustPrompts[project] == prompt {
            trustPrompts[project] = nil
        }
        if let answer {
            workspace.updateProject(project) { $0.scriptTrust = answer ? .trusted : .declined }
        }
        return answer ?? false
    }

    /// Runs the pre-request phase, when trusted; returns the failure that stops the run, if its scripts failed or were
    /// stopped. What they set is committed either way, except in a preview. `key` is the run's, for `scriptPhases`; a
    /// preview has none.
    func runPreRequestScripts(_ session: ScriptSession, key: RunKey?, options: RunOptions) async -> RunFailure? {
        guard await resolveTrust(session, options: options), session.hasScripts(.preRequest) else {
            return nil
        }
        if let key {
            scriptPhases[key] = .preRequest
        }
        let outcome = await session.run(.preRequest, response: nil, runner: scripts, timeLimit: scriptTimeLimit)
        if let key, scriptPhases[key] == .preRequest {
            scriptPhases[key] = nil
        }
        // Now, not when the run ends, so an agent reading a stream still open can have it masked.
        if let key, let run = liveStamps[key]?.id {
            scriptSecrets.remember(session.secretValues, for: run)
        }
        session.commit(to: library)
        switch outcome {
        case .finished:
            return nil
        case .cancelled:
            return RunFailure(kind: .cancelled, message: HTTPExecutionError.cancelled.localizedDescription)
        case .failed:
            let summary = session.report.phase(.preRequest)?.failureSummary ?? "The pre-request script failed."
            return RunFailure(kind: .script, message: summary)
        }
    }

    /// Runs the post-response phase on a finished exchange, when trusted and there is a response, then attaches the
    /// masked report. The phase runs in its own task (`scriptTasks`), so it outlives the Stop that ended a stream.
    func finishScripts(_ exchange: RequestExchange, key: RunKey, session: ScriptSession) async -> RequestExchange {
        var finished = exchange
        if session.isTrusted == true, session.hasScripts(.postResponse) {
            if let response = ScriptInputBuilder.response(exchange.outcome) {
                let runner = scripts
                let timeLimit = scriptTimeLimit
                let post = Task {
                    await session.run(.postResponse, response: response, runner: runner, timeLimit: timeLimit)
                }
                scriptTasks[key] = post
                scriptPhases[key] = .postResponse
                pendingPostExchanges[key] = exchange
                _ = await withTaskCancellationHandler {
                    await post.value
                } onCancel: {
                    post.cancel()
                }
                if scriptTasks[key] == post {
                    scriptTasks[key] = nil
                    scriptPhases[key] = nil
                    pendingPostExchanges[key] = nil
                }
                session.commit(to: library)
            } else if let kind = exchange.failure?.kind, ![.script, .cancelled].contains(kind) {
                // A failed pre-request script, or a stop, already says why nothing came back.
                session.skip(.postResponse, reason: .requestFailed)
            }
        }
        finished.scriptReport = session.shownReport
        return finished
    }

    /// The report for a run Reqling quits on: its post-response phase didn't run, or didn't finish.
    func quitReport(for key: RunKey) -> ScriptReport? {
        guard let session = scriptSessions[key], session.isTrusted == true else {
            return nil
        }
        session.skip(.postResponse, reason: .quit)
        return session.shownReport
    }
}

extension RunFailure {
    /// The failure, noting that the request's pre-request scripts didn't run when the project isn't trusted, since a
    /// header they set may be what the server missed.
    @MainActor
    func noting(_ session: ScriptSession?) -> RunFailure {
        guard let session, session.isTrusted == false, session.hasScripts(.preRequest) else {
            return self
        }
        var noted = self
        noted.message += " The request's pre-request scripts didn't run, since this project's scripts aren't trusted on this Mac."
        return noted
    }
}

/// The values each recorded run's scripts made secret, so masking a past run for an agent covers them too. Kept in
/// memory only, never written anywhere: a run-local secret exists nowhere else once its run ends, and an agent reading
/// a run after Reqling relaunched gets its response withheld instead (`ScriptReport.madeRunLocalSecrets`).
struct ScriptSecretMemory {
    /// The newest runs whose secrets are kept; older ones fall back to withholding.
    static let capacity = 500

    private var secrets: [RunID: Set<String>] = [:]
    private var order: [RunID] = []

    mutating func remember(_ values: Set<String>, for run: RunID) {
        guard !values.isEmpty else {
            return
        }
        if secrets.updateValue(values, forKey: run) == nil {
            order.append(run)
        }
        if order.count > Self.capacity {
            secrets[order.removeFirst()] = nil
        }
    }

    func secrets(of run: RunID) -> Set<String>? {
        secrets[run]
    }
}
