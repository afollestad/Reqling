/// A spec addressed by a URL whose query lives in a table, as HTTP's and WebSocket's are.
///
/// `url` never carries a query string: `queryParameters` is the single source of truth, including disabled rows, and
/// the editor shows the two joined. `normalized()` moves a pasted or externally written query into the table.
public protocol QueryAddressed {
    var url: String { get set }
    var queryParameters: [KeyValuePair] { get set }
}

extension QueryAddressed {
    /// Splits a query string out of `url` and appends its items to `queryParameters` as enabled rows. Item text is
    /// kept as written, percent-escapes included, so encoding happens once, when the request is built; only `+` is
    /// read as a space, as form-encoded queries mean it (`?q=a+b` searches for "a b").
    ///
    /// The new rows' IDs derive from their positions and text, so normalizing the same spec twice yields equal specs:
    /// editors normalize every stored spec they read, and a random ID would make each read look like a change elsewhere.
    public func normalized() -> Self {
        guard let (path, query) = Self.splitQuery(url) else {
            return self
        }
        var copy = self
        copy.url = path
        copy.queryParameters += Self.parseQuery(query)
        copy.queryParameters.deriveIDs(at: queryParameters.count..<copy.queryParameters.count, name: Self.queryRowName)
        return copy
    }

    /// The text the URL bar shows: `url` plus the enabled query rows, unencoded except where `applyDisplayURL` would
    /// read the text back differently: `+` (a space there), `#` (the fragment), `&` (the next row), and `=` in a name
    /// show percent-encoded. Each is one the builder escapes anyway, so the bytes sent never change.
    public var displayURL: String {
        let enabled = queryParameters.filter(\.isEnabled)
        guard !enabled.isEmpty else {
            return url
        }
        func shown(_ text: String, isName: Bool) -> String {
            var result = ""
            for character in text {
                switch character {
                case "+": result += "%2B"
                case "#": result += "%23"
                case "&": result += "%26"
                case "=" where isName: result += "%3D"
                default: result.append(character)
                }
            }
            return result
        }
        let query = enabled.map { row in
            row.value.isEmpty ? shown(row.key, isName: true) : "\(shown(row.key, isName: true))=\(shown(row.value, isName: false))"
        }
        return "\(url)?\(query.joined(separator: "&"))"
    }

    /// Applies URL-bar text: the query becomes the enabled rows, and disabled rows the bar cannot show are kept.
    ///
    /// Rows the text still describes keep their IDs (`carryingIDs(into:reserving:name:)`), so typing in the bar edits
    /// rows rather than replacing them, and a merge with a change made elsewhere meanwhile keeps that change.
    public mutating func applyDisplayURL(_ text: String) {
        let enabled = queryParameters.filter(\.isEnabled)
        let disabled = queryParameters.filter { !$0.isEnabled }
        let (path, query) = Self.splitQuery(text) ?? (text, "")
        url = path
        let parsed = enabled.carryingIDs(into: Self.parseQuery(query), reserving: Set(disabled.map(\.id)), name: Self.queryRowName)
        queryParameters = parsed + disabled
    }

    /// `url` before its `?`, and the query after it up to any `#fragment`; `nil` when there is no `?`.
    private static func splitQuery(_ url: String) -> (path: String, query: String)? {
        guard let questionMark = url.firstIndex(of: "?") else {
            return nil
        }
        var query = url[url.index(after: questionMark)...]
        if let fragment = query.firstIndex(of: "#") {
            query = query[..<fragment]
        }
        return (String(url[..<questionMark]), String(query))
    }

    /// What a query row parsed from text derives its ID from (`deriveIDs`).
    private static func queryRowName(_ index: Int, _ row: KeyValuePair) -> String {
        "query/\(index)/\(row.key)=\(row.value)"
    }

    static func parseQuery(_ query: String) -> [KeyValuePair] {
        func text(_ part: Substring) -> String {
            part.replacingOccurrences(of: "+", with: " ")
        }
        return query.split(separator: "&", omittingEmptySubsequences: true).map { item in
            if let equals = item.firstIndex(of: "=") {
                return KeyValuePair(key: text(item[..<equals]), value: text(item[item.index(after: equals)...]))
            }
            return KeyValuePair(key: text(item), value: "")
        }
    }
}
