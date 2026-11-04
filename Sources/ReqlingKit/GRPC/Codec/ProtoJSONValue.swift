/// JSON as the codec needs it, which `JSONSerialization` cannot offer: objects keep member order, so output follows
/// field declaration order, and numbers keep their source text, so 64-bit integers never round through `Double`.
enum ProtoJSONValue: Equatable {
    case null
    case bool(Bool)
    /// The number's literal text, always valid JSON number grammar.
    case number(String)
    case string(String)
    case array([ProtoJSONValue])
    case object([ProtoJSONMember])

    /// Names the value's JSON type for "expected X, got Y" errors.
    var typeDescription: String {
        switch self {
        case .null:
            "null"
        case .bool:
            "a boolean"
        case .number:
            "a number"
        case .string:
            "a string"
        case .array:
            "an array"
        case .object:
            "an object"
        }
    }

    /// Two-space indentation with `"key": value` members; empty containers stay on one line.
    func prettyPrinted() -> String {
        var output = ""
        write(to: &output, indent: 0)
        return output
    }

    private func write(to output: inout String, indent: Int) {
        switch self {
        case .null:
            output += "null"
        case .bool(let value):
            output += value ? "true" : "false"
        case .number(let text):
            output += text
        case .string(let text):
            Self.writeQuoted(text, to: &output)
        case .array(let items):
            Self.writeContainer(items.count, brackets: ("[", "]"), to: &output, indent: indent) { index, output in
                items[index].write(to: &output, indent: indent + 1)
            }
        case .object(let members):
            Self.writeContainer(members.count, brackets: ("{", "}"), to: &output, indent: indent) { index, output in
                Self.writeQuoted(members[index].key, to: &output)
                output += ": "
                members[index].value.write(to: &output, indent: indent + 1)
            }
        }
    }

    private static func writeContainer(
        _ count: Int,
        brackets: (open: String, close: String),
        to output: inout String,
        indent: Int,
        writeElement: (Int, inout String) -> Void
    ) {
        guard count > 0 else {
            output += brackets.open + brackets.close
            return
        }
        let innerPadding = String(repeating: "  ", count: indent + 1)
        output += brackets.open + "\n"
        for index in 0..<count {
            output += innerPadding
            writeElement(index, &output)
            output += index == count - 1 ? "\n" : ",\n"
        }
        output += String(repeating: "  ", count: indent) + brackets.close
    }

    private static func writeQuoted(_ text: String, to output: inout String) {
        output += "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"":
                output += "\\\""
            case "\\":
                output += "\\\\"
            case "\n":
                output += "\\n"
            case "\r":
                output += "\\r"
            case "\t":
                output += "\\t"
            case "\u{08}":
                output += "\\b"
            case "\u{0C}":
                output += "\\f"
            case "\u{00}"..."\u{1F}":
                let hex = String(scalar.value, radix: 16, uppercase: true)
                output += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
            default:
                output.unicodeScalars.append(scalar)
            }
        }
        output += "\""
    }
}

struct ProtoJSONMember: Equatable {
    let key: String
    let value: ProtoJSONValue
}
