import ReqlingScriptProtocol

/// A spec addressed by a URL whose query and path variables live in tables, as HTTP's and WebSocket's are.
///
/// `url` never carries a query string: `queryParameters` is the single source of truth, including disabled rows, and
/// the editor shows the two joined. `normalized()` moves a pasted or externally written query into the table.
///
/// `url` does carry its path variables' names (`/pets/:petId`, read by `RequestPathVariables`), and `pathVariables`
/// holds one row per name with its value. `normalized()` and `applyDisplayURL` keep the two in step, so nothing else
/// adds or removes those rows.
public protocol URLAddressed {
    var url: String { get set }
    var queryParameters: [KeyValuePair] { get set }
    /// One row per `:name` segment of `url`, in the order the URL first uses each; `isEnabled` is always true, since a
    /// segment can't be left out of a path.
    var pathVariables: [KeyValuePair] { get set }
}

extension URLAddressed {
    /// Splits a query string out of `url` and appends its items to `queryParameters` as enabled rows. Item text is
    /// kept as written, percent-escapes included, so encoding happens once, when the request is built; only `+` is
    /// read as a space, as form-encoded queries mean it (`?q=a+b` searches for "a b").
    ///
    /// The new rows' IDs derive from their positions and text, so normalizing the same spec twice yields equal specs:
    /// editors normalize every stored spec they read, and a random ID would make each read look like a change elsewhere.
    ///
    /// It also gives `pathVariables` one row per `:name` the URL uses (`syncPathVariables()`).
    public func normalized() -> Self {
        var copy = self
        if let (path, query) = Self.splitQuery(url) {
            copy.url = path
            copy.queryParameters += Self.parseQuery(query)
            copy.queryParameters.deriveIDs(at: queryParameters.count..<copy.queryParameters.count, name: Self.queryRowName)
        }
        copy.syncPathVariables()
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
        syncPathVariables()
    }

    /// Makes `pathVariables` one row per name `url` uses, in its order. A row whose name the URL still uses keeps its
    /// ID and value. When the URL drops as many names as it gains, as renaming `:petId` to `:id` in the bar does, the
    /// rows it dropped pass their IDs and values to the names it gained, in order; otherwise a new name starts empty.
    /// Rows already in step are left as they are, so normalizing twice yields equal specs.
    mutating func syncPathVariables() {
        let names = RequestPathVariables.names(in: url)
        guard names != pathVariables.map(\.key) || pathVariables.contains(where: { !$0.isEnabled }) else {
            return
        }
        let kept = Set(names)
        var dropped = pathVariables.filter { !kept.contains($0.key) }[...]
        let gained = names.filter { name in !pathVariables.contains { $0.key == name } }
        let renames = dropped.count == gained.count
        var rows: [KeyValuePair] = []
        var unnamed: [Int] = []
        for name in names {
            if let row = pathVariables.first(where: { $0.key == name }) {
                rows.append(KeyValuePair(id: row.id, key: name, value: row.value))
            } else if renames, let row = dropped.popFirst() {
                rows.append(KeyValuePair(id: row.id, key: name, value: row.value))
            } else {
                unnamed.append(rows.count)
                rows.append(KeyValuePair(key: name, value: ""))
            }
        }
        rows.deriveIDs(at: unnamed, name: Self.pathRowName)
        pathVariables = rows
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

    /// What a path variable row made for a new name derives its ID from (`deriveIDs`).
    private static func pathRowName(_ index: Int, _ row: KeyValuePair) -> String {
        "path/\(index)/\(row.key)"
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
