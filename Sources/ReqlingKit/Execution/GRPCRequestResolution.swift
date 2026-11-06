import Foundation

/// Where and how a gRPC request connects, with templates resolved: what a call and a reflection lookup both need.
struct GRPCEndpoint {
    let target: GRPCTarget
    /// The target as typed with secrets masked, for the record.
    let shownTarget: String
    /// Request metadata, auth included, as sent; `shownMetadata` is the same rows masked.
    let metadata: [KeyValuePair]
    let shownMetadata: [KeyValuePair]
    /// The request's own deadline, if it sets one; `timeout(for:kind:keepsStreamOpen:)` decides what a call uses.
    let requestedTimeout: Duration?
    /// The Settings deadline.
    let defaultTimeout: Duration
    let verifiesServer: Bool
}

/// Turns a `GRPCRequestSpec` into what `GRPCExecutor` sends. The schema-dependent half (the method's kind and the
/// encoded messages) happens in `RequestRunner`, once the schema is known.
enum GRPCRequestResolution {
    static func endpoint(
        _ spec: GRPCRequestSpec,
        templates: inout RunTemplates,
        authChain: [HTTPAuth],
        defaults: AppSettings
    ) throws(RunFailure) -> GRPCEndpoint {
        let text = try templates.resolve(spec.target)
        let target: GRPCTarget
        do {
            target = try GRPCTarget(parsing: text.sent)
        } catch {
            // The sent text may hold a secret, so the message comes from parsing the masked one.
            let message: String
            do {
                _ = try GRPCTarget(parsing: text.shown)
                message = "The target “\(text.shown)” is not a valid host:port."
            } catch {
                message = error.localizedDescription
            }
            throw RunFailure(kind: .invalidRequest, message: message)
        }
        let auth = try authMetadata(HTTPRequestBuilder.effectiveAuth(spec.auth, chain: authChain), templates: &templates)
        var rows: [(key: ResolvedTemplate, value: ResolvedTemplate)] = []
        for row in spec.metadata where row.isEnabled && !row.key.trimmingCharacters(in: .whitespaces).isEmpty {
            rows.append((try templates.resolve(row.key), try templates.resolve(row.value)))
        }
        // A metadata row of the same name beats the auth's, as a header does over HTTP auth.
        let taken = Set(rows.map { $0.key.sent.lowercased() })
        rows += auth.filter { !taken.contains($0.key.sent.lowercased()) }
        return GRPCEndpoint(
            target: target,
            shownTarget: text.shown.trimmingCharacters(in: .whitespacesAndNewlines),
            metadata: rows.map { KeyValuePair(key: $0.key.sent, value: $0.value.sent) },
            shownMetadata: rows.map { KeyValuePair(key: $0.key.shown.lowercased(), value: $0.value.shown) },
            requestedTimeout: spec.deadlineSeconds.flatMap(duration),
            defaultTimeout: duration(defaults.grpcDeadlineSeconds) ?? .seconds(30),
            verifiesServer: spec.verifyTLS ?? defaults.verifyTLS
        )
    }

    /// The deadline a call runs under. An interactive call (one the editor keeps open to send into, client-streaming
    /// or bidirectional) gets none unless the request sets one, since the Settings default would cut off a person
    /// still typing messages. Every other call, agents' and tests' included, falls back to the Settings default, so
    /// an unattended call always ends. `kind` is `nil` when the schema has no such method; the run then fails anyway.
    static func timeout(for endpoint: GRPCEndpoint, kind: GRPCMethodKind?, keepsStreamOpen: Bool) -> Duration? {
        if let requested = endpoint.requestedTimeout {
            return requested
        }
        if keepsStreamOpen, kind?.clientStreams == true {
            return nil
        }
        return endpoint.defaultTimeout
    }

    /// `seconds` as a deadline, or `nil` when it is not a positive finite number. A request file can say anything, so
    /// it is clamped to the Settings range's maximum before the integer conversion, which would trap on `1e16`.
    static func duration(_ seconds: Double) -> Duration? {
        guard seconds.isFinite, seconds > 0 else {
            return nil
        }
        let milliseconds = min(max(seconds, 0.001), AppSettings.timeoutRange.upperBound) * 1000
        return .milliseconds(Int(milliseconds.rounded()))
    }

    /// The messages a call of `kind` sends from the spec: all of them when the client streams, otherwise the first,
    /// or `{}` when there is none (methods taking `google.protobuf.Empty` need nothing else).
    static func messages(_ spec: GRPCRequestSpec, kind: GRPCMethodKind) -> [String] {
        if kind.clientStreams {
            return spec.messages
        }
        return [spec.messages.first ?? "{}"]
    }

    /// Auth as gRPC carries it: Basic and Bearer in `authorization`, a header API key under its own name. gRPC has no
    /// query string, so an API key set to go in one cannot be sent.
    private static func authMetadata(
        _ auth: HTTPAuth,
        templates: inout RunTemplates
    ) throws(RunFailure) -> [(key: ResolvedTemplate, value: ResolvedTemplate)] {
        let authorization = ResolvedTemplate(sent: "authorization", shown: "authorization")
        switch auth {
        case .inherit, .none:
            return []
        case .basic(let username, let password):
            let username = try templates.resolve(username)
            let password = try templates.resolve(password)
            func credentials(_ username: String, _ password: String) -> String {
                "Basic \(Data("\(username):\(password)".utf8).base64EncodedString())"
            }
            let value = ResolvedTemplate(sent: credentials(username.sent, password.sent), shown: credentials(username.shown, password.shown))
            return [(authorization, value)]
        case .bearer(let token):
            let token = try templates.resolve(token)
            return [(authorization, ResolvedTemplate(sent: "Bearer \(token.sent)", shown: "Bearer \(token.shown)"))]
        case .apiKey(let name, let value, .header):
            return [(try templates.resolve(name), try templates.resolve(value))]
        case .apiKey(_, _, .query):
            throw RunFailure(
                kind: .invalidRequest,
                message: "gRPC has no query string, so this API key cannot be sent; set it to go in a header (metadata) instead."
            )
        }
    }
}
