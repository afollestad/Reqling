import Foundation

/// Which of a jar's cookies a script or agent means. A URL means exactly what a request to it sends, matched by
/// Foundation's own `cookies(for:)`, as URLSession matches what it sends, so the two never disagree. A bare domain
/// means every cookie its host gets from itself and its parent domains, whatever their path or `Secure` flag.
public enum ScriptCookieScope: Hashable, Sendable {
    case url(URL)
    /// A lowercased host, without a leading dot.
    case domain(String)

    /// Text with `://` is a URL, and so is anything that isn't a plain host name (`localhost:8080`, `example.com/api`),
    /// read as `RequestURLText` reads a request's; `ws` and `wss` match as `http` and `https`, as their handshakes do.
    public static func parse(_ text: String) throws(ScriptCookieError) -> ScriptCookieScope {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ScriptCookieError("Cookies need a URL or a domain.")
        }
        if !trimmed.contains("://"), let host = bareHost(trimmed) {
            return .domain(host)
        }
        return try requestURL(trimmed)
    }

    /// `text` read as a URL alone, as a request's own URL is: `example.com` means `http://example.com/`.
    public static func requestURL(_ text: String) throws(ScriptCookieError) -> ScriptCookieScope {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = RequestURLText.components(trimmed) else {
            throw ScriptCookieError("“\(trimmed)” isn't a URL or a domain.")
        }
        switch components.scheme?.lowercased() {
        case "http", "ws": components.scheme = "http"
        case "https", "wss": components.scheme = "https"
        default: throw ScriptCookieError("Cookies belong to http and https URLs, not “\(trimmed)”.")
        }
        components.query = nil
        components.fragment = nil
        guard let url = components.url else {
            throw ScriptCookieError("“\(trimmed)” isn't a URL or a domain.")
        }
        return .url(url)
    }

    /// The host cookies set here are for.
    public var host: String {
        switch self {
        case .url(let url): url.host(percentEncoded: false)?.lowercased() ?? ""
        case .domain(let host): host
        }
    }

    /// The canonical text, which `parse` reads back as this scope.
    public var text: String {
        switch self {
        case .url(let url): url.absoluteString
        case .domain(let host): host
        }
    }

    /// Whether the jar would send `cookie` to some URL on this domain's host.
    func covers(_ cookie: HTTPCookie) -> Bool {
        let stored = cookie.domain.lowercased()
        guard stored.hasPrefix(".") else {
            return stored == host
        }
        let domain = stored.dropFirst()
        return host == domain || host.hasSuffix(".\(domain)")
    }

    /// Letters, digits, `-`, `.`, and `_` alone, an optional leading dot dropped.
    private static func bareHost(_ text: String) -> String? {
        let host = (text.hasPrefix(".") ? String(text.dropFirst()) : text).lowercased()
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-._")
        guard !host.isEmpty, host.unicodeScalars.allSatisfy(allowed.contains) else {
            return nil
        }
        return host
    }
}

extension HTTPCookieStorage {
    /// The cookies `scope` covers, or every cookie for `nil`, without any that have expired. A URL's come in
    /// Foundation's order, the most specific path first; the rest by domain, then path, most specific first.
    public func cookies(in scope: ScriptCookieScope?, now: Date = Date()) -> [HTTPCookie] {
        let found: [HTTPCookie] = switch scope {
        case .url(let url): cookies(for: url) ?? []
        case .domain: (cookies ?? []).filter { scope?.covers($0) == true }.sorted(by: Self.mostSpecificFirst)
        case nil: (cookies ?? []).sorted(by: Self.mostSpecificFirst)
        }
        return found.filter { $0.expiresDate.map { $0 > now } ?? true }
    }

    /// Changes one cookie, never replacing the jar, so a `Set-Cookie` stored meanwhile by a request in flight stays.
    public func apply(_ write: ScriptCookieWrite) {
        switch write {
        case .set(let cookie):
            if let stored = cookie.httpCookie {
                setCookie(stored)
            }
        case .remove(let identity):
            for cookie in cookies ?? [] where identity.matches(cookie) {
                deleteCookie(cookie)
            }
        }
    }

    private static func mostSpecificFirst(_ first: HTTPCookie, _ second: HTTPCookie) -> Bool {
        let firstDomain = first.domain.trimmingPrefix(".")
        let secondDomain = second.domain.trimmingPrefix(".")
        if firstDomain.count != secondDomain.count {
            return firstDomain.count > secondDomain.count
        }
        if firstDomain != secondDomain {
            return firstDomain < secondDomain
        }
        if first.path.count != second.path.count {
            return first.path.count > second.path.count
        }
        return first.name < second.name
    }
}
