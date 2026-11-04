import SwiftUI

/// Shows `preferred` while the width it is offered fits `preferred`'s ideal width, and `fallback` once it doesn't.
///
/// The main window's stand-in for `ViewThatFits`. That measures every candidate on every layout pass, and the window's
/// root hosting view runs a pass per frame of a resize or split-divider drag just to recompute the window's minimum
/// size, proposing zero so that no candidate fits and all of them get measured; nested in the request and response
/// panes, that was most of each frame. This measures `preferred` through a hidden copy, which SwiftUI sizes again
/// only when its content changes, and switches when its own width crosses that size.
///
/// It fills the width it is offered, with its content at `alignment`, so give it a row of its own. Its minimum width
/// is zero, which leaves the window's minimum size to the content around it.
struct WidthAdaptive<Preferred: View, Fallback: View>: View {
    private let alignment: Alignment
    private let preferred: Preferred
    private let fallback: Fallback

    @State private var preferredWidth: CGFloat = 0
    @State private var fits = true

    init(alignment: Alignment = .leading, @ViewBuilder preferred: () -> Preferred, @ViewBuilder fallback: () -> Fallback) {
        self.alignment = alignment
        self.preferred = preferred()
        self.fallback = fallback()
    }

    var body: some View {
        // Captured by value: a new measurement re-renders this view, which hands the geometry observer a new
        // threshold and so re-evaluates `fits` against it.
        let threshold = preferredWidth
        Group {
            if fits {
                preferred
            } else {
                fallback
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: alignment)
        .background(alignment: .topLeading) {
            preferred
                .fixedSize()
                .hidden()
                .accessibilityHidden(true)
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.width
                } action: { width in
                    preferredWidth = width
                }
        }
        .onGeometryChange(for: Bool.self) { proxy in
            proxy.size.width >= threshold
        } action: { newValue in
            fits = newValue
        }
    }
}
