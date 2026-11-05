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
}

/// Suggestions for the name at the cursor, already ranked by what is typed there.
struct CodeCompletionList: Equatable {
    /// What accepting an item replaces: the whole name being typed, or an empty range at the cursor.
    let replacementRange: NSRange
    let items: [CodeCompletionItem]
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
        }
    }

    /// System colors, so the badges read in both appearances.
    var tint: Color {
        switch self {
        case .field, .inputField: Color(nsColor: .systemBlue)
        case .argument: Color(nsColor: .systemTeal)
        case .enumValue: Color(nsColor: .systemPurple)
        case .variable: Color(nsColor: .systemOrange)
        case .directive: Color(nsColor: .systemPink)
        case .type, .fragment: Color(nsColor: .systemGreen)
        case .keyword: Color(nsColor: .secondaryLabelColor)
        }
    }
}
