import Foundation

/// The keys of a JSON response, so `rq.response.json().` completes with what this request's latest response held. Built
/// over `JSONStructureIndex`, which takes a body the history cut short, and read a container at a time, so a large
/// response costs only the containers a completion walks.
public struct ScriptJSONShape: Sendable {
    public struct Key: Hashable, Sendable {
        public let name: String
        public let kind: JSONValueKind
    }

    /// The items of an array whose keys are merged, since items of one array usually share a shape.
    static let sampledItems = 5

    private let index: JSONStructureIndex

    /// `nil` when `data` isn't JSON.
    public init?(json data: Data) {
        guard let index = try? JSONStructureIndex.build(data, allowsTruncation: true) else {
            return nil
        }
        self.index = index
    }

    /// The keys of the objects `path` leads to, in order and without repeats: each step is an object's key, or `nil`
    /// for an array's items.
    public func keys(at path: [String?]) -> [Key] {
        var values = index.rootEntries()
        for step in path {
            values = values.flatMap { value -> [JSONEntry] in
                guard let container = value.container else {
                    return []
                }
                let children = index.children(of: container)
                switch (value.kind, step) {
                case (.object, let key?):
                    return children.filter { $0.key == key }
                case (.array, nil):
                    return Array(children.prefix(Self.sampledItems))
                default:
                    return []
                }
            }
        }
        var seen: Set<String> = []
        var keys: [Key] = []
        for value in values where value.kind == .object {
            for child in value.container.map(index.children(of:)) ?? [] {
                if let name = child.key, seen.insert(name).inserted {
                    keys.append(Key(name: name, kind: child.kind))
                }
            }
        }
        return keys
    }
}
