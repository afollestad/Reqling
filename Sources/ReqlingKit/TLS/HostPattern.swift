/// Matches request hosts for client certificate selection: `api.example.com`, `*.example.com` (any depth of
/// subdomain, not the bare domain), optionally with `:port`. Matching ignores case.
public struct HostPattern: Hashable, Sendable {
    public let host: String
    public let port: Int?
    public let isWildcard: Bool

    public init?(_ pattern: String) {
        var text = pattern.trimmingCharacters(in: .whitespaces).lowercased()
        guard !text.isEmpty, !text.contains("/") else {
            return nil
        }
        var port: Int?
        if let colon = text.lastIndex(of: ":"), !text.hasPrefix("[") {
            guard let parsed = Int(text[text.index(after: colon)...]), (1...65535).contains(parsed) else {
                return nil
            }
            port = parsed
            text = String(text[..<colon])
        }
        isWildcard = text.hasPrefix("*.")
        host = isWildcard ? String(text.dropFirst(2)) : text
        guard !host.isEmpty, !host.contains("*") else {
            return nil
        }
        self.port = port
    }

    public func matches(host candidate: String, port candidatePort: Int?) -> Bool {
        if let port, port != candidatePort {
            return false
        }
        let candidate = candidate.lowercased()
        return isWildcard ? candidate.hasSuffix(".\(host)") : candidate == host
    }

    /// Higher wins when several patterns match: an exact host beats a wildcard, a longer suffix beats a shorter one,
    /// and a port-specific pattern beats a portless one.
    public var specificity: Int {
        (isWildcard ? 0 : 10_000) + host.split(separator: ".").count * 10 + (port == nil ? 0 : 1)
    }
}
