import Foundation
import ReqlingTemplating

/// Masks a run's secret values in text that no masked resolution produced: URLSession and Security error messages,
/// and the final URL after redirects. It covers each secret as stored and as resolved, in the encodings a URL gives it,
/// and, for one that reads as a URL or a bare hostname, its host (a TLS error quotes just the host).
///
/// Matching ignores case, since URLs come back with their hosts lower-cased. Values shorter than
/// `VariableLayers.minimumSecretLength` are left alone, as the scripts' leak guard leaves them.
struct SecretRedaction: Sendable {
    /// Longest first, so a secret inside another is masked whole.
    let values: [String]
    /// The secrets as stored and as resolved, unencoded, for matching decoded URL components.
    let plainValues: [String]

    init(resolver: TemplateResolver) {
        let secrets = resolver.scope.entries.values.filter(\.isSecret).flatMap { entry in
            [entry.value, resolver.resolve(entry.value).value]
        }
        self.init(secrets: secrets)
    }

    /// Masks `secrets` as stored, with their encodings and hosts, as `init(resolver:)` masks a scope's: for values a
    /// script made secret, which no scope entry may carry any more.
    init(secrets: some Sequence<String>) {
        var values: Set<String> = []
        var plainValues: Set<String> = []
        for value in Set(secrets) {
            plainValues.insert(value)
            values.insert(value)
            values.insert(HTTPEncoding.queryComponent(value))
            values.insert(HTTPEncoding.formComponent(value))
            if let encoded = value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) {
                values.insert(encoded)
            }
            if let host = Self.host(in: value) {
                values.insert(host)
            }
        }
        self.values = values.filter { $0.count >= VariableLayers.minimumSecretLength }.sorted { $0.count > $1.count }
        self.plainValues = plainValues.filter { $0.count >= VariableLayers.minimumSecretLength }.sorted { $0.count > $1.count }
    }

    /// `url` with every path segment and query value that decodes to text containing a secret masked whole (the whole
    /// query item when its name holds one), then the rest of `apply`. A redirecting server re-encodes values its own
    /// way (`encodeURIComponent` keeps `!` but escapes `@`), so matching only Reqling's encodings lets a secret through.
    func apply(to url: URL) -> String {
        let text = url.absoluteString
        guard !plainValues.isEmpty, let components = URLComponents(string: text) else {
            return apply(text)
        }
        // Assembled from slices of `text`, so no index is used after a mutation.
        var masked = ""
        var cursor = text.startIndex
        if let path = components.rangeOfPath, !path.isEmpty {
            masked += text[cursor..<path.lowerBound]
            masked += text[path].split(separator: "/", omittingEmptySubsequences: false).map { segment in
                containsSecret(Self.decoded(segment, plusIsSpace: false)) ? Substring(TemplateResolver.mask) : segment
            }.joined(separator: "/")
            cursor = path.upperBound
        }
        if let query = components.rangeOfQuery {
            masked += text[cursor..<query.lowerBound]
            masked += text[query].split(separator: "&", omittingEmptySubsequences: false).map(maskQueryItem).joined(separator: "&")
            cursor = query.upperBound
        }
        masked += text[cursor...]
        return apply(masked)
    }

    /// Masks the value of `name=value`, or the whole item when its name holds a secret, so the key stays readable.
    private func maskQueryItem(_ item: Substring) -> Substring {
        let parts = item.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        if containsSecret(Self.decoded(parts[0], plusIsSpace: true)) {
            return Substring(TemplateResolver.mask)
        }
        guard parts.count == 2, containsSecret(Self.decoded(parts[1], plusIsSpace: true)) else {
            return item
        }
        return parts[0] + "=" + TemplateResolver.mask
    }

    private func containsSecret(_ text: String) -> Bool {
        plainValues.contains { text.range(of: $0, options: .caseInsensitive) != nil }
    }

    private static func decoded(_ component: Substring, plusIsSpace: Bool) -> String {
        let text = plusIsSpace ? component.replacingOccurrences(of: "+", with: " ") : String(component)
        return text.removingPercentEncoding ?? text
    }

    func apply(_ text: String) -> String {
        values.reduce(text) { text, secret in
            text.replacingOccurrences(of: secret, with: TemplateResolver.mask, options: .caseInsensitive)
        }
    }

    /// The host of a URL (`https://api.internal/x`) or of a bare hostname (`api.internal:8443/v1`, `localhost`), and
    /// `nil` for anything else. A bare value needs a dot, a port, or to be `localhost`, so `pw@server`, `prod/xyz`, or
    /// `admin:secret` never turn an ordinary word into a mask everywhere it appears.
    private static func host(in value: String) -> String? {
        if value.contains("://") {
            return URLComponents(string: value)?.host.flatMap { $0.isEmpty ? nil : $0 }
        }
        guard let match = value.wholeMatch(of: /([A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*)(:[0-9]+)?(?:\/\S*)?/) else {
            return nil
        }
        let host = String(match.1)
        guard host.contains(".") || match.2 != nil || host.lowercased() == "localhost" else {
            return nil
        }
        return host
    }
}
