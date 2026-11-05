import Foundation

/// Arguments and the values they take: scalars, enums, variables, lists, and input objects, each knowing the type it
/// should be so completion can offer what fits.
extension GraphQLDocumentParser {
    mutating func arguments(_ token: GraphQLToken, owner: GraphQLArgumentOwner?, given: Set<String>) -> Outcome {
        if Self.isName(token) {
            let name = Self.nameText(token) ?? ""
            replaceTop(with: .arguments(owner: owner, given: given.union([name])))
            stack.append(.argument(owner: owner, name: name, expectsColon: true))
            return .consumed(.argument(owner, given: given))
        }
        switch token.kind == .punctuator ? token.text : "" {
        case ")":
            stack.removeLast()
            return .consumed(nil)
        // A missing `)`: the field's selection set, or the end of the one around it.
        case "{", "}": return .ends
        default: return .consumed(nil)
        }
    }

    mutating func argument(_ token: GraphQLToken, owner: GraphQLArgumentOwner?, name: String, expectsColon: Bool) -> Outcome {
        guard expectsColon, token.isPunctuator(":") else {
            return .ends
        }
        replaceTop(with: .argument(owner: owner, name: name, expectsColon: false))
        return push(.value(expected: argumentType(name, of: owner), afterDollar: false))
    }

    mutating func value(_ token: GraphQLToken, expected: GraphQLTypeRef?, afterDollar: Bool) -> Outcome {
        if afterDollar {
            guard Self.isName(token) else {
                return .ends
            }
            stack.removeLast()
            return .consumed(.variable(expected: expected))
        }
        switch token.kind {
        case .name:
            stack.removeLast()
            return .consumed(.value(expected: expected))
        case .number, .string, .blockString, .template:
            stack.removeLast()
            return .consumed(nil)
        case .punctuator:
            break
        default:
            return .ends
        }
        switch token.text {
        case "$":
            replaceTop(with: .value(expected: expected, afterDollar: true))
            return .consumed(nil)
        case "[":
            // A single value may stand for a list of one, so a non-list type still describes the elements.
            replaceTop(with: .list(element: expected?.listElement ?? expected?.nullable))
            return .consumed(nil)
        case "{":
            replaceTop(with: .object(inputType: expected?.namedType, given: []))
            return .consumed(nil)
        default:
            return .ends
        }
    }

    mutating func list(_ token: GraphQLToken, element: GraphQLTypeRef?) -> Outcome {
        if token.isPunctuator("]") {
            stack.removeLast()
            return .consumed(nil)
        }
        if Self.startsValue(token) {
            stack.append(.value(expected: element, afterDollar: false))
            return value(token, expected: element, afterDollar: false)
        }
        return token.kind == .punctuator && (token.text == ")" || token.text == "}") ? .ends : .consumed(nil)
    }

    mutating func object(_ token: GraphQLToken, inputType: String?, given: Set<String>) -> Outcome {
        if Self.isName(token) {
            let name = Self.nameText(token) ?? ""
            replaceTop(with: .object(inputType: inputType, given: given.union([name])))
            stack.append(.objectField(inputType: inputType, name: name, expectsColon: true))
            return .consumed(.objectField(inputType: inputType, given: given))
        }
        if token.isPunctuator("}") {
            stack.removeLast()
            return .consumed(nil)
        }
        return token.isPunctuator(")") || token.isPunctuator("]") ? .ends : .consumed(nil)
    }

    mutating func objectField(_ token: GraphQLToken, inputType: String?, name: String, expectsColon: Bool) -> Outcome {
        guard expectsColon, token.isPunctuator(":") else {
            return .ends
        }
        replaceTop(with: .objectField(inputType: inputType, name: name, expectsColon: false))
        return push(.value(expected: inputFieldType(name, of: inputType), afterDollar: false))
    }

    private static func startsValue(_ token: GraphQLToken) -> Bool {
        switch token.kind {
        case .name, .number, .string, .blockString, .template: true
        case .punctuator: token.text == "$" || token.text == "[" || token.text == "{"
        default: false
        }
    }
}
