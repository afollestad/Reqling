import Foundation

/// One cookie of a project's jar, as scripts read it, the helper mirrors it, and MCP describes it. `domain` never has
/// the leading dot `HTTPCookie` uses to mark a cookie its subdomains get too; `isHostOnly` says that instead.
public struct ScriptCookie: Hashable, Sendable, Codable {
    public var name: String
    public var value: String
    public var domain: String
    public var path: String
    /// `nil` for a session cookie, which lasts until Reqling quits: the jar is never saved.
    public var expires: Date?
    public var isSecure: Bool
    public var isHTTPOnly: Bool
    /// `lax`, `strict`, or `none`; `nil` when none was named.
    public var sameSite: String?
    /// Sent to `domain` itself only, not to its subdomains.
    public var isHostOnly: Bool

    public init(
        name: String,
        value: String,
        domain: String,
        path: String = "/",
        expires: Date? = nil,
        isSecure: Bool = false,
        isHTTPOnly: Bool = false,
        sameSite: String? = nil,
        isHostOnly: Bool = true
    ) {
        self.name = name
        self.value = value
        self.domain = domain
        self.path = path
        self.expires = expires
        self.isSecure = isSecure
        self.isHTTPOnly = isHTTPOnly
        self.sameSite = sameSite
        self.isHostOnly = isHostOnly
    }

    /// Foundation marks a cookie that subdomains get with a leading dot on its domain, and only that way.
    public init(_ cookie: HTTPCookie) {
        let isHostOnly = !cookie.domain.hasPrefix(".")
        self.init(
            name: cookie.name,
            value: cookie.value,
            domain: isHostOnly ? cookie.domain : String(cookie.domain.dropFirst()),
            path: cookie.path,
            expires: cookie.expiresDate,
            isSecure: cookie.isSecure,
            isHTTPOnly: cookie.isHTTPOnly,
            sameSite: cookie.sameSitePolicy?.rawValue.lowercased(),
            isHostOnly: isHostOnly
        )
    }

    public var identity: ScriptCookieIdentity {
        ScriptCookieIdentity(name: name, domain: domain, isHostOnly: isHostOnly, path: path)
    }

    /// The cookie as a jar keeps it; `nil` only when Foundation refuses its properties.
    public var httpCookie: HTTPCookie? {
        var properties: [HTTPCookiePropertyKey: Any] = [.name: name, .value: value, .domain: identity.storedDomain, .path: path]
        if let expires {
            properties[.expires] = expires
        }
        if isSecure {
            properties[.secure] = "TRUE"
        }
        if isHTTPOnly {
            properties[Self.httpOnlyKey] = "TRUE"
        }
        if let sameSite {
            properties[.sameSitePolicy] = sameSite
        }
        return HTTPCookie(properties: properties)
    }

    /// Foundation reads `HttpOnly` from the properties but names no constant for it.
    private static let httpOnlyKey = HTTPCookiePropertyKey("HttpOnly")
}

/// What makes a cookie the one a jar replaces or removes: a jar holds one cookie per name, domain, and path.
public struct ScriptCookieIdentity: Hashable, Sendable, Codable {
    public var name: String
    public var domain: String
    public var isHostOnly: Bool
    public var path: String

    public init(name: String, domain: String, isHostOnly: Bool, path: String) {
        self.name = name
        self.domain = domain
        self.isHostOnly = isHostOnly
        self.path = path
    }

    /// The domain as `HTTPCookie` holds it.
    var storedDomain: String {
        isHostOnly ? domain : ".\(domain)"
    }

    func matches(_ cookie: HTTPCookie) -> Bool {
        cookie.name == name && cookie.path == path && cookie.domain.caseInsensitiveCompare(storedDomain) == .orderedSame
    }
}

/// One change a script makes to the jar, applied in order (`HTTPCookieStorage.apply`).
public enum ScriptCookieWrite: Hashable, Sendable, Codable {
    case set(ScriptCookie)
    case remove(ScriptCookieIdentity)

    public var identity: ScriptCookieIdentity {
        switch self {
        case .set(let cookie): cookie.identity
        case .remove(let identity): identity
        }
    }

    public var isRemoval: Bool {
        if case .remove = self {
            return true
        }
        return false
    }
}

/// Why a cookie couldn't be read or set, in words that name no API, so scripts and MCP report it alike.
public struct ScriptCookieError: Error, Hashable, Sendable {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }
}
