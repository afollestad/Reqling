import AppKit
import ReqlingKit
import SwiftUI

/// Shows a read-only body of any size; see `CodeViewerView` for how. Pair it with `CodeViewerPane`, which adds the
/// in-place search. AppKit because SwiftUI's text views lay out the whole text at once, which stalls on a multi-megabyte
/// body.
struct CodeViewer: NSViewRepresentable {
    let document: TextDocument
    /// Each line's style when `document` is a `DiffDocument`'s text.
    var diff: [DiffLineStyle]?
    var matches: [Range<Int>] = []
    var currentMatch: Range<Int>?
    var accessibilityLabel: String
    /// The Find menu reaching the viewer while it has focus.
    var onFind: ((NSTextFinder.Action) -> Void)?

    func makeNSView(context: Context) -> CodeViewerView {
        CodeViewerView()
    }

    func updateNSView(_ view: CodeViewerView, context: Context) {
        view.accent = context.environment.appAccent
        view.onFind = onFind
        view.documentView.label = accessibilityLabel
        view.setDocument(document, diff: diff)
        view.setMatches(matches, current: currentMatch)
    }
}

/// A `CodeViewer` on the editors' surface, with `BodySearchBar` above it while searching.
struct CodeViewerPane: View {
    let document: TextDocument
    /// Each line's style when `document` is a `DiffDocument`'s text, which draws the diff's gutter and colors.
    var diff: [DiffLineStyle]?
    @Bindable var search: BodySearchModel
    let accessibilityLabel: String

    var body: some View {
        VStack(spacing: 6) {
            if search.isPresented {
                BodySearchBar(search: search)
            }
            CodeViewer(
                document: document,
                diff: diff,
                matches: search.isPresented ? search.result.textMatches : [],
                currentMatch: search.isPresented ? search.currentTextMatch : nil,
                accessibilityLabel: accessibilityLabel,
                onFind: { search.perform($0) }
            )
            .editorChrome()
        }
        .task(id: search.key(for: .text(document))) {
            await search.search(in: .text(document))
        }
    }
}
