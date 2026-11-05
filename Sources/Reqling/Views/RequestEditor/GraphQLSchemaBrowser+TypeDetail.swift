import ReqlingKit
import SwiftUI

/// One type: its declaration and description, what it implements or may be, its fields with their arguments, its
/// values or input fields, and where it is used. Every type named is a link.
struct GraphQLTypeDetail: View {
    let type: GraphQLTypeSystem.NamedType
    let typeSystem: GraphQLTypeSystem
    let browser: GraphQLSchemaBrowserModel

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(type.kind.keyword) \(type.name)")
                        .font(.system(.title3, design: .monospaced).weight(.semibold))
                        .textSelection(.enabled)
                    if let description = type.description {
                        Text(description).foregroundStyle(.secondary)
                    }
                    if let url = type.specifiedByURL {
                        Text(url).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
                links("Implements", type.interfaces)
                links("Possible types", type.possibleTypes)
                links("Implemented by", typeSystem.implementations(of: type.name).map(\.name))
                ForEach(type.fields, id: \.name) { field in
                    GraphQLFieldRow(
                        name: field.name,
                        args: field.args,
                        type: field.type,
                        description: field.description,
                        deprecationReason: field.deprecationReason,
                        browser: browser
                    )
                }
                ForEach(type.inputFields, id: \.name) { field in
                    GraphQLFieldRow(
                        name: field.name,
                        args: [],
                        type: field.type,
                        defaultValue: field.defaultValue,
                        description: field.description,
                        deprecationReason: field.deprecationReason,
                        browser: browser
                    )
                }
                ForEach(type.enumValues, id: \.name) { value in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(value.name)
                            .font(.system(.body, design: .monospaced))
                            .strikethrough(value.isDeprecated)
                        GraphQLDescriptionLines(description: value.description, deprecationReason: value.deprecationReason)
                    }
                }
                links("Used by", typeSystem.references(to: type.name).prefix(40).map(\.path), linkingTo: { String($0.prefix { $0 != "." }) })
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// A caption over links to `names`; `linkingTo` maps a name to the type it opens.
    @ViewBuilder
    private func links(_ title: String, _ names: [String], linkingTo target: @escaping (String) -> String = { $0 }) -> some View {
        if !names.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(names, id: \.self) { name in
                    GraphQLTypeLink(text: name, type: target(name), browser: browser)
                        .font(.system(.callout, design: .monospaced))
                }
            }
        }
    }
}

/// A field or input field: its name, arguments, type (a link), default, description, and deprecation.
private struct GraphQLFieldRow: View {
    let name: String
    let args: [GraphQLTypeSystem.InputValue]
    let type: GraphQLTypeRef
    var defaultValue: String?
    let description: String?
    let deprecationReason: String?
    let browser: GraphQLSchemaBrowserModel

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text(name).strikethrough(deprecationReason != nil)
                Text(": ")
                GraphQLTypeLink(text: type.description, type: type.namedType, browser: browser)
                if let defaultValue {
                    Text(" = \(defaultValue)").foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .font(.system(.body, design: .monospaced))
            ForEach(args, id: \.name) { arg in
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Text("  \(arg.name): ").strikethrough(arg.isDeprecated)
                    GraphQLTypeLink(text: arg.type.description, type: arg.type.namedType, browser: browser)
                    if let value = arg.defaultValue {
                        Text(" = \(value)").foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .font(.system(.callout, design: .monospaced))
                .help(arg.description ?? "")
            }
            GraphQLDescriptionLines(description: description, deprecationReason: deprecationReason)
        }
    }
}

private struct GraphQLDescriptionLines: View {
    let description: String?
    let deprecationReason: String?

    var body: some View {
        if let deprecationReason {
            Text("Deprecated: \(deprecationReason)")
                .font(.caption)
                .foregroundStyle(Color(nsColor: .systemOrange))
        }
        if let description {
            Text(description)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
