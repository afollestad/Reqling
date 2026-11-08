import Foundation
@_implementationOnly import Yams

/// A value written back out: as block-style YAML for a response's Pretty view and an imported body, and as compact
/// JSON, in member order, for the trees that index JSON.
extension YAMLValue {
    /// Two-space block YAML. A string that would read back as something else (`"true"`, `"1.0"`, `""`) is
    /// double-quoted and a multi-line one written as a literal block.
    public func yamlText() -> String {
        YAML.text([self])
    }

    /// Compact JSON with members in order and non-ASCII characters as they are, never as `\u` escapes.
    public func jsonText() -> String {
        var output = ""
        writeJSON(to: &output)
        return output
    }

    private func writeJSON(to output: inout String) {
        switch self {
        case .null: output += "null"
        case .bool(let value): output += value ? "true" : "false"
        case .number(let text): output += text
        case .string(let text): Self.writeJSONString(text, to: &output)
        case .array(let values):
            output += "["
            for (index, value) in values.enumerated() {
                if index > 0 {
                    output += ","
                }
                value.writeJSON(to: &output)
            }
            output += "]"
        case .object(let members):
            output += "{"
            for (index, member) in members.enumerated() {
                if index > 0 {
                    output += ","
                }
                Self.writeJSONString(member.key, to: &output)
                output += ":"
                member.value.writeJSON(to: &output)
            }
            output += "}"
        }
    }

    private static func writeJSONString(_ text: String, to output: inout String) {
        output += "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": output += "\\\""
            case "\\": output += "\\\\"
            case "\n": output += "\\n"
            case "\r": output += "\\r"
            case "\t": output += "\\t"
            case _ where scalar.value < 0x20: output += String(format: "\\u%04X", scalar.value)
            default: output.unicodeScalars.append(scalar)
            }
        }
        output += "\""
    }

    var node: Node {
        switch self {
        case .null: Node("null", .implicit, .plain)
        case .bool(let value): Node(value ? "true" : "false", .implicit, .plain)
        case .number(let text): Node(text, .implicit, .plain)
        case .string(let text): Node(text, .implicit, Self.style(for: text))
        case .array(let values): Node(values.map(\.node), Tag(.seq))
        case .object(let members): Node(members.map { (Node($0.key, .implicit, Self.style(for: $0.key)), $0.value.node) }, Tag(.map))
        }
    }

    private static func style(for text: String) -> Node.Scalar.Style {
        if text.contains("\n") {
            return .literal
        }
        return YAMLScalars.needsQuotes(text) ? .doubleQuoted : .any
    }
}

extension YAML {
    /// The documents as one stream: a lone document as is, and several each after a `---`.
    public static func text(_ documents: [YAMLValue]) -> String {
        let text = try? serialize(
            nodes: documents.map(\.node),
            indent: 2,
            width: -1,
            allowUnicode: true,
            explicitStart: documents.count > 1
        )
        // JSON is YAML, so a value libyaml can't emit still reads back the same.
        return text ?? documents.map { $0.jsonText() }.joined(separator: "\n---\n")
    }
}
