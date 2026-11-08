import Foundation
import ReqlingScriptProtocol

/// A run's stream scripts, around an event stream, a WebSocket connection, or a gRPC call: started as the stream
/// opens, handed each event or message from the transport's `receive` without waiting (`ScriptSession.deliver`), and
/// ended before the post-response phase (`finishScripts`). Each call's results reach the run at once: committed values,
/// the secrets that mask what an agent reads, sends that resolve with what handlers set, and the live Tests tab.
extension RequestRunner {
    /// What a transport gives its run's stream scripts: what the stream opened with, and how they reach it. The session
    /// keeps these closures while `live` keeps the session, so they hold `live` weakly.
    struct StreamScriptsTransport {
        let opening: ScriptStreamOpening
        let canSend: Bool
        /// Whether the run still owns its key; a replaced or forgotten run must not publish.
        let isCurrent: @MainActor () -> Bool
        /// Points the run's later sends at what handlers set; `nil` for an event stream, which sends nothing.
        let refresh: (@MainActor (TemplateResolver, SecretRedaction) -> Void)?
        /// Delivers `rq.send`.
        let send: @MainActor (ScriptOutgoingMessage) -> ScriptSendFailure?
    }

    /// Starts `session`'s stream scripts as the run's stream opens, when it has any and may run them. `live` is the
    /// run's live record, which their results republish.
    func startStreamScripts(_ session: ScriptSession?, key: RunKey, live: some LiveRun, publishes: Bool, transport: StreamScriptsTransport) {
        guard let session, session.mode == .run, session.isTrusted == true, session.hasScripts(.stream), session.stream == nil else {
            return
        }
        let (isCurrent, refresh, send) = (transport.isCurrent, transport.refresh, transport.send)
        scriptPhases[key] = .stream
        var refreshed = session.layersRevision
        // Before each send too, so a secret a handler just set is masked in the message it then sends.
        let refreshIfChanged: @MainActor () -> Void = { [weak self, weak session] in
            guard let self, let session, let refresh, session.layersRevision != refreshed else {
                return
            }
            refreshed = session.layersRevision
            let resolution = liveResolution(for: session)
            refresh(resolution.resolver, resolution.redaction)
        }
        let hooks = ScriptStreamHooks(
            changed: { [weak self, weak session, weak live] in
                guard let self, let session, scriptSessions[key] === session else {
                    return
                }
                session.commitStream(to: library)
                // Now, not when the run ends, so an agent reading the stream while it's open can have it masked.
                if let run = liveStamps[key]?.id {
                    scriptSecrets.remember(session.secretValues, for: run)
                }
                refreshIfChanged()
                if publishes, let live, isCurrent() {
                    publishThrottled(live, key: key, isCurrent: isCurrent)
                }
            },
            send: { message in
                refreshIfChanged()
                return send(message)
            }
        )
        session.startStream(transport.opening, canSend: transport.canSend, runner: scripts, timeLimit: scriptTimeLimit, hooks: hooks)
    }

    /// What a run's later sends resolve against once scripts have set values: `runContext`'s resolver and redaction,
    /// from the session as it stands now.
    func liveResolution(for session: ScriptSession) -> (resolver: TemplateResolver, redaction: SecretRedaction) {
        let scope = session.scope
        let resolver = TemplateResolver(scope: scope, dynamic: dynamic)
        return (resolver, Self.redaction(scope: scope, resolver: resolver, carried: session.allSecretValues))
    }

    /// Masks every secret `scope` holds, as written and as resolved, and `carried`: secrets a run's scripts made, which
    /// may be in no scope any more yet still be what a server echoes.
    static func redaction(scope: VariableScope, resolver: TemplateResolver, carried: Set<String>) -> SecretRedaction {
        let scoped = scope.entries.values.filter(\.isSecret).flatMap { [$0.value, resolver.resolve($0.value).value] }
        return SecretRedaction(secrets: carried.union(scoped))
    }
}

extension RequestExchange {
    /// An event stream or WebSocket connection stopped by its `StreamLimit`, which ends its stream scripts as Stop does.
    var endedAtLimit: Bool {
        switch outcome {
        case .response(let response): response.eventStream?.end == .limit
        case .webSocket(let record): record.end == .limit
        case .grpc, .failure: false
        }
    }
}
