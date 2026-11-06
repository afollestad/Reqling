import ReqlingKit
import SwiftUI

/// A tree pane: the in-place search above a `BodyTreeView` on the editors' surface.
struct BodyTreePane: View {
    let structure: BodyStructure
    @Bindable var search: BodySearchModel
    let controller: BodyTreeController
    let accessibilityLabel: String
    /// A live timeline opens at its end, where it follows the newest rows, and stays there through resizes.
    var isLive = false
    /// Whether the tree is scrolled to its end, for a live timeline's Jump to Bottom.
    var onScrolledToEndChange: ((Bool) -> Void)?

    var body: some View {
        VStack(spacing: 6) {
            if search.isPresented {
                BodySearchBar(search: search)
            }
            BodyTreeView(
                structure: structure,
                currentMatch: search.isPresented ? search.currentTreeMatch : nil,
                controller: controller,
                accessibilityLabel: accessibilityLabel,
                onFind: { search.perform($0) },
                followsNewest: !search.isPresented,
                isLive: isLive,
                onScrolledToEndChange: onScrolledToEndChange
            )
            .editorChrome()
        }
        .task(id: search.key(for: .tree(structure))) {
            await search.search(in: .tree(structure))
        }
    }
}
