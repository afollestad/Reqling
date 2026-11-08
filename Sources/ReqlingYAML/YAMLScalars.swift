import Foundation
@_implementationOnly import Yams

/// How a plain scalar's text is typed: YAML 1.2's core schema, the one JSON agrees with. `null`, `~`, and nothing are
/// null; `true` and `false` (and their capitalized spellings) are booleans; decimal, `0o` octal, and `0x` hex integers
/// and decimal floats are numbers, in JSON's grammar; everything else is a string.
enum YAMLScalars {
    /// The tag every untagged plain scalar resolves to (`resolver`), so typing can tell `123` from `!!str 123` and
    /// `"123"`, which Yams tags `str` alike.
    static let plainTag = "tag:reqling.app,2026:plain"

    /// No rules but one matching every plain scalar Yams can't otherwise tag.
    static let resolver = (try? Resolver.basic.appending(Tag.Name(rawValue: plainTag), "^")) ?? .basic

    static func value(of text: String, tag: String) -> YAMLValue {
        switch tag {
        case plainTag: core(text)
        case Tag.Name.null.rawValue: .null
        case Tag.Name.bool.rawValue: bool(text).map(YAMLValue.bool) ?? .string(text)
        case Tag.Name.int.rawValue, Tag.Name.float.rawValue: number(text).map(YAMLValue.number) ?? .string(text)
        // `!!str`, quoted and block scalars, the non-specific `!`, and every application tag.
        default: .string(text)
        }
    }

    static func core(_ text: String) -> YAMLValue {
        if ["", "~", "null", "Null", "NULL"].contains(text) {
            return .null
        }
        if let bool = bool(text) {
            return .bool(bool)
        }
        if let number = number(text) {
            return .number(number)
        }
        return .string(text)
    }

    static func bool(_ text: String) -> Bool? {
        switch text {
        case "true", "True", "TRUE": true
        case "false", "False", "FALSE": false
        default: nil
        }
    }

    /// The text as a JSON number (`+1` → `1`, `007` → `7`, `.5` → `0.5`, `2.` → `2`, `0x1F` → `31`); `nil` when the core
    /// schema doesn't read it as one. `.inf` and `.nan` aren't, since JSON has no spelling for them, nor is a hex or
    /// octal integer too large for 64 bits.
    static func number(_ text: String) -> String? {
        if text.hasPrefix("0x") {
            return UInt64(text.dropFirst(2), radix: 16).map(String.init)
        }
        if text.hasPrefix("0o") {
            return UInt64(text.dropFirst(2), radix: 8).map(String.init)
        }
        var rest = Substring(text)
        var sign = ""
        if let first = rest.first, first == "-" || first == "+" {
            sign = first == "-" ? "-" : ""
            rest = rest.dropFirst()
        }
        let integer = digits(&rest)
        var fraction = ""
        if rest.first == "." {
            rest = rest.dropFirst()
            fraction = String(digits(&rest))
        }
        guard !integer.isEmpty || !fraction.isEmpty else {
            return nil
        }
        var exponent = ""
        if let marker = rest.first, marker == "e" || marker == "E" {
            rest = rest.dropFirst()
            var exponentSign = ""
            if let first = rest.first, first == "-" || first == "+" {
                exponentSign = first == "-" ? "-" : ""
                rest = rest.dropFirst()
            }
            let exponentDigits = digits(&rest)
            guard !exponentDigits.isEmpty else {
                return nil
            }
            exponent = "e\(exponentSign)\(exponentDigits)"
        }
        guard rest.isEmpty else {
            return nil
        }
        let trimmed = integer.drop { $0 == "0" }
        return sign + (trimmed.isEmpty ? "0" : String(trimmed)) + (fraction.isEmpty ? "" : ".\(fraction)") + exponent
    }

    /// Whether a string must be quoted to read back as a string: YAML 1.2 would type it, or a YAML 1.1 reader would
    /// (`yes`, `on`, `1_000`, `2024-01-01`, `.inf`), as many still do.
    static func needsQuotes(_ text: String) -> Bool {
        core(text) != .string(text) || Resolver.default.resolveTag(of: Node(text)) != .str
    }

    private static func digits(_ text: inout Substring) -> Substring {
        let digits = text.prefix { $0.isASCII && $0.isNumber }
        text = text.dropFirst(digits.count)
        return digits
    }
}
