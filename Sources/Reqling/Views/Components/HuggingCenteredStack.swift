import SwiftUI

/// Lines stacked and centered on each other, as wide as the widest one up to `maxWidth`, past which they're proposed
/// `maxWidth` and truncate as their `truncationMode` says.
///
/// `.frame(maxWidth:)` can't do this: offered more room than its content needs, as a toolbar offers its items, it grows
/// to `maxWidth`, and the lines float in the extra space instead of hugging the longest.
struct HuggingCenteredStack: Layout {
    let maxWidth: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = width(for: proposal, subviews: subviews)
        let height = subviews.reduce(0) { $0 + $1.sizeThatFits(ProposedViewSize(width: width, height: nil)).height }
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var top = bounds.minY
        for subview in subviews {
            let lineProposal = ProposedViewSize(width: bounds.width, height: nil)
            subview.place(at: CGPoint(x: bounds.midX, y: top), anchor: .top, proposal: lineProposal)
            top += subview.sizeThatFits(lineProposal).height
        }
    }

    private func width(for proposal: ProposedViewSize, subviews: Subviews) -> CGFloat {
        let widest = subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0
        return min(widest, maxWidth, proposal.width ?? .infinity)
    }
}
