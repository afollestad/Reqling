import Foundation
import SwiftUI

/// What a `CodeEditor` asks about its text as it is edited and pointed at: what may be typed at the cursor, and what
/// the name under the pointer is. Offsets are UTF-16. `GraphQLEditorModel` answers for GraphQL queries.
@MainActor
protocol CodeEditorAssistant: AnyObject {
    /// What may be typed at `cursor`, or nil where nothing is offered (inside a string, a comment, or a
    /// `{{template}}`, whose completion is the editor's own).
    func completions(in text: String, cursor: Int) -> CodeCompletionList?
    /// What the text at `offset` is, or nil where there is nothing to say.
    func hover(in text: String, at offset: Int) -> CodeHoverContent?
    /// Whether typing `typed` just before `cursor` starts something worth suggesting for. GraphQL's rules unless the
    /// assistant has its own.
    func opensCompletion(_ typed: String, before cursor: Int, in text: NSString) -> Bool
}

extension CodeEditorAssistant {
    func opensCompletion(_ typed: String, before cursor: Int, in text: NSString) -> Bool {
        CodeTextView.opensCompletion(typed, before: cursor, in: text)
    }
}

/// An assistant that also knows what a call's arguments are, for parameter hints. A separate protocol so an editor
/// whose assistant can't say (GraphQL's, whose arguments are named) leaves ⇧⌘Space and ⌘P to the rest of the app.
@MainActor
protocol CodeEditorSignatureAssistant: CodeEditorAssistant {
    /// The call whose arguments hold `cursor`, or nil outside one it knows.
    func signatureHelp(in text: String, cursor: Int) -> CodeSignatureHelp?
}

/// What parameter hints show: the signature of the method being called, and which parameter the cursor's argument
/// fills.
struct CodeSignatureHelp: Equatable {
    struct Parameter: Equatable {
        let name: String
        /// As the signature shows it, such as `options?: object`.
        let label: String
        let summary: String?
    }

    /// Such as `RequestCookies.get`.
    let name: String
    let parameters: [Parameter]
    /// Nil for a function whose result isn't known, such as one a script declares.
    let returnType: String?
    /// Nil when the cursor's argument fills none, as past the last.
    let activeParameter: Int?
    /// What the method does.
    let summary: String?
    /// The call's `(`, which the hints line up with when it is on the cursor's line. UTF-16.
    let anchor: Int

    var active: Parameter? {
        activeParameter.flatMap { parameters.indices.contains($0) ? parameters[$0] : nil }
    }
}

/// Suggestions for the name at the cursor, already ranked by what is typed there.
struct CodeCompletionList: Equatable {
    /// Which characters a name in a list is made of, so typing one narrows the list rather than closing it.
    enum NameCharacters: Equatable {
        /// Letters, digits, and `_`.
        case code
        /// A `{{variable}}` name inside a string: anything but a brace, a quote, or whitespace.
        case variableName

        func contains(_ character: Character) -> Bool {
            switch self {
            case .code: CodeTextView.isNameCharacter(character)
            case .variableName: !character.isWhitespace && !"{}\"'`".contains(character)
            }
        }
    }

    /// What accepting an item replaces: the whole name being typed, or an empty range at the cursor.
    let replacementRange: NSRange
    let items: [CodeCompletionItem]
    var nameCharacters: NameCharacters = .code
}

struct CodeCompletionItem: Equatable, Identifiable {
    /// Its place in the list.
    let id: Int
    let label: String
    let kind: CodeSymbolKind
    /// The type it has or takes, shown at the row's trailing edge.
    let detail: String?
    /// Its description, shown under the list while it is highlighted.
    let summary: String?
    let isDeprecated: Bool
    let insertText: String
    /// The parentheses accepting adds after `insertText`, for a method; `nil` for anything else.
    var parentheses: Parentheses?

    enum Parentheses: Equatable {
        /// `(|)`, with parameter hints for what goes between.
        case withArguments
        /// `()|`.
        case withoutArguments
    }
}

/// What the hover card shows for a name.
struct CodeHoverContent: Equatable {
    let range: NSRange
    /// Such as `Book.title: String!`.
    let signature: String
    let summary: String?
    let deprecationReason: String?
}

/// What a suggestion names, for its badge in the list.
enum CodeSymbolKind: Hashable, Sendable {
    case field
    case argument
    case inputField
    case enumValue
    case variable
    case directive
    case type
    case fragment
    case keyword
    case namespace
    case property
    case method
    /// A name a script declared itself.
    case local
    /// A Reqling variable's name, completed inside a script's string.
    case scriptVariable
    case jsonKey

    var badge: String {
        switch self {
        case .field: "F"
        case .argument: "A"
        case .inputField: "I"
        case .enumValue: "E"
        case .variable: "$"
        case .directive: "@"
        case .type: "T"
        case .fragment: "…"
        case .keyword: "K"
        case .namespace: "N"
        case .property: "P"
        case .method: "M"
        case .local: "L"
        case .scriptVariable: "V"
        case .jsonKey: "J"
        }
    }

    /// Spoken by VoiceOver with the highlighted suggestion.
    var spokenName: String {
        switch self {
        case .field: "field"
        case .argument: "argument"
        case .inputField: "input field"
        case .enumValue: "enum value"
        case .variable: "variable"
        case .directive: "directive"
        case .type: "type"
        case .fragment: "fragment"
        case .keyword: "keyword"
        case .namespace: "object"
        case .property: "property"
        case .method: "method"
        case .local: "local name"
        case .scriptVariable: "variable"
        case .jsonKey: "JSON key"
        }
    }

    /// System colors, so the badges read in both appearances.
    var tint: Color {
        switch self {
        case .field, .inputField, .property: Color(nsColor: .systemBlue)
        case .argument, .jsonKey: Color(nsColor: .systemTeal)
        case .enumValue, .method: Color(nsColor: .systemPurple)
        case .variable, .scriptVariable, .local: Color(nsColor: .systemOrange)
        case .directive: Color(nsColor: .systemPink)
        case .type, .fragment, .namespace: Color(nsColor: .systemGreen)
        case .keyword: Color(nsColor: .secondaryLabelColor)
        }
    }
}
