import SwiftUI

/// The drag's chrome over the list: its event monitor, and the line or border showing where a drop lands.
///
/// Drawn over the whole list, never on a row, whose background the list lifts out of the row and so would misplace. Its
/// geometry is in the window's coordinates (`SidebarDragGeometry`), so it draws from the list's origin there. It takes no
/// clicks.
struct SidebarDragOverlay: View {
    let drag: SidebarDragController

    var body: some View {
        let origin = drag.listOrigin
        ZStack(alignment: .topLeading) {
            SidebarListGeometryReader(role: .list)
            SidebarDragMonitor(drag: drag, state: drag.state)
            if let candidate = drag.candidate, let visible = drag.visibleFrame?.offsetBy(dx: -origin.x, dy: -origin.y) {
                if let line = candidate.line {
                    SidebarDropLine(start: CGPoint(x: line.x - origin.x, y: line.y - origin.y), visible: visible)
                        .transition(.opacity)
                }
                if let border = candidate.border {
                    SidebarDropBorder(span: border.offsetBy(dx: -origin.x, dy: -origin.y), visible: visible)
                        .transition(.opacity)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Where a drop inserts: an accent line from the level's indent to near the trailing edge, kept within the visible list.
struct SidebarDropLine: View {
    static let thickness: CGFloat = 2

    let start: CGPoint
    let visible: CGRect

    @Environment(\.appAccent) private var accent

    var body: some View {
        let width = max(visible.maxX - SidebarDropMetrics.lineInset - start.x, 0)
        let top = min(max(start.y - Self.thickness / 2, visible.minY), visible.maxY - Self.thickness)
        Rectangle()
            .fill(Color(nsColor: accent))
            .frame(width: width, height: Self.thickness)
            .offset(x: start.x, y: top)
    }
}

/// A folder or project a drop goes into: an accent-tinted box around its row and open contents, clipped to the
/// visible list, as Alveary draws a drop container.
struct SidebarDropBorder: View {
    /// Inside the list's edges, and outside the inset selection highlight, so a selected row's fill stays within it.
    static let horizontalInset: CGFloat = 3
    /// Clears the rows it wraps, whose selection highlight otherwise traces the same edge.
    static let verticalOutset: CGFloat = 2

    let span: CGRect
    let visible: CGRect

    @Environment(\.appAccent) private var accent

    var body: some View {
        let top = max(span.minY - Self.verticalOutset, visible.minY)
        let bottom = min(span.maxY + Self.verticalOutset, visible.maxY)
        let shape = RoundedRectangle(cornerRadius: AppMetrics.containerCornerRadius, style: .continuous)
        shape
            .fill(Color(nsColor: accent).opacity(0.16))
            .overlay { shape.strokeBorder(Color(nsColor: accent).opacity(0.55), lineWidth: 1.5) }
            .frame(width: max(visible.width - Self.horizontalInset * 2, 0), height: max(bottom - top, 0))
            .offset(x: visible.minX + Self.horizontalInset, y: top)
    }
}
