import Foundation

/// Sidebar search over a project's tree.
extension ProjectDocument {
    /// The tree trimmed to what matches `query` and `filter`, or `nil` when nothing does.
    ///
    /// A project or folder whose name matches the query keeps everything inside it that passes `filter`; otherwise a
    /// request matches on its name, method, or URL and keeps the folders around it. Matching ignores case and
    /// diacritics, and every word of the query must match somewhere in the item's text. An active filter hides
    /// folders left empty.
    public func filtered(
        matching query: String,
        filter: RequestFilter = .none,
        outcome: @escaping (RequestNodeID) -> RunOutcomeKind = { _ in .notSent }
    ) -> [RequestNode]? {
        let terms = Self.terms(in: query)
        guard !terms.isEmpty || filter.isActive else {
            return items
        }
        let matcher = Matcher(terms: terms, filter: filter, outcome: outcome)
        let filtered = matcher.filter(items, nameMatched: Self.matches(name, terms))
        if filtered.isEmpty {
            // An empty project still shows when only its name was searched for.
            return !filter.isActive && Self.matches(name, terms) ? [] : nil
        }
        return filtered
    }

    private struct Matcher {
        let terms: [String]
        let filter: RequestFilter
        let outcome: (RequestNodeID) -> RunOutcomeKind

        /// `nameMatched` is true inside a project or folder whose own name matched, where the query no longer applies.
        func filter(_ nodes: [RequestNode], nameMatched: Bool) -> [RequestNode] {
            nodes.compactMap { node in
                switch node {
                case .request(let request):
                    let queryMatches = nameMatched || ProjectDocument.matches(ProjectDocument.searchableText(for: request), terms)
                    return queryMatches && filter.admits(request, outcome: outcome(request.id)) ? node : nil
                case .folder(var folder):
                    let folderMatched = nameMatched || ProjectDocument.matches(folder.name, terms)
                    folder.children = filter(folder.children, nameMatched: folderMatched)
                    if folder.children.isEmpty {
                        return folderMatched && !filter.isActive ? .folder(folder) : nil
                    }
                    return .folder(folder)
                }
            }
        }
    }

    fileprivate static func searchableText(for request: RequestItem) -> String {
        switch request.kind {
        case .http(let spec):
            "\(request.name) \(spec.method.rawValue) \(spec.displayURL)"
        case .grpc(let spec):
            "\(request.name) gRPC \(spec.methodPath) \(spec.target)"
        case .webSocket(let spec):
            "\(request.name) WebSocket \(spec.displayURL)"
        }
    }

    private static func terms(in query: String) -> [String] {
        query.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    fileprivate static func matches(_ text: String, _ terms: [String]) -> Bool {
        terms.allSatisfy { text.localizedStandardContains($0) }
    }
}
