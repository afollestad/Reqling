import ReqlingKit
import SwiftUI
import XCTest

@testable import Reqling

/// GraphQL editing: the completion list and the hover card, rendered as their panels hold them but never shown.
extension SnapshotTests {
    func testCompletionList() {
        let model = CodeCompletionModel()
        model.items = [
            CodeCompletionItem(id: 0, label: "books", kind: .field, detail: "[Book!]!", summary: nil, isDeprecated: false, insertText: "books"),
            CodeCompletionItem(
                id: 1, label: "book", kind: .field, detail: "Book", summary: "One book, by ID or ISBN.", isDeprecated: false, insertText: "book"
            ),
            CodeCompletionItem(id: 2, label: "first", kind: .argument, detail: "Int = 20", summary: nil, isDeprecated: false, insertText: "first"),
            CodeCompletionItem(id: 3, label: "POETRY", kind: .enumValue, detail: "Genre", summary: nil, isDeprecated: false, insertText: "POETRY"),
            CodeCompletionItem(id: 4, label: "$id", kind: .variable, detail: "ID!", summary: nil, isDeprecated: false, insertText: "$id"),
            CodeCompletionItem(id: 5, label: "nickname", kind: .field, detail: "String", summary: nil, isDeprecated: true, insertText: "nickname")
        ]
        model.highlighted = 1

        assertBothAppearances(CodeCompletionListView(model: model).padding(8), size: CGSize(width: 396, height: 180))
    }

    func testHoverCard() {
        let content = CodeHoverCardContent(
            hover: CodeHoverContent(
                range: NSRange(location: 0, length: 8),
                signature: "Author.nickname: String",
                summary: "What readers call them.",
                deprecationReason: "Use `name`."
            ),
            diagnostics: [CodeDiagnostic(range: NSRange(location: 0, length: 8), message: "Deprecated.", severity: .warning)]
        )

        assertBothAppearances(CodeHoverCard(content: content).padding(8), size: CGSize(width: 300, height: 140))
    }
}
