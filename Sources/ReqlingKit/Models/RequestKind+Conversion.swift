/// Switching a saved request between HTTP, gRPC, and WebSocket in place. Only what both protocols share carries over:
/// auth, headers (as gRPC's metadata), TLS verification, and the timeout (as gRPC's deadline). HTTP and WebSocket also
/// share the URL (`http`↔`ws`, `https`↔`wss`) and its query; gRPC's target maps to a scheme-and-host URL (`https`
/// meaning TLS). Everything else resets to the new kind's defaults, and gRPC and WebSocket convert through HTTP.
extension RequestKind {
    public func converted(to name: Name) -> RequestKind {
        switch (self, name) {
        case (.http, .http), (.grpc, .grpc), (.webSocket, .webSocket):
            return self
        case (.http(let spec), .webSocket):
            return .webSocket(WebSocketRequestSpec(
                url: Self.swappingScheme(of: spec.url, [("https://", "wss://"), ("http://", "ws://")]),
                queryParameters: spec.queryParameters,
                headers: spec.headers,
                disabledAutoHeaders: spec.disabledAutoHeaders,
                auth: spec.auth,
                options: WebSocketRequestOptions(timeoutSeconds: spec.options.timeoutSeconds, verifyTLS: spec.options.verifyTLS)
            ))
        case (.webSocket(let spec), .http):
            return .http(HTTPRequestSpec(
                url: Self.swappingScheme(of: spec.url, [("wss://", "https://"), ("ws://", "http://")]),
                queryParameters: spec.queryParameters,
                headers: spec.headers,
                disabledAutoHeaders: spec.disabledAutoHeaders,
                auth: spec.auth,
                options: HTTPRequestOptions(timeoutSeconds: spec.options.timeoutSeconds, verifyTLS: spec.options.verifyTLS)
            ))
        case (.grpc, .webSocket), (.webSocket, .grpc):
            return converted(to: .http).converted(to: name)
        case (.http(let spec), .grpc):
            let target = Self.target(fromURL: spec.url)
            return .grpc(GRPCRequestSpec(
                target: target?.target ?? "",
                security: target?.security ?? .plaintext,
                metadata: spec.headers,
                deadlineSeconds: spec.options.timeoutSeconds,
                verifyTLS: spec.options.verifyTLS,
                auth: spec.auth
            ))
        case (.grpc(let spec), .http):
            return .http(HTTPRequestSpec(
                url: Self.url(fromTarget: spec.target, security: spec.security),
                headers: spec.metadata,
                auth: spec.auth,
                options: HTTPRequestOptions(timeoutSeconds: spec.deadlineSeconds, verifyTLS: spec.verifyTLS)
            ))
        }
    }

    /// Whether switching to `name` discards something: true exactly when switching back would not restore this request,
    /// so the check can never drift from what `converted(to:)` carries.
    public func losesContent(convertingTo name: Name) -> Bool {
        name != self.name && converted(to: name).converted(to: self.name) != self
    }

    /// The URL with its scheme swapped by the first pair whose prefix it has, case aside; any other URL stays as typed.
    private static func swappingScheme(of url: String, _ pairs: [(prefix: String, replacement: String)]) -> String {
        for (prefix, replacement) in pairs where url.lowercased().hasPrefix(prefix) {
            return replacement + url.dropFirst(prefix.count)
        }
        return url
    }

    /// Only a bare `http(s)://host[:port]`, with at most a trailing `/`, maps; a path, query, or credentials have no place
    /// in a gRPC target. String matching rather than `URLComponents`, which rejects `{{variables}}`.
    private static func target(fromURL url: String) -> (target: String, security: GRPCSecurity)? {
        for (scheme, security) in [("https://", GRPCSecurity.tls), ("http://", .plaintext)] where url.lowercased().hasPrefix(scheme) {
            var host = Substring(url.dropFirst(scheme.count))
            if host.hasSuffix("/") {
                host = host.dropLast()
            }
            guard !host.isEmpty, !host.contains(where: { "/?#@".contains($0) }) else {
                return nil
            }
            return (String(host), security)
        }
        return nil
    }

    /// A Unix socket target (`unix:/path`) has no HTTP URL.
    private static func url(fromTarget target: String, security: GRPCSecurity) -> String {
        guard !target.isEmpty, !target.contains(where: { "/?#@".contains($0) }) else {
            return ""
        }
        return "\(security == .tls ? "https" : "http")://\(target)"
    }
}
