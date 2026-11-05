import Foundation
import Observation
import ReqlingKit

/// The schema browser beside a GraphQL request: a filter, and the types followed from the list (`path`), the last of
/// which is shown. It belongs to the request's `GraphQLEditorModel`, so each request keeps its own place.
@MainActor
@Observable
final class GraphQLSchemaBrowserModel {
    struct Entry: Hashable, Identifiable {
        /// The type, or `Type.field`, unique in its list.
        let id: String
        let type: String
        let field: String?
        let kind: GraphQLTypeSystem.Kind?
        /// The first line of its description.
        let summary: String?
        let isDeprecated: Bool
    }

    struct Section: Hashable, Identifiable {
        let title: String
        let entries: [Entry]

        var id: String {
            title
        }
    }

    var filter = ""
    private(set) var path: [String] = []

    /// `sections(in:)`'s memo, keyed on the schema and the filter, the only inputs it reads.
    @ObservationIgnored private var sectionsCache: (key: SectionsKey, value: [Section])?

    /// The type shown in detail; nil shows the list.
    var currentType: String? {
        path.last
    }

    func show(_ type: String) {
        if path.last != type {
            path.append(type)
        }
        filter = ""
    }

    func back() {
        _ = path.popLast()
    }

    /// With no filter: the root types, then every other type by kind. With one: matching types, then matching fields,
    /// ranked as completion ranks them.
    func sections(in snapshot: GraphQLSchemaSnapshot) -> [Section] {
        let key = SectionsKey(snapshot: snapshot.id, filter: filter.trimmingCharacters(in: .whitespaces))
        if let sectionsCache, sectionsCache.key == key {
            return sectionsCache.value
        }
        let typeSystem = snapshot.typeSystem
        let value = key.filter.isEmpty ? Self.byKind(typeSystem) : Self.matching(key.filter, in: typeSystem)
        sectionsCache = (key, value)
        return value
    }

    private static func byKind(_ typeSystem: GraphQLTypeSystem) -> [Section] {
        let roots = GraphQLTypeSystem.OperationType.allCases.compactMap { typeSystem.rootType($0) }
        let rootNames = Set(roots.map(\.name))
        let kinds: [(String, GraphQLTypeSystem.Kind)] = [
            ("Objects", .object),
            ("Interfaces", .interface),
            ("Unions", .union),
            ("Enums", .enumeration),
            ("Input Objects", .inputObject),
            ("Scalars", .scalar)
        ]
        let types = typeSystem.browsableTypes.filter { !rootNames.contains($0.name) }
        let sections = [Section(title: "Roots", entries: roots.map(entry))] + kinds.map { title, kind in
            Section(title: title, entries: types.filter { $0.kind == kind }.map(entry))
        }
        return sections.filter { !$0.entries.isEmpty }
    }

    private static func matching(_ text: String, in typeSystem: GraphQLTypeSystem) -> [Section] {
        var types: [Entry] = []
        var fields: [Entry] = []
        for hit in typeSystem.search(text) {
            switch hit {
            case .type(let name):
                if let type = typeSystem.type(named: name) {
                    types.append(entry(type))
                }
            case .field(let typeName, let name):
                let field = typeSystem.type(named: typeName)?.field(name)
                let input = typeSystem.type(named: typeName)?.inputField(name)
                fields.append(Entry(
                    id: "\(typeName).\(name)",
                    type: typeName,
                    field: name,
                    kind: nil,
                    summary: (field?.type ?? input?.type).map { "\(typeName).\(name): \($0)" },
                    isDeprecated: field?.isDeprecated ?? input?.isDeprecated ?? false
                ))
            }
        }
        return [Section(title: "Types", entries: types), Section(title: "Fields", entries: fields)].filter { !$0.entries.isEmpty }
    }

    private static func entry(_ type: GraphQLTypeSystem.NamedType) -> Entry {
        Entry(
            id: type.name,
            type: type.name,
            field: nil,
            kind: type.kind,
            summary: type.description?.split(separator: "\n", maxSplits: 1).first.map(String.init),
            isDeprecated: false
        )
    }

    private struct SectionsKey: Equatable {
        let snapshot: UUID
        let filter: String
    }
}
