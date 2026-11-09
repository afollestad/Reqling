import AppKit
import SwiftUI

/// A folder's pill, which opens and closes it where the outline's caret would (`SidebarNodeRow`): a closed folder on
/// grey, or an open one on the accent.
struct SidebarFolderToggle: View {
    let isExpanded: Bool
    let toggle: @MainActor () -> Void

    var body: some View {
        Button(action: toggle) {
            SidebarFolderGlyph(isOpen: isExpanded)
        }
        .buttonStyle(SidebarFolderToggleStyle(isExpanded: isExpanded))
        .help(isExpanded ? "Collapse folder" : "Expand folder")
        .accessibilityLabel(isExpanded ? "Collapse folder" : "Expand folder")
    }
}

/// The toggle's pill. Stateless, so a snapshot can draw hover and press, which an offscreen render can't trigger;
/// `SidebarFolderHoverTile` feeds it the pointer.
struct SidebarFolderTile<Content: View>: View {
    let isOpen: Bool
    let isHovered: Bool
    let isPressed: Bool
    @ViewBuilder let content: Content

    @Environment(\.appAccent) private var accent

    var body: some View {
        // Closed, a grey made from the label color: `.secondary`, already half transparent, all but vanished from the
        // sidebar's translucent background in dark mode.
        let tint = isOpen ? Color(nsColor: accent) : .primary
        SidebarPill(tint: tint, fillOpacity: isPressed ? 0.32 : isHovered ? 0.24 : 0.16) {
            content
                .frame(width: 13, height: 10)
                .foregroundStyle(BadgeTint(color: isOpen ? tint : tint.opacity(0.7)))
        }
        .contentShape(Rectangle())
    }
}

/// A folder drawn here because SF Symbols has no open one, so the closed folder is drawn too, to match it. Open, the
/// front panel tips forward off the back one, cut a hairline apart so a single fill still reads as two panels.
struct SidebarFolderGlyph: Shape {
    let isOpen: Bool

    func path(in rect: CGRect) -> Path {
        /// A point as fractions of the glyph's width and height.
        func point(_ across: CGFloat, _ down: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + across * rect.width, y: rect.minY + down * rect.height)
        }
        let corner = rect.height * 0.14
        let tabCorner = rect.height * 0.08
        // The tab, its slope down to the shoulder, and the shoulder to the back's right edge.
        let top: [(CGPoint, CGFloat)] = [
            (point(0, 0), corner), (point(0.36, 0), tabCorner), (point(0.46, 0.2), tabCorner)
        ]
        guard isOpen else {
            return Self.roundedPolygon(top + [(point(1, 0.2), corner), (point(1, 1), corner), (point(0, 1), corner)])
        }
        let back = Self.roundedPolygon(top + [(point(0.84, 0.2), corner), (point(0.84, 1), corner), (point(0, 1), corner)])
        let front = Self.roundedPolygon([
            (point(0.2, 0.44), tabCorner), (point(1, 0.44), tabCorner), (point(0.8, 1), corner), (point(0, 1), corner)
        ])
        let gap = front.strokedPath(StrokeStyle(lineWidth: rect.height * 0.16, lineJoin: .round))
        return back.subtracting(gap).union(front)
    }

    /// Each corner rounded by its own radius, from the middle of the closing edge around.
    private static func roundedPolygon(_ corners: [(CGPoint, CGFloat)]) -> Path {
        Path { path in
            guard let first = corners.first?.0, let last = corners.last?.0 else {
                return
            }
            path.move(to: CGPoint(x: (first.x + last.x) / 2, y: (first.y + last.y) / 2))
            for (index, (vertex, radius)) in corners.enumerated() {
                path.addArc(tangent1End: vertex, tangent2End: corners[(index + 1) % corners.count].0, radius: radius)
            }
            path.closeSubpath()
        }
    }
}

private struct SidebarFolderToggleStyle: ButtonStyle {
    let isExpanded: Bool

    func makeBody(configuration: Configuration) -> some View {
        SidebarFolderHoverTile(isOpen: isExpanded, isPressed: configuration.isPressed) {
            configuration.label
        }
    }
}

/// Tracks the pointer for `SidebarFolderTile`, since `@State` can't live in a `ButtonStyle`. Disabled while filtering,
/// when it shows no hover.
private struct SidebarFolderHoverTile<Content: View>: View {
    let isOpen: Bool
    let isPressed: Bool
    @ViewBuilder let content: Content

    @State private var isHovered = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        SidebarFolderTile(isOpen: isOpen, isHovered: isHovered && isEnabled, isPressed: isPressed) {
            content
        }
        .onHover { isHovered = $0 }
    }
}
