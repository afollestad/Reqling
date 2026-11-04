import AppKit
import ReqlingKit
import SwiftUI

/// Shows a read-only body of any size; see `CodeViewerView` for how. Pair it with `CodeViewerPane`, which adds the
/// in-place search.
struct CodeViewer: NSViewRepresentable {
    let document: TextDocument
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
        view.setDocument(document)
        view.setMatches(matches, current: currentMatch)
    }
}

/// A `CodeViewer` on the editors' surface, with `BodySearchBar` above it while searching.
struct CodeViewerPane: View {
    let document: TextDocument
    @Bindable var search: BodySearchModel
    let accessibilityLabel: String

    var body: some View {
        VStack(spacing: 6) {
            if search.isPresented {
                BodySearchBar(search: search)
            }
            CodeViewer(
                document: document,
                matches: search.isPresented ? search.result.matches : [],
                currentMatch: search.isPresented ? search.currentMatch : nil,
                accessibilityLabel: accessibilityLabel,
                onFind: { search.perform($0) }
            )
            .editorChrome()
        }
        .task(id: search.key(for: document)) {
            await search.search(in: document)
        }
    }
}
