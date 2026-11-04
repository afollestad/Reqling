import Foundation

extension HTTPRequestBuilder {
    /// The automatic headers a request gets, before user headers override them; the editor lists these.
    ///
    /// They include what macOS adds below Reqling, so the list matches the wire: the URL loading system always sets
    /// `Host`, `Content-Length`, `Accept-Encoding`, and `Accept-Language`, gives a body with no type
    /// `application/x-www-form-urlencoded`, and fills in its own value for any switchable header turned off.
    public static func autoHeaders(for spec: HTTPRequestSpec, userAgent: String) -> [AutoHeader] {
        var headers = [
            AutoHeader(name: "Accept", value: "*/*", isOverridable: true, systemFallback: "*/*"),
            AutoHeader(name: "User-Agent", value: userAgent, isOverridable: true, systemFallback: "its own")
        ]
        if spec.method.bodyPolicy.allowsBody, spec.body.mode != .none {
            if let contentType = contentType(for: spec.body) {
                headers.insert(
                    AutoHeader(name: "Content-Type", value: contentType, isOverridable: true, systemFallback: Self.systemContentType),
                    at: 0
                )
            } else {
                headers.insert(AutoHeader(name: "Content-Type", value: Self.systemContentType, isOverridable: false), at: 0)
            }
            headers.append(AutoHeader(name: "Content-Length", value: "Calculated when sent", isOverridable: false))
        }
        headers.append(AutoHeader(name: "Host", value: "From the URL", isOverridable: false))
        headers.append(AutoHeader(name: "Accept-Encoding", value: "Chosen by macOS", isOverridable: false))
        headers.append(AutoHeader(name: "Accept-Language", value: "From your language settings", isOverridable: false))
        return headers
    }

    /// What the URL loading system sends for a body without a Content-Type.
    public static let systemContentType = "application/x-www-form-urlencoded"

    /// The Content-Type a body's mode implies, or `nil` for none (no body, or a raw body with no type).
    private static func contentType(for body: HTTPBody) -> String? {
        switch body.mode {
        case .none:
            nil
        case .raw:
            body.raw.contentType.isEmpty ? nil : body.raw.contentType
        case .urlEncoded:
            "application/x-www-form-urlencoded"
        case .formData:
            "multipart/form-data"
        case .binary:
            body.binary.contentType ?? "application/octet-stream"
        case .graphQL:
            "application/json"
        }
    }
}
