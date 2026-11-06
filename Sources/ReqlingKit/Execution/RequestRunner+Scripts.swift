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
            levels: levels
        )
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
    /// stopped. What they set is committed either way.
    func runPreRequestScripts(_ session: ScriptSession, key: RunKey, options: RunOptions) async -> RunFailure? {
        guard await resolveTrust(session, options: options), session.hasScripts(.preRequest) else {
            return nil
        }
        scriptPhases[key] = .preRequest
        let outcome = await session.run(.preRequest, response: nil, runner: scripts, timeLimit: scriptTimeLimit)
        if scriptPhases[key] == .preRequest {
            scriptPhases[key] = nil
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
        finished.scriptReport = session.report.isEmpty ? nil : session.maskedReport()
        return finished
    }

    /// The report for a run Reqling quits on: its post-response phase didn't run, or didn't finish.
    func quitReport(for key: RunKey) -> ScriptReport? {
        guard let session = scriptSessions[key], session.isTrusted == true else {
            return nil
        }
        session.skip(.postResponse, reason: .quit)
        return session.report.isEmpty ? nil : session.maskedReport()
    }
}
