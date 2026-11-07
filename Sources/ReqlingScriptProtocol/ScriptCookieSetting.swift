import Foundation

/// A cookie a script or agent asks to set, checked against its scope before anything reaches a jar. Foundation's
/// `HTTPCookie` accepts names and values no server could read (`"a b"`, `"v;x"`), so every rule a `Set-Cookie` would
/// impose is enforced here, for scripts and MCP alike.
public struct ScriptCookieSetting: Hashable, Sendable {
    public var name: String
    public var value: String
    /// `/` when `nil`: an API client wants a cookie it sets to go with every request to the host, not only those under
    /// the URL's directory, as RFC 6265's default path would have it.
    public var path: String?
    /// The host itself or a parent of it, which makes the cookie go to the domain's subdomains too; `nil` keeps it to
    /// the scope's host alone.
    public var domain: String?
    /// `nil` for a session cookie.
    public var expires: Date?
    public var isSecure: Bool
    public var isHTTPOnly: Bool
    /// `lax`, `strict`, or `none`, in any case.
    public var sameSite: String?

    public init(
        name: String,
        value: String,
        path: String? = nil,
        domain: String? = nil,
        expires: Date? = nil,
        isSecure: Bool = false,
        isHTTPOnly: Bool = false,
        sameSite: String? = nil
    ) {
        self.name = name
        self.value = value
        self.path = path
        self.domain = domain
        self.expires = expires
        self.isSecure = isSecure
        self.isHTTPOnly = isHTTPOnly
        self.sameSite = sameSite
    }

    /// What setting it does to the jar `scope` reads: a remove once `expires` has passed, as a browser does.
    public func write(for scope: ScriptCookieScope, limits: ScriptLimits = .standard, now: Date = Date()) throws(ScriptCookieError)
        -> ScriptCookieWrite {
        guard !name.isEmpty else {
            throw ScriptCookieError("A cookie needs a name.")
        }
        guard name.utf8.allSatisfy(Self.isTokenByte) else {
            throw ScriptCookieError(
                "“\(name)” can't be a cookie's name: names can't hold spaces, control characters, or ( ) < > @ , ; : \\ \" / [ ] ? = { }."
            )
        }
        guard Self.isCookieValue(value) else {
            throw ScriptCookieError(
                "A cookie's value can't hold spaces, quotes, commas, semicolons, backslashes, or control characters; "
                    + "encode it first, as encodeURIComponent does."
            )
        }
        guard name.utf8.count + value.utf8.count <= limits.cookieLength else {
            throw ScriptCookieError("A cookie's name and value can hold at most \(limits.cookieLength) bytes together.")
        }
        let path = path ?? "/"
        guard path.hasPrefix("/"), !path.utf8.contains(where: { $0 < 0x20 || $0 == 0x7F || $0 == UInt8(ascii: ";") }) else {
            throw ScriptCookieError("A cookie's path must start with / and can't hold semicolons or control characters, not “\(path)”.")
        }
        let (cookieDomain, isHostOnly) = try domain(in: scope)
        let sameSite = try sameSitePolicy()
        let cookie = ScriptCookie(
            name: name,
            value: value,
            domain: cookieDomain,
            path: path,
            expires: expires,
            isSecure: isSecure,
            isHTTPOnly: isHTTPOnly,
            sameSite: sameSite,
            isHostOnly: isHostOnly
        )
        if let expires, expires <= now {
            return .remove(cookie.identity)
        }
        return .set(cookie)
    }

    /// The cookie's domain and whether it's host-only. An IP address has no parent domains, so a cookie for one is
    /// always the host's alone.
    private func domain(in scope: ScriptCookieScope) throws(ScriptCookieError) -> (String, Bool) {
        let host = scope.host
        guard !host.isEmpty else {
            throw ScriptCookieError("Cookies need a URL with a host.")
        }
        guard let domain else {
            return (host, true)
        }
        let named = domain.trimmingCharacters(in: .whitespaces).trimmingPrefix(".").lowercased()
        if named == host {
            return (host, Self.isIPAddress(host))
        }
        let isParent = !Self.isIPAddress(host) && host.hasSuffix(".\(named)") && named.contains(".")
        guard isParent else {
            throw ScriptCookieError("A cookie for “\(host)” can name that host or a parent domain of it, not “\(domain)”.")
        }
        return (named, false)
    }

    private func sameSitePolicy() throws(ScriptCookieError) -> String? {
        guard let sameSite else {
            return nil
        }
        let policy = sameSite.lowercased()
        guard ["lax", "strict", "none"].contains(policy) else {
            throw ScriptCookieError("A cookie's SameSite is Lax, Strict, or None, not “\(sameSite)”.")
        }
        return policy
    }

    /// RFC 6265's `token`: visible ASCII but its separators.
    private static func isTokenByte(_ byte: UInt8) -> Bool {
        (0x21...0x7E).contains(byte) && !tokenSeparators.contains(byte)
    }

    private static let tokenSeparators = Set(Array("()<>@,;:\\\"/[]?={}".utf8))

    /// RFC 6265's `cookie-value`: `cookie-octet`s, optionally wrapped in double quotes.
    private static func isCookieValue(_ value: String) -> Bool {
        var bytes = value.utf8[...]
        if bytes.count >= 2, bytes.first == UInt8(ascii: "\""), bytes.last == UInt8(ascii: "\"") {
            bytes = bytes.dropFirst().dropLast()
        }
        return bytes.allSatisfy { byte in
            byte == 0x21 || (0x23...0x2B).contains(byte) || (0x2D...0x3A).contains(byte) || (0x3C...0x5B).contains(byte)
                || (0x5D...0x7E).contains(byte)
        }
    }

    private static func isIPAddress(_ host: String) -> Bool {
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        return host.contains(":") || (octets.count == 4 && octets.allSatisfy { UInt8($0) != nil })
    }
}
