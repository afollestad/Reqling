import Foundation

/// App-wide request defaults from Settings → Requests, applied where a request's own options are unset.
public struct HTTPRequestDefaults: Hashable, Sendable {
    public var timeoutSeconds: Double
    public var followRedirects: Bool
    public var verifyTLS: Bool

    public init(timeoutSeconds: Double = 30, followRedirects: Bool = true, verifyTLS: Bool = true) {
        self.timeoutSeconds = timeoutSeconds
        self.followRedirects = followRedirects
        self.verifyTLS = verifyTLS
    }
}

/// Everything a request build needs beyond the spec itself.
public struct HTTPBuildContext: Sendable {
    public var resolver: TemplateResolver
    /// The project's auth followed by each enclosing folder's, outermost first; `inherit` walks it from the end.
    public var authChain: [HTTPAuth]
    public var paths: ProjectPathResolver
    public var defaults: HTTPRequestDefaults
    public var userAgent: String
    /// Multipart boundaries are injected so tests and previews are deterministic.
    public var makeBoundary: @Sendable () -> String

    public init(
        resolver: TemplateResolver,
        authChain: [HTTPAuth],
        paths: ProjectPathResolver,
        defaults: HTTPRequestDefaults,
        userAgent: String,
        makeBoundary: @escaping @Sendable () -> String = { "reqling-\(UUID().uuidString.lowercased())" }
    ) {
        self.resolver = resolver
        self.authChain = authChain
        self.paths = paths
        self.defaults = defaults
        self.userAgent = userAgent
        self.makeBoundary = makeBoundary
    }
}

/// A request ready to send, plus a masked description of it for display and agents.
public struct PreparedHTTPRequest: Sendable {
    public var urlRequest: URLRequest
    public var followRedirects: Bool
    public var verifyTLS: Bool
    public var unresolvedVariables: [String]
    /// Lower-cased names of the headers that carry credentials: the auth's (an API key's header, `Authorization`) and
    /// any whose name or value uses a secret variable. `HTTPExecutor` strips them, with `Cookie`, before following a
    /// redirect to another origin.
    public var credentialHeaderNames: Set<String>
    /// What was sent, with secret values masked.
    public var summary: ResolvedHTTPRequest
    /// Masks this request's secrets in what the exchange reports back, such as the final URL after redirects.
    var redaction: SecretRedaction
}

/// A human-readable record of a sent request, safe to show and to hand to agents: secrets are masked.
public struct ResolvedHTTPRequest: Hashable, Sendable, Codable {
    public static let bodyPreviewLimit = 64 * 1024

    public var method: String
    public var url: String
    public var headers: [KeyValuePair]
    /// The body as text when it is UTF-8, truncated to `bodyPreviewLimit`.
    public var bodyPreview: String?
    public var bodyByteCount: Int

    public init(method: String, url: String, headers: [KeyValuePair], bodyPreview: String?, bodyByteCount: Int) {
        self.method = method
        self.url = url
        self.headers = headers
        self.bodyPreview = bodyPreview
        self.bodyByteCount = bodyByteCount
    }
}

public enum HTTPBuildError: Error, Equatable, LocalizedError {
    case invalidMethod(String)
    /// Carries the masked URL, so a secret never appears in an error.
    case invalidURL(String)
    case missingFile(String)
    case invalidGraphQLVariables(String)
    case templateTooLarge

    public var errorDescription: String? {
        switch self {
        case .invalidMethod(let method):
            "“\(method)” is not a valid HTTP method."
        case .invalidURL(let url):
            url.isEmpty ? "Enter a URL to send the request." : "“\(url)” is not a valid URL."
        case .missingFile(let description):
            "\(description) could not be found on this Mac."
        case .invalidGraphQLVariables(let detail):
            "The GraphQL variables are not a JSON object: \(detail)"
        case .templateTooLarge:
            "The request’s variables expand to too much text. Check for variables that reference each other many times."
        }
    }
}

/// Builds `URLRequest`s from `HTTPRequestSpec`s: resolves variables, applies inherited auth and automatic headers,
/// and encodes the body for its mode, subject to `HTTPMethod.bodyPolicy`.
///
/// Every template is resolved once, yielding the sent and the masked text together, so the summary carries the same
/// dynamic values (`{{$uuid}}`) the server received. Only the sent side is validated: masking must never block a
/// request, so a masked URL or GraphQL body that no longer parses is shown as text instead.
public enum HTTPRequestBuilder {
    public static func prepare(_ spec: HTTPRequestSpec, context: HTTPBuildContext) throws(HTTPBuildError) -> PreparedHTTPRequest {
        let built = try build(spec, context: context, boundary: context.makeBoundary())
        var urlRequest = URLRequest(url: built.url)
        urlRequest.httpMethod = spec.method.rawValue
        urlRequest.timeoutInterval = spec.options.timeoutSeconds ?? context.defaults.timeoutSeconds
        urlRequest.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        // Without this, URLSession attaches cookies from its jar on top of any the user typed.
        urlRequest.httpShouldHandleCookies = !built.headers.contains { $0.name.sent.caseInsensitiveCompare("Cookie") == .orderedSame }
        for header in built.headers {
            urlRequest.addValue(header.value.sent, forHTTPHeaderField: header.name.sent)
        }
        urlRequest.httpBody = built.body?.sent
        return PreparedHTTPRequest(
            urlRequest: urlRequest,
            followRedirects: spec.options.followRedirects ?? context.defaults.followRedirects,
            verifyTLS: spec.options.verifyTLS ?? context.defaults.verifyTLS,
            unresolvedVariables: built.unresolved,
            credentialHeaderNames: built.credentialHeaderNames,
            summary: ResolvedHTTPRequest(
                method: spec.method.rawValue,
                url: built.shownURL,
                headers: built.headers.map { KeyValuePair(key: $0.name.shown, value: $0.value.shown) },
                bodyPreview: built.body.flatMap { body in
                    String(data: body.shown.prefix(ResolvedHTTPRequest.bodyPreviewLimit), encoding: .utf8)
                },
                bodyByteCount: built.body?.shown.count ?? 0
            ),
            redaction: SecretRedaction(resolver: context.resolver)
        )
    }

    /// The effective auth after walking `inherit` up the chain; a project-level `inherit` means none.
    public static func effectiveAuth(_ auth: HTTPAuth, chain: [HTTPAuth]) -> HTTPAuth {
        guard auth == .inherit else {
            return auth
        }
        return chain.reversed().first { $0 != .inherit } ?? .none
    }

    /// One template's text for the wire and for the summary, from the same resolution.
    private struct Resolved {
        var sent: String
        var shown: String

        init(sent: String, shown: String) {
            self.sent = sent
            self.shown = shown
        }

        /// Text with nothing to mask, such as an automatic header.
        init(_ text: String) {
            self.init(sent: text, shown: text)
        }
    }

    private struct Header {
        var name: Resolved
        var value: Resolved
    }

    private struct Body {
        var sent: Data
        var shown: Data
    }

    private struct Built {
        var url: URL
        var shownURL: String
        var headers: [Header]
        var body: Body?
        var unresolved: [String]
        var credentialHeaderNames: Set<String>
    }

    private typealias Resolve = (String) throws(HTTPBuildError) -> Resolved

    private static func build(_ spec: HTTPRequestSpec, context: HTTPBuildContext, boundary: String) throws(HTTPBuildError) -> Built {
        guard spec.method.isValid else {
            throw .invalidMethod(spec.method.rawValue)
        }
        var unresolved: [String] = []
        func resolve(_ text: String) throws(HTTPBuildError) -> Resolved {
            let resolution = context.resolver.resolve(text)
            guard !resolution.exceedsLimit else {
                throw .templateTooLarge
            }
            for name in resolution.unresolved where !unresolved.contains(name) {
                unresolved.append(name)
            }
            return Resolved(sent: resolution.value, shown: resolution.maskedValue)
        }

        let auth = try authParts(effectiveAuth(spec.auth, chain: context.authChain), resolve: resolve)
        let urls = try buildURLs(spec, authQuery: auth.query, resolve: resolve)
        let body = spec.method.bodyPolicy.allowsBody ? try buildBody(spec.body, boundary: boundary, context: context, resolve: resolve) : nil
        let headers = try buildHeaders(spec, authHeaders: auth.headers, boundary: boundary, userAgent: context.userAgent, resolve: resolve)
        // Masking changed it, so it carries a secret, whatever its name.
        let secretHeaders = headers.filter { $0.name.sent != $0.name.shown || $0.value.sent != $0.value.shown }
        return Built(
            url: urls.sent,
            shownURL: urls.shown,
            headers: headers,
            body: body,
            unresolved: unresolved,
            credentialHeaderNames: Set((auth.headers + secretHeaders).map { $0.name.sent.lowercased() })
        )
    }

    /// The headers an auth adds, or the query item an API key in the query adds (still unresolved, so it resolves in
    /// order with the other query items).
    private static func authParts(_ auth: HTTPAuth, resolve: Resolve) throws(HTTPBuildError) -> (headers: [Header], query: [KeyValuePair]) {
        switch auth {
        case .inherit, .none:
            return ([], [])
        case .basic(let username, let password):
            let username = try resolve(username)
            let password = try resolve(password)
            func credentials(_ username: String, _ password: String) -> String {
                "Basic \(Data("\(username):\(password)".utf8).base64EncodedString())"
            }
            let value = Resolved(sent: credentials(username.sent, password.sent), shown: credentials(username.shown, password.shown))
            return ([Header(name: Resolved("Authorization"), value: value)], [])
        case .bearer(let token):
            let token = try resolve(token)
            return ([Header(name: Resolved("Authorization"), value: Resolved(sent: "Bearer \(token.sent)", shown: "Bearer \(token.shown)"))], [])
        case .apiKey(let name, let value, .header):
            return ([Header(name: try resolve(name), value: try resolve(value))], [])
        case .apiKey(let name, let value, .query):
            return ([], [KeyValuePair(key: name, value: value)])
        }
    }

    /// The URL to send, and the masked one to show. Only the sent URL must parse; a failure reports the masked text,
    /// since the sent one may carry a secret.
    private static func buildURLs(
        _ spec: HTTPRequestSpec,
        authQuery: [KeyValuePair],
        resolve: Resolve
    ) throws(HTTPBuildError) -> (sent: URL, shown: String) {
        let text = try resolve(spec.url)
        var query: [(name: Resolved, value: Resolved)] = []
        for item in spec.queryParameters.filter({ $0.isEnabled && !$0.key.isEmpty }) + authQuery {
            query.append((try resolve(item.key), try resolve(item.value)))
        }
        let url: URL
        do {
            url = try buildURL(text.sent, query: query.map { ($0.name.sent, $0.value.sent) })
        } catch {
            throw .invalidURL(text.sent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : text.shown)
        }
        let shownQuery = query.map { ($0.name.shown, $0.value.shown) }
        let shown = (try? buildURL(text.shown, query: shownQuery))?.absoluteString
            ?? (shownQuery.isEmpty ? text.shown : "\(text.shown)?\(HTTPEncoding.query(shownQuery))")
        return (url, shown)
    }

    /// User headers, then auth headers they do not override, then the automatic ones neither overrides nor disables.
    private static func buildHeaders(
        _ spec: HTTPRequestSpec,
        authHeaders: [Header],
        boundary: String,
        userAgent: String,
        resolve: Resolve
    ) throws(HTTPBuildError) -> [Header] {
        // `buildBody` returns a body for every mode but `none` that the method allows.
        let hasBody = spec.method.bodyPolicy.allowsBody && spec.body.mode != .none
        var headers: [Header] = []
        for header in spec.headers where header.isEnabled && !header.key.isEmpty {
            headers.append(Header(name: try resolve(header.key), value: try resolve(header.value)))
        }
        let userHeaderNames = Set(headers.map { $0.name.sent.lowercased() })
        headers += authHeaders.filter { !userHeaderNames.contains($0.name.sent.lowercased()) }
        let takenNames = Set(headers.map { $0.name.sent.lowercased() })
        var automatic = autoHeaders(for: spec, userAgent: userAgent).filter(\.isOverridable)
        if spec.body.mode == .formData, let index = automatic.firstIndex(where: { $0.key == "content-type" }) {
            automatic[index] = AutoHeader(name: "Content-Type", value: MultipartEncoder(boundary: boundary).contentType, isOverridable: true)
        }
        if !hasBody {
            automatic.removeAll { $0.key == "content-type" }
        }
        let disabled = Set(spec.disabledAutoHeaders.map { $0.lowercased() })
        headers += automatic
            .filter { !takenNames.contains($0.key) && !disabled.contains($0.key) }
            .map { Header(name: Resolved($0.name), value: Resolved($0.value)) }
        if spec.body.mode == .formData, hasBody {
            for index in headers.indices where headers[index].name.sent.caseInsensitiveCompare("Content-Type") == .orderedSame {
                headers[index].value.sent = withBoundary(headers[index].value.sent, boundary)
                headers[index].value.shown = withBoundary(headers[index].value.shown, boundary)
            }
        }
        return headers
    }

    /// A user's `multipart/…` Content-Type without a `boundary` parameter gets the body's boundary appended; without it
    /// the server cannot find the parts. cURL does the same for `-H 'Content-Type: multipart/form-data' -F …`.
    private static func withBoundary(_ contentType: String, _ boundary: String) -> String {
        let parameters = contentType.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        guard parameters.first?.hasPrefix("multipart/") == true, !parameters.dropFirst().contains(where: { $0.hasPrefix("boundary=") }) else {
            return contentType
        }
        return "\(contentType.trimmingCharacters(in: .whitespaces)); boundary=\(boundary)"
    }

    private static func buildURL(_ resolved: String, query: [(String, String)]) throws(HTTPBuildError) -> URL {
        var text = resolved.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw .invalidURL("")
        }
        if !text.contains("://") {
            text = "http://\(text)"
        }
        guard var components = URLComponents(string: text) ?? URLComponents(string: HTTPEncoding.lenientURL(text)),
              components.host?.isEmpty == false else {
            throw .invalidURL(resolved)
        }
        if !query.isEmpty {
            components.percentEncodedQuery = ([components.percentEncodedQuery].compactMap { $0 } + [HTTPEncoding.query(query)]).joined(separator: "&")
        }
        guard let url = components.url else {
            throw .invalidURL(resolved)
        }
        return url
    }

    private static func buildBody(
        _ body: HTTPBody,
        boundary: String,
        context: HTTPBuildContext,
        resolve: Resolve
    ) throws(HTTPBuildError) -> Body? {
        switch body.mode {
        case .none:
            return nil
        case .raw:
            let text = try resolve(body.raw.text)
            return Body(sent: Data(text.sent.utf8), shown: Data(text.shown.utf8))
        case .urlEncoded:
            var sent: [String] = []
            var shown: [String] = []
            for pair in body.urlEncoded where pair.isEnabled && !pair.key.isEmpty {
                let key = try resolve(pair.key)
                let value = try resolve(pair.value)
                sent.append("\(HTTPEncoding.formComponent(key.sent))=\(HTTPEncoding.formComponent(value.sent))")
                shown.append("\(HTTPEncoding.formComponent(key.shown))=\(HTTPEncoding.formComponent(value.shown))")
            }
            return Body(sent: Data(sent.joined(separator: "&").utf8), shown: Data(shown.joined(separator: "&").utf8))
        case .formData:
            return try multipartBody(body.formData, boundary: boundary, paths: context.paths, resolve: resolve)
        case .binary:
            let data = try fileData(body.binary.file, paths: context.paths).data
            return Body(sent: data, shown: data)
        case .graphQL:
            return try graphQLBody(body.graphQL, resolve: resolve)
        }
    }

    private static func multipartBody(
        _ fields: [MultipartField],
        boundary: String,
        paths: ProjectPathResolver,
        resolve: Resolve
    ) throws(HTTPBuildError) -> Body {
        var sent: [MultipartEncoder.Part] = []
        var shown: [MultipartEncoder.Part] = []
        for field in fields where field.isEnabled && !field.key.isEmpty {
            let name = try resolve(field.key)
            let contentType: Resolved? = if let type = field.contentType { try resolve(type) } else { nil }
            switch field.kind {
            case .text:
                let value = try resolve(field.value)
                sent.append(.init(name: name.sent, contentType: contentType?.sent, data: Data(value.sent.utf8)))
                shown.append(.init(name: name.shown, contentType: contentType?.shown, data: Data(value.shown.utf8)))
            case .file:
                let file = try fileData(field.file, paths: paths)
                let guessed = HTTPEncoding.mimeType(forFileName: file.name)
                sent.append(.init(name: name.sent, fileName: file.name, contentType: contentType?.sent ?? guessed, data: file.data))
                shown.append(.init(name: name.shown, fileName: file.name, contentType: contentType?.shown ?? guessed, data: file.data))
            }
        }
        let encoder = MultipartEncoder(boundary: boundary)
        return Body(sent: encoder.encode(sent), shown: encoder.encode(shown))
    }

    private static func graphQLBody(_ graphQL: GraphQLBody, resolve: Resolve) throws(HTTPBuildError) -> Body {
        let query = try resolve(graphQL.query)
        let variables = try resolve(graphQL.variables)
        let operationName = try resolve(graphQL.operationName)
        let sentVariables: [String: Any]?
        do {
            sentVariables = try graphQLVariables(variables.sent)
        } catch {
            // Describe the masked text, so the error can never quote a secret.
            _ = try graphQLVariables(variables.shown)
            throw .invalidGraphQLVariables("Check the values of the variables it uses.")
        }
        let sent = graphQLJSON(query: query.sent, operationName: operationName.sent, variables: sentVariables)
        let shown: Data
        if let shownVariables = try? graphQLVariables(variables.shown) {
            shown = graphQLJSON(query: query.shown, operationName: operationName.shown, variables: shownVariables)
        } else {
            // A masked value can break the JSON (`{"limit": ••••••}`); show the masked text as written.
            var text = String(bytes: graphQLJSON(query: query.shown, operationName: operationName.shown, variables: nil), encoding: .utf8) ?? "{}"
            text.removeLast()
            text += #","variables":\#(variables.shown.trimmingCharacters(in: .whitespacesAndNewlines))}"#
            shown = Data(text.utf8)
        }
        return Body(sent: sent, shown: shown)
    }

    /// The parsed variables object, or `nil` when the text is blank.
    private static func graphQLVariables(_ text: String) throws(HTTPBuildError) -> [String: Any]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }
        let parsed: Any
        do {
            parsed = try JSONSerialization.jsonObject(with: Data(trimmed.utf8))
        } catch {
            throw .invalidGraphQLVariables(error.localizedDescription)
        }
        guard let object = parsed as? [String: Any] else {
            throw .invalidGraphQLVariables("Expected an object.")
        }
        return object
    }

    /// Sorted keys put `variables` last, which the masked fallback in `graphQLBody` relies on.
    private static func graphQLJSON(query: String, operationName: String, variables: [String: Any]?) -> Data {
        var object: [String: Any] = ["query": query]
        if let variables {
            object["variables"] = variables
        }
        if !operationName.isEmpty {
            object["operationName"] = operationName
        }
        // `JSONSerialization` cannot fail on dictionaries of strings and parsed JSON.
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
    }

    private static func fileData(
        _ reference: ProjectPathReference?,
        paths: ProjectPathResolver
    ) throws(HTTPBuildError) -> (data: Data, name: String) {
        guard let reference else {
            throw .missingFile("The body file")
        }
        guard let url = paths.url(for: reference), let data = try? Data(contentsOf: url) else {
            throw .missingFile(paths.describe(reference))
        }
        return (data, url.lastPathComponent)
    }
}
