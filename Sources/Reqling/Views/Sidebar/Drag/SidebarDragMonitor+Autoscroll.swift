import AppKit

/// How fast to scroll for a pointer inside `viewport`: ramping up to `maximumSpeed` toward either edge, and `0` in the
/// middle and anywhere outside.
func sidebarAutoscrollVelocity(location: CGPoint, viewport: CGRect, edgeBand: CGFloat = 32, maximumSpeed: CGFloat = 12) -> CGFloat {
    guard edgeBand > 0, maximumSpeed > 0,
          location.x >= viewport.minX, location.x <= viewport.maxX,
          location.y >= viewport.minY, location.y <= viewport.maxY else {
        return 0
    }
    let fromTop = location.y - viewport.minY
    if fromTop < edgeBand {
        return -maximumSpeed * (1 - fromTop / edgeBand)
    }
    let fromBottom = viewport.maxY - location.y
    if fromBottom < edgeBand {
        return maximumSpeed * (1 - fromBottom / edgeBand)
    }
    return 0
}

/// The clip view's next origin for one autoscroll tick. Clamped by `constrainBoundsRect(_:)` rather than a range from
/// zero, because the list's insets can give a short document a negative resting origin.
@MainActor
func sidebarAutoscrollOriginY(clipView: NSClipView, velocity: CGFloat, documentIsFlipped: Bool) -> CGFloat {
    var proposed = clipView.bounds
    proposed.origin.y += documentIsFlipped ? velocity : -velocity
    return clipView.constrainBoundsRect(proposed).origin.y
}
