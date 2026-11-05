import Foundation

/// Printing the type system as GraphQL SDL, for reading (the browser, `graphql_describe_type`) and for GraphQLSwift to
/// build a schema to validate against (`GraphQLDocumentValidator`).
///
/// Built-in scalars, the `__*` introspection types, and the directives every GraphQL implementation defines are left
/// out, since a schema that redefined them would not build. The `schema { … }` block is always printed, so a type that
/// merely happens to be named `Mutation` never becomes a root.
extension GraphQLTypeSystem {
    static let builtInScalars: Set<String> = ["String", "Int", "Float", "Boolean", "ID"]
    static let builtInDirectives: Set<String> = ["include", "skip", "deprecated", "specifiedBy", "oneOf"]

    /// The whole schema.
    public func sdl() -> String {
        sdl(SDLStyle())
    }

    /// One type, or nil when the schema has none by that name.
    public func sdl(forType name: String) -> String? {
        type(named: name).map { print($0, style: SDLStyle()) }
    }

    /// One directive, or nil when the schema has none by that name or none of its locations is known.
    public func sdl(forDirective name: String) -> String? {
        directive(named: name).flatMap { print($0, style: SDLStyle()) }
    }

    /// Choices for validation. `assumesUnknownRepeatable` prints a directive whose repeatability the server did not
    /// report as repeatable, so using it twice is never flagged by mistake. `dropsDefaults` leaves default values out,
    /// for a server whose defaults are not valid GraphQL literals; arguments that had one become nullable, so leaving
    /// them out stays valid.
    struct SDLStyle {
        var assumesUnknownRepeatable = false
        var dropsDefaults = false
    }

    func sdl(_ style: SDLStyle) -> String {
        var blocks: [String] = []
        var roots: [String] = []
        for operation in OperationType.allCases {
            if let name = rootTypes[operation] {
                roots.append("  \(operation.rawValue): \(name)")
            }
        }
        blocks.append(Self.described(description, indent: "") + "schema {\n" + roots.joined(separator: "\n") + "\n}")
        blocks += directives
            .filter { !Self.builtInDirectives.contains($0.name) }
            .compactMap { print($0, style: style) }
        blocks += types
            .filter { !$0.name.hasPrefix("__") && !Self.builtInScalars.contains($0.name) }
            .map { print($0, style: style) }
        return blocks.joined(separator: "\n\n") + "\n"
    }

    private func print(_ type: NamedType, style: SDLStyle) -> String {
        let head = Self.described(type.description, indent: "")
        switch type.kind {
        case .scalar:
            let specifiedBy = type.specifiedByURL.map { " @specifiedBy(url: \(Self.quoted($0)))" } ?? ""
            return head + "scalar \(type.name)\(specifiedBy)"
        case .object, .interface:
            let keyword = type.kind == .object ? "type" : "interface"
            let implements = type.interfaces.isEmpty ? "" : " implements " + type.interfaces.joined(separator: " & ")
            let fields = type.fields.map { field in
                Self.described(field.description, indent: "  ") + "  \(field.name)\(Self.arguments(field.args, style: style)): \(field.type)"
                    + Self.deprecated(field.deprecationReason)
            }
            return head + "\(keyword) \(type.name)\(implements)" + Self.body(fields)
        case .union:
            let members = type.possibleTypes.isEmpty ? "" : " = " + type.possibleTypes.joined(separator: " | ")
            return head + "union \(type.name)\(members)"
        case .enumeration:
            let values = type.enumValues.map { value in
                Self.described(value.description, indent: "  ") + "  \(value.name)" + Self.deprecated(value.deprecationReason)
            }
            return head + "enum \(type.name)" + Self.body(values)
        case .inputObject:
            let fields = type.inputFields.map { Self.described($0.description, indent: "  ") + "  " + Self.inputValue($0, style: style) }
            return head + "input \(type.name)\(type.isOneOf ? " @oneOf" : "")" + Self.body(fields)
        }
    }

    private func print(_ directive: Directive, style: SDLStyle) -> String? {
        guard !directive.locations.isEmpty else {
            return nil
        }
        let repeats = directive.isRepeatable ?? style.assumesUnknownRepeatable
        return Self.described(directive.description, indent: "")
            + "directive @\(directive.name)\(Self.arguments(directive.args, style: style))\(repeats ? " repeatable" : "") on "
            + directive.locations.map(\.rawValue).joined(separator: " | ")
    }

    /// Inline when no argument has a description; one per line otherwise, so each description sits above its argument.
    private static func arguments(_ args: [InputValue], style: SDLStyle) -> String {
        guard !args.isEmpty else {
            return ""
        }
        if args.allSatisfy({ $0.description == nil }) {
            return "(" + args.map { inputValue($0, style: style) }.joined(separator: ", ") + ")"
        }
        let lines = args.map { described($0.description, indent: "    ") + "    " + inputValue($0, style: style) }
        return "(\n" + lines.joined(separator: "\n") + "\n  )"
    }

    private static func inputValue(_ value: InputValue, style: SDLStyle) -> String {
        if style.dropsDefaults, value.defaultValue != nil {
            return "\(value.name): \(value.type.nullable)" + deprecated(value.deprecationReason)
        }
        let defaultValue = value.defaultValue.map { " = \($0)" } ?? ""
        return "\(value.name): \(value.type)\(defaultValue)" + deprecated(value.deprecationReason)
    }

    private static func body(_ lines: [String]) -> String {
        lines.isEmpty ? "" : " {\n" + lines.joined(separator: "\n") + "\n}"
    }

    private static func deprecated(_ reason: String?) -> String {
        guard let reason else {
            return ""
        }
        return reason == defaultDeprecationReason ? " @deprecated" : " @deprecated(reason: \(quoted(reason)))"
    }

    /// A description followed by a line break, or nothing. Block strings read best, but their value drops common
    /// indentation and blank first and last lines, so text that has those, or control characters, is quoted instead.
    static func described(_ description: String?, indent: String) -> String {
        guard let description else {
            return ""
        }
        guard isPrintableAsBlockString(description) else {
            return indent + quoted(description) + "\n"
        }
        let lines = description
            .replacingOccurrences(of: tripleQuote, with: "\\" + tripleQuote)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.isEmpty ? "" : indent + $0 }
        return indent + tripleQuote + "\n" + lines.joined(separator: "\n") + "\n" + indent + tripleQuote + "\n"
    }

    private static let tripleQuote = String(repeating: "\"", count: 3)

    private static func isPrintableAsBlockString(_ text: String) -> Bool {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let isBlank = { (line: Substring) in line.allSatisfy { $0 == " " || $0 == "\t" } }
        guard let first = lines.first, let last = lines.last, !isBlank(first), !isBlank(last) else {
            return false
        }
        let hasControl = text.unicodeScalars.contains { $0.value < 0x20 && $0 != "\n" && $0 != "\t" }
        let allIndented = lines.filter { !isBlank($0) }.allSatisfy { $0.first == " " || $0.first == "\t" }
        return !hasControl && !allIndented
    }

    /// A GraphQL string literal.
    static func quoted(_ text: String) -> String {
        var result = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            case _ where scalar.value < 0x20:
                result += String(format: "\\u%04X", scalar.value)
            default:
                result.unicodeScalars.append(scalar)
            }
        }
        return result + "\""
    }
}
