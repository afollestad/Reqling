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
            Self.setURL(.string(url), of: &spec)
        } else if let request {
            let method = request["method"]?.string?.trimmingCharacters(in: .whitespaces) ?? ""
            spec.method = HTTPMethod(rawValue: method.isEmpty ? "GET" : method)
            Self.setURL(request["url"], of: &spec)
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

    /// The spec's URL without its query or fragment, its query as rows, and a path variable row for each `:name`
    /// segment, with the value Postman gave it. Postman's `query` list keeps the rows it turned off, which `raw` leaves
    /// out, so it's the source when there is one.
    private static func setURL(_ url: PostmanJSON?, of spec: inout HTTPRequestSpec) {
        guard let url else {
            return
        }
        var values: [KeyValuePair] = []
        if let raw = url.string {
            spec.url = raw
        } else {
            let raw = url["raw"]?.string ?? rebuilt(url)
            values = rows(url["variable"]).filter(\.isEnabled)
            if let query = url["query"]?.array {
                spec.url = raw.firstIndex(of: "?").map { String(raw[..<$0]) } ?? raw
                spec.queryParameters = rows(.array(query))
            } else {
                spec.url = raw
            }
        }
        spec = spec.normalized()
        // Normalizing split off the query, which ends at a fragment; one left without a query goes here.
        spec.url = withoutFragment(spec.url)
        spec = spec.normalized()
        for index in spec.pathVariables.indices {
            spec.pathVariables[index].value = values.last { $0.key == spec.pathVariables[index].key }?.value ?? ""
        }
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
