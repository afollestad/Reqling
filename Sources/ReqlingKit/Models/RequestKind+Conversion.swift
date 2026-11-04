/// Switching a saved request between HTTP and gRPC in place. Only what both protocols share carries over: auth, headers
/// as metadata, a scheme-and-host URL as the target (`https` meaning TLS), TLS verification, and the timeout as the
/// deadline. Everything else resets to the new kind's defaults.
extension RequestKind {
    public func converted(to name: Name) -> RequestKind {
        switch (self, name) {
        case (.http, .http), (.grpc, .grpc):
            return self
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
