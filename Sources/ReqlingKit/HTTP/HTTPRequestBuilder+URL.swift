import Foundation
import ReqlingScriptProtocol

/// A request's URL: its text and path variables resolved and substituted, then its query rows appended, each encoded
/// once. Every request's URL is built here, a script's own fetches (`prepareLiteral`) included.
extension HTTPRequestBuilder {
    struct BuiltURL {
        var sent: URL
        /// Masked, for the summary.
        var shown: String
        /// The path variables whose value resolved empty (`PreparedHTTPRequest.emptyPathVariables`).
        var emptyPathVariables: [String]
    }

    /// The URL to send, and the masked one to show. Only the sent URL must parse; a failure reports the masked text,
    /// since the sent one may carry a secret.
    static func buildURLs(_ spec: HTTPRequestSpec, authQuery: [KeyValuePair], resolve: Resolve) throws(HTTPBuildError) -> BuiltURL {
        let (text, emptyPathVariables) = try resolvedURL(spec, resolve: resolve)
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
        return BuiltURL(sent: url, shown: shown, emptyPathVariables: emptyPathVariables)
    }

    /// The URL's text with each `:name` segment replaced by its row's resolved value, encoded as one path segment, and
    /// the names whose value resolved empty, which keep their `:name`. Substituted on the template, between resolving
    /// the text around each segment, so names always match the rows and a variable's value can never add one.
    private static func resolvedURL(_ spec: HTTPRequestSpec, resolve: Resolve) throws(HTTPBuildError) -> (Resolved, [String]) {
        let segments = RequestPathVariables.segments(in: spec.url)
        guard !segments.isEmpty else {
            return (try resolve(spec.url), [])
        }
        var text = Resolved("")
        var empty: [String] = []
        var cursor = spec.url.startIndex
        func append(_ part: Resolved) {
            text.sent += part.sent
            text.shown += part.shown
        }
        for segment in segments {
            append(try resolve(String(spec.url[cursor..<segment.range.lowerBound])))
            let value = try resolve(spec.pathVariables.first { $0.key == segment.name }?.value ?? "")
            if value.sent.isEmpty {
                append(Resolved(":\(segment.name)"))
                if !empty.contains(segment.name) {
                    empty.append(segment.name)
                }
            } else {
                append(Resolved(sent: RequestPathVariables.encoded(value.sent), shown: RequestPathVariables.encoded(value.shown)))
            }
            cursor = segment.range.upperBound
        }
        append(try resolve(String(spec.url[cursor...])))
        return (text, empty)
    }

    static func buildURL(_ resolved: String, query: [(String, String)]) throws(HTTPBuildError) -> URL {
        guard !resolved.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw .invalidURL("")
        }
        guard var components = RequestURLText.components(resolved) else {
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
}
