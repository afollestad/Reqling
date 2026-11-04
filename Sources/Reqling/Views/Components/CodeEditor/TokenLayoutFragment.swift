import AppKit

/// Draws rounded pills behind the `{{variable}}` tokens in its paragraph, then the text on top.
///
/// It draws only from the pills it was created with, never by reaching back into the text view, because TextKit may
/// draw off the main actor. Showing different pills means recreating fragments (`CodeTextView.rebuildPills`);
/// invalidating layout keeps these ones.
final class TokenLayoutFragment: NSTextLayoutFragment {
    struct Pill {
        /// Relative to the paragraph, the same space as each line fragment's `characterRange`.
        let range: NSRange
        let fill: CGColor
    }

    var pills: [Pill] = []

    private static let horizontalPadding: CGFloat = 2

    override var renderingSurfaceBounds: CGRect {
        super.renderingSurfaceBounds.insetBy(dx: -Self.horizontalPadding - 1, dy: -1)
    }

    override func draw(at point: CGPoint, in context: CGContext) {
        let radius = AppMetrics.badgeCornerRadius
        for pill in pills {
            context.setFillColor(pill.fill)
            for line in textLineFragments {
                let overlap = NSIntersectionRange(pill.range, line.characterRange)
                guard overlap.length > 0 else {
                    continue
                }
                let startX = line.locationForCharacter(at: overlap.location).x
                let endX = line.locationForCharacter(at: NSMaxRange(overlap)).x
                let bounds = line.typographicBounds
                let rect = CGRect(
                    x: point.x + bounds.minX + startX - Self.horizontalPadding,
                    y: point.y + bounds.minY,
                    width: endX - startX + Self.horizontalPadding * 2,
                    height: bounds.height
                )
                context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
                context.fillPath()
            }
        }
        super.draw(at: point, in: context)
    }
}
