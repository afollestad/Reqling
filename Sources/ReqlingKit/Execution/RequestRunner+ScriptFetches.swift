import Foundation
import ReqlingScriptProtocol

/// Sends the requests scripts send (`rq.sendRequest`, `rq.runRequest`), as each `ScriptSession`'s performer
/// (`ScriptSession+Fetches.swift`). Never through `run`: a script's request is no run, so it records nothing, runs no
/// scripts, and leaves alone the run of a request it names, which `run` would replace. It shares the project's executor,
/// so its jar and connections, and its TLS certificates.
///
/// Only http and https go out, since a `file:` URL would read this Mac's files, which scripts never can.
extension RequestRunner {
    func performFetch(_ fetch: ScriptFetch, for session: ScriptSession) async -> ScriptFetchCompletion {
        let prepared: PreparedFetch
        do throws(RunFailure) {
            prepared = try prepareFetch(fetch, for: session)
        } catch {
            return ScriptFetchCompletion(outcome: .failed(error.message))
        }
        var request = prepared.request
        if session.mode == .run {
            session.commitCookies()
        } else {
            sendScriptsCookies(with: &request, from: session)
        }
        do {
            let record = try await executor(for: session.project).execute(request, tls: prepared.tls)
            if session.mode == .preview, let url = request.urlRequest.url,
               let setCookie = record.headers.first(where: { $0.key.caseInsensitiveCompare("Set-Cookie") == .orderedSame }) {
                // As a WebSocket handshake reads its own (`WebSocketHandshake`).
                let cookies = HTTPCookie.cookies(withResponseHeaderFields: ["Set-Cookie": setCookie.value], for: url)
                session.holdPreviewCookies(cookies.map(ScriptCookie.init))
            }
            let (response, body) = ScriptInputBuilder.fetched(record)
            return ScriptFetchCompletion(sent: prepared.label, outcome: .response(response), body: body)
        } catch {
            return ScriptFetchCompletion(sent: prepared.label, outcome: .failed(error.localizedDescription))
        }
    }

    /// Builds the request, as the session stands now: a saved one resolves against what scripts have set so far.
    private func prepareFetch(_ fetch: ScriptFetch, for session: ScriptSession) throws(RunFailure) -> PreparedFetch {
        guard let project = library.project(session.project), let document = project.document else {
            throw RunFailure(kind: .invalidRequest, message: "The project is not available.")
        }
        let paths = ProjectPathResolver(projectRoot: project.url, localPaths: workspace.localPaths(in: project.id))
        let prepared: PreparedFetch
        switch fetch {
        case .send(let request):
            let built: PreparedHTTPRequest
            do {
                built = try HTTPRequestBuilder.prepareLiteral(
                    request,
                    defaults: settings.settings.requestDefaults,
                    userAgent: userAgent,
                    redaction: SecretRedaction(secrets: session.allSecretValues)
                )
            } catch {
                throw RunFailure(kind: .invalidRequest, message: error.localizedDescription)
            }
            let tls = try tlsContext(for: built, project: project.id, document: document, paths: paths)
            prepared = PreparedFetch(request: built, tls: tls, label: "\(built.summary.method) \(built.summary.url)")
        case .run(let name, let variables):
            let item = try savedRequest(name, in: document)
            guard let spec = item.kind.httpSpec else {
                let kind = item.kind.name.title
                throw RunFailure(kind: .invalidRequest, message: "“\(item.name)” is a \(kind) request; rq.runRequest sends HTTP requests.")
            }
            // As a run resolves it, against what scripts have set so far: the request's own scripts don't run.
            var layers = session.layers
            layers.overrides.merge(variables) { $1 }
            let scope = VariableScope(layers: layers, environments: session.environments)
            let resolver = TemplateResolver(scope: scope, dynamic: dynamic)
            let context = RunContext(
                item: item,
                document: document,
                resolver: resolver,
                redaction: Self.redaction(scope: scope, resolver: resolver, carried: session.allSecretValues),
                paths: paths,
                environmentName: session.environmentName
            )
            let built = try preparedHTTP(spec, context: context, options: RunOptions())
            prepared = PreparedFetch(request: built, tls: try tls(for: built, project: project.id, context: context),
                                     label: "“\(item.name)” \(built.summary.method) \(built.summary.url)")
        }
        guard let scheme = prepared.request.urlRequest.url?.scheme?.lowercased(), ["http", "https"].contains(scheme) else {
            throw RunFailure(kind: .invalidRequest, message: "Scripts send only http and https requests.")
        }
        return prepared
    }

    /// The saved request a script names, by ID or else by name, as `rq.execution.setNextRequest` names one. A name
    /// several requests share is refused, listing them, rather than sending whichever comes first.
    private func savedRequest(_ target: String, in document: ProjectDocument) throws(RunFailure) -> RequestItem {
        let requests = document.allRequests
        if let match = requests.first(where: { $0.request.id.description == target.lowercased() }) {
            return match.request
        }
        let named = requests.filter { $0.request.name == target }
        guard named.count < 2 else {
            let paths = named.map { ($0.folderPath + [$0.request.name]).joined(separator: "/") }.joined(separator: ", ")
            throw RunFailure(kind: .invalidRequest, message: "Several requests are named “\(target)”: \(paths). Name one by its ID.")
        }
        guard let match = named.first else {
            throw RunFailure(kind: .invalidRequest, message: "This project has no request named “\(target)”.")
        }
        return match.request
    }

    /// A preview keeps nothing its scripts did, so its requests send the cookies the scripts see by hand, and what
    /// comes back reaches only the scripts' view (`ScriptSession.holdPreviewCookies`). A `Cookie` header the request
    /// names stands in for them, as it does in every request.
    private func sendScriptsCookies(with request: inout PreparedHTTPRequest, from session: ScriptSession) {
        guard request.urlRequest.httpShouldHandleCookies else {
            return
        }
        request.urlRequest.httpShouldHandleCookies = false
        guard let url = request.urlRequest.url, let cookies = session.scriptsCookieJar()?.storage.cookies(for: url), !cookies.isEmpty else {
            return
        }
        for (name, value) in HTTPCookie.requestHeaderFields(with: cookies) {
            request.urlRequest.setValue(value, forHTTPHeaderField: name)
        }
    }
}

/// A script's request, built and ready: what goes out, with which certificates, and how its console line names it.
private struct PreparedFetch {
    let request: PreparedHTTPRequest
    let tls: TLSContext
    let label: String
}
