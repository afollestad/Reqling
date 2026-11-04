import SwiftUI

/// An icon-only button: the glyph centered in a fixed square tile that tints on hover, darkens while pressed, and wears
/// the accent while `isSelected`. `.borderless` and `.plain` show none of that, and leave each symbol at its own drawn
/// size, so neighbours like Copy and Save never line up.
struct IconButtonStyle: ButtonStyle {
    var isSelected = false
    var size = AppMetrics.iconButtonSize

    func makeBody(configuration: Configuration) -> some View {
        IconButtonHoverTile(isPressed: configuration.isPressed, isSelected: isSelected, size: size) {
            configuration.label
        }
    }
}

/// An icon toggle, like a variable's secret lock: an `IconButtonStyle` tile that wears the accent while on.
struct IconToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            configuration.label
        }
        .buttonStyle(IconButtonStyle(isSelected: configuration.isOn))
        .accessibilityAddTraits(.isToggle)
        .accessibilityValue(configuration.isOn ? "On" : "Off")
    }
}

extension View {
    /// `IconButtonStyle`'s tile for an icon-labeled `Menu`. A `.borderlessButton` menu is an AppKit pop-up that drops
    /// whatever background its label draws, so the tile goes around the menu instead. The pop-up also sizes its glyph
    /// itself, so `AppMetrics.iconButtonGlyphSize` doesn't reach it. Menus get no pressed state: the menu opening is the
    /// click's feedback.
    func iconButtonChrome(isSelected: Bool = false) -> some View {
        IconButtonHoverTile(isPressed: false, isSelected: isSelected, size: AppMetrics.iconButtonSize) {
            self
        }
    }
}

/// The tile behind every icon button and icon menu. Stateless, so a snapshot can draw hover and press, which an
/// offscreen render can't trigger; `IconButtonHoverTile` feeds it the pointer.
struct IconButtonTile<Content: View>: View {
    let isHovered: Bool
    let isPressed: Bool
    let isSelected: Bool
    var size = AppMetrics.iconButtonSize
    @ViewBuilder let content: Content

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.appAccent) private var accent

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: AppMetrics.badgeCornerRadius, style: .continuous)
        content
            .font(.system(size: AppMetrics.iconButtonGlyphSize))
            .foregroundStyle(glyphStyle)
            .frame(width: size, height: size)
            .background(shape.fill(fill))
            .contentShape(shape)
    }

    private var fill: Color {
        if isSelected {
            return Color(nsColor: accent).opacity(isPressed ? 0.34 : isHovered ? 0.28 : 0.22)
        }
        guard isEnabled else {
            return .clear
        }
        if isPressed {
            return Color.primary.opacity(0.16)
        }
        return isHovered ? Color.primary.opacity(0.08) : .clear
    }

    private var glyphStyle: AnyShapeStyle {
        if !isEnabled {
            return AnyShapeStyle(.tertiary)
        }
        if isSelected {
            return AnyShapeStyle(Color(nsColor: accent))
        }
        return isHovered || isPressed ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary)
    }
}

/// Tracks the pointer for `IconButtonTile`, since `@State` can't live in a `ButtonStyle` or a modifier function. A
/// disabled control shows no hover.
private struct IconButtonHoverTile<Content: View>: View {
    let isPressed: Bool
    let isSelected: Bool
    let size: CGFloat
    @ViewBuilder let content: Content

    @State private var isHovered = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        IconButtonTile(isHovered: isHovered && isEnabled, isPressed: isPressed, isSelected: isSelected, size: size) {
            content
        }
        .onHover { isHovered = $0 }
    }
}
