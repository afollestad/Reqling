import Foundation

/// What the name under the pointer is: its signature as GraphQL writes it, and the schema's description of it.
public struct GraphQLHover: Hashable, Sendable {
    /// The name described, including a variable's `$`.
    public let range: NSRange
    /// Such as `Book.title: String!`, `first: Int = 10`, or `enum Genre`.
    public let signature: String
    public let description: String?
    public let deprecationReason: String?
}

/// Describes a name from its role, as completion would have offered it.
struct GraphQLHoverDescriber {
    let typeSystem: GraphQLTypeSystem
    let outline: GraphQLDocumentParser.Outline
    let operation: Int?

    struct Description {
        var signature: String
        var description: String?
        var deprecationReason: String?
    }

    func describe(_ role: GraphQLNameRole, name: String) -> Description? {
        switch role {
        case .definitionKeyword(let operation?):
            return typeSystem.rootType(operation).flatMap { type($0.name) }
        case .field(let parent?):
            return field(name, on: parent)
        case .argument(let owner?, _):
            return argument(name, of: owner)
        case .objectField(let inputType?, _):
            return typeSystem.type(named: inputType)?.inputField(name).map { inputValue($0, owner: inputType) }
        case .value(let expected?):
            return enumValue(name, in: expected.namedType)
        case .variable, .variableDefinition:
            return variable(name)
        case .variableType, .typeCondition, .fragmentTypeCondition:
            return type(name)
        case .directive:
            return directive(name)
        case .spread:
            return outline.fragments.first { $0.name == name }.map { Description(signature: "fragment \(name) on \($0.typeCondition ?? "?")") }
        default:
            return nil
        }
    }

    private func field(_ name: String, on parent: String) -> Description? {
        guard let field = typeSystem.field(name, on: parent) else {
            return nil
        }
        let args = field.args.isEmpty ? "" : "(" + field.args.map(Self.inputValueSignature).joined(separator: ", ") + ")"
        return Description(
            signature: "\(parent).\(name)\(args): \(field.type)",
            description: field.description,
            deprecationReason: field.deprecationReason
        )
    }

    private func argument(_ name: String, of owner: GraphQLArgumentOwner) -> Description? {
        let arg: GraphQLTypeSystem.InputValue? = switch owner {
        case .field(let parent, let field): typeSystem.field(field, on: parent)?.arg(name)
        case .directive(let directive): typeSystem.directive(named: directive)?.args.first { $0.name == name }
        }
        return arg.map { inputValue($0, owner: nil) }
    }

    private func inputValue(_ value: GraphQLTypeSystem.InputValue, owner: String?) -> Description {
        Description(
            signature: (owner.map { "\($0)." } ?? "") + Self.inputValueSignature(value),
            description: value.description,
            deprecationReason: value.deprecationReason
        )
    }

    private func enumValue(_ name: String, in typeName: String) -> Description? {
        guard let value = typeSystem.type(named: typeName)?.enumValues.first(where: { $0.name == name }) else {
            return nil
        }
        return Description(signature: "\(typeName).\(name)", description: value.description, deprecationReason: value.deprecationReason)
    }

    private func variable(_ name: String) -> Description? {
        guard let operation, operation < outline.operations.count,
              let variable = outline.operations[operation].variables.first(where: { $0.name == name }) else {
            return nil
        }
        return Description(signature: "$\(name): \(variable.type?.description ?? "?")")
    }

    private func type(_ name: String) -> Description? {
        guard let type = typeSystem.type(named: name) else {
            return nil
        }
        var signature = "\(type.kind.keyword) \(type.name)"
        if !type.interfaces.isEmpty {
            signature += " implements " + type.interfaces.joined(separator: " & ")
        }
        if type.kind == .union, !type.possibleTypes.isEmpty {
            signature += " = " + type.possibleTypes.joined(separator: " | ")
        }
        return Description(signature: signature, description: type.description)
    }

    private func directive(_ name: String) -> Description? {
        guard let directive = typeSystem.directive(named: name) else {
            return nil
        }
        let args = directive.args.isEmpty ? "" : "(" + directive.args.map(Self.inputValueSignature).joined(separator: ", ") + ")"
        return Description(signature: "@\(name)\(args)", description: directive.description)
    }

    static func inputValueSignature(_ value: GraphQLTypeSystem.InputValue) -> String {
        "\(value.name): \(value.type)" + (value.defaultValue.map { " = \($0)" } ?? "")
    }
}
