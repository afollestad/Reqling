import Foundation
import ReqlingScriptProtocol

/// A request built as given, for one a script sends (`rq.sendRequest`): its text is never resolved, since scripts
/// treat `{{name}}` as plain text, and no auth or file goes into it. What every request gets still applies: the
/// method's `bodyPolicy`, Settings' defaults for timeouts, redirects, and TLS, the automatic `Accept` and `User-Agent`
/// unless the script names them, and a summary with `redaction`'s secrets masked, as a script may have put one in.
extension HTTPRequestBuilder {
    static func prepareLiteral(
        _ request: ScriptFetchRequest,
        defaults: HTTPRequestDefaults,
        userAgent: String,
        redaction: SecretRedaction
    ) throws(HTTPBuildError) -> PreparedHTTPRequest {
        let name = request.method
        let body = request.body
        let method = HTTPMethod(rawValue: name)
        guard method.isValid else {
            throw .invalidMethod(name)
        }
        if body != nil, !method.bodyPolicy.allowsBody {
            throw .bodyNotAllowed(name)
        }
        let url: URL
        do {
            url = try buildURL(request.url, query: [])
        } catch {
            throw .invalidURL(redaction.apply(request.url))
        }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = name
        urlRequest.timeoutInterval = defaults.timeoutSeconds
        urlRequest.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let named = Set(request.headers.map { $0.name.lowercased() })
        var sent = request.headers
        let automatic = [ScriptRow(name: "Accept", value: "*/*"), ScriptRow(name: "User-Agent", value: userAgent)]
        sent += automatic.filter { !named.contains($0.name.lowercased()) }
        // Without this, URLSession attaches cookies from its jar on top of any the script wrote.
        urlRequest.httpShouldHandleCookies = !named.contains("cookie")
        for header in sent {
            urlRequest.addValue(header.value, forHTTPHeaderField: header.name)
        }
        urlRequest.httpBody = body
        return PreparedHTTPRequest(
            urlRequest: urlRequest,
            followRedirects: defaults.followRedirects,
            verifyTLS: defaults.verifyTLS,
            unresolvedVariables: [],
            // Masking changed it, so it carries a secret, whatever its name.
            credentialHeaderNames: Set(sent.filter { redaction.apply($0.value) != $0.value }.map { $0.name.lowercased() }),
            summary: ResolvedHTTPRequest(
                method: name,
                url: redaction.apply(url.absoluteString),
                headers: sent.map { KeyValuePair(key: $0.name, value: redaction.apply($0.value)) },
                bodyPreview: body.flatMap { String(data: $0.prefix(ResolvedHTTPRequest.bodyPreviewLimit), encoding: .utf8) }.map(redaction.apply),
                bodyByteCount: body?.count ?? 0
            ),
            redaction: redaction
        )
    }
}
