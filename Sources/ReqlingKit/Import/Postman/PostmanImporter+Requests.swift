import Foundation
import ReqlingScriptProtocol

/// A Postman request as an HTTP request: its method, URL and query, headers, body, auth, settings, and scripts.
extension PostmanPlanner {
    mutating func request(_ item: PostmanJSON, name: String, path: [String], profile: [String: PostmanJSON]) -> RequestItem {
        counts.requests += 1
        counts.savedResponses += item["response"]?.array?.count ?? 0
        let id = RequestNodeID()
        let owner = PostmanImportNote.Owner.node(path)
        var spec = HTTPRequestSpec()
        let request = item["request"]
        if let url = request?.string {
            // A request given as its URL alone is a GET.
            spec.url = url
            spec = spec.normalized()
            spec.url = pathVariables(in: Self.withoutFragment(spec.url), values: [], owner: owner)
        } else if let request {
            let method = request["method"]?.string?.trimmingCharacters(in: .whitespaces) ?? ""
            spec.method = HTTPMethod(rawValue: method.isEmpty ? "GET" : method)
            (spec.url, spec.queryParameters) = url(request["url"], owner: owner)
            spec.headers = Self.headers(request["header"])
            body(request["body"], into: &spec, request: id, owner: owner, sendsDespiteMethod: profile["disableBodyPruning"]?.bool == true)
            spec.auth = auth(request["auth"], owner: owner, inheritedByDefault: true)
        }
        Self.apply(profile, to: &spec)
        let scripts = scripts(item["event"], owner: owner, protocols: ScriptAnalysisContext.protocols(for: .http))
        noteUnknownDynamicVariables(in: spec, owner: owner)
        return RequestItem(id: id, name: name, kind: .http(spec), scripts: scripts)
    }

    // MARK: - URL

    /// The URL without its query, and the query as rows. Postman's `query` list keeps the rows it turned off, which
    /// `raw` leaves out, so it's the source when there is one.
    private mutating func url(_ url: PostmanJSON?, owner: PostmanImportNote.Owner) -> (String, [KeyValuePair]) {
        guard let url else {
            return ("", [])
        }
        if let raw = url.string {
            var spec = HTTPRequestSpec(url: raw).normalized()
            spec.url = pathVariables(in: Self.withoutFragment(spec.url), values: [], owner: owner)
            return (spec.url, spec.queryParameters)
        }
        let raw = url["raw"]?.string ?? Self.rebuilt(url)
        let values = Self.rows(url["variable"]).filter(\.isEnabled)
        guard let query = url["query"]?.array else {
            var spec = HTTPRequestSpec(url: raw).normalized()
            spec.url = pathVariables(in: Self.withoutFragment(spec.url), values: values, owner: owner)
            return (spec.url, spec.queryParameters)
        }
        let base = raw.firstIndex(of: "?").map { String(raw[..<$0]) } ?? raw
        return (pathVariables(in: Self.withoutFragment(base), values: values, owner: owner), Self.rows(.array(query)))
    }

    /// A URL from Postman's parts, for an export that gives no `raw`.
    private static func rebuilt(_ url: PostmanJSON) -> String {
        func joined(_ part: PostmanJSON?, _ separator: String) -> String {
            part?.array.map { $0.map { $0["value"]?.text ?? $0.text }.joined(separator: separator) } ?? part?.text ?? ""
        }
        let scheme = url["protocol"]?.string.map { "\($0)://" } ?? ""
        let port = url["port"].map { ":\($0.text)" } ?? ""
        let path = joined(url["path"], "/")
        return scheme + joined(url["host"], ".") + port + (path.isEmpty ? "" : "/\(path)")
    }

    /// A fragment never goes out with a request, so it's dropped rather than kept where it reads as part of the path.
    private static func withoutFragment(_ url: String) -> String {
        url.firstIndex(of: "#").map { String(url[..<$0]) } ?? url
    }

    /// The URL with each `:name` path segment written as `{{name}}`, since Reqling has no path variables. Postman's
    /// value for it is noted rather than kept: requests that share a name usually give it different values, which one
    /// environment couldn't hold.
    private mutating func pathVariables(in url: String, values: [KeyValuePair], owner: PostmanImportNote.Owner) -> String {
        // The authority (`host:port`) ends at the first `/` after the scheme, or at the first `/` when there is none.
        let authorityStart = url.range(of: "://")?.upperBound ?? url.startIndex
        guard let pathStart = url[authorityStart...].firstIndex(of: "/") else {
            return url
        }
        var segments = url[pathStart...].split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        for index in segments.indices {
            let segment = segments[index]
            guard segment.count > 1, segment.hasPrefix(":") else {
                continue
            }
            let name = String(segment.dropFirst())
            segments[index] = "{{\(name)}}"
            let given = values.last { $0.key == name }?.value ?? ""
            let message = given.isEmpty
                ? "The URL's :\(name) is {{\(name)}} now, since Reqling has no path variables; define “\(name)” in an environment."
                : "The URL's :\(name) is {{\(name)}} now, since Reqling has no path variables; Postman gave it “\(given)”."
            note(owner, .url, message)
        }
        return String(url[..<pathStart]) + segments.joined(separator: "/")
    }

    // MARK: - Rows

    /// Query parameters, form fields, and the like: Postman's `{ key, value, disabled }` entries, as rows.
    static func rows(_ list: PostmanJSON?) -> [KeyValuePair] {
        (list?.array ?? []).compactMap { entry in
            let key = entry["key"]?.text ?? ""
            let value = entry["value"]?.text ?? ""
            guard !key.isEmpty || !value.isEmpty else {
                return nil
            }
            return KeyValuePair(key: key, value: value, isEnabled: !(entry["disabled"]?.bool ?? false))
        }
    }

    /// Postman's headers: a list of entries, or `Name: value` lines.
    static func headers(_ header: PostmanJSON?) -> [KeyValuePair] {
        if let text = header?.string {
            return text.split(whereSeparator: \.isNewline).compactMap { line in
                guard let colon = line.firstIndex(of: ":") else {
                    return nil
                }
                let key = line[..<colon].trimmingCharacters(in: .whitespaces)
                return key.isEmpty ? nil : KeyValuePair(key: key, value: line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
            }
        }
        return rows(header).filter { !$0.key.isEmpty }
    }

    // MARK: - Settings

    /// The `protocolProfileBehavior` settings Reqling has: following redirects, verifying TLS, and turning off the
    /// automatic headers that can be.
    private static func apply(_ profile: [String: PostmanJSON], to spec: inout HTTPRequestSpec) {
        if let follows = profile["followRedirects"]?.bool {
            spec.options.followRedirects = follows
        }
        if let verifies = profile["strictSSL"]?.bool {
            spec.options.verifyTLS = verifies
        }
        let switchable: Set<String> = ["accept", "user-agent", "content-type"]
        let disabled = (profile["disabledSystemHeaders"]?.object ?? [:]).compactMap { name, value in
            value.bool == true && switchable.contains(name.lowercased()) ? name.lowercased() : nil
        }
        spec.disabledAutoHeaders = disabled.sorted()
    }
}
