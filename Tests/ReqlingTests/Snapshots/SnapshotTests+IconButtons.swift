import SwiftUI
import XCTest

@testable import Reqling

extension SnapshotTests {
    /// Every state of an icon button's tile, for symbols that draw at different sizes on their own (Copy beside Save
    /// among them). Hover and press can't be triggered offscreen, so this sets each state on `IconButtonTile` directly.
    func testIconButtonStates() {
        assertBothAppearances(IconButtonStateGrid(), size: CGSize(width: 420, height: 150))
    }
}

private struct IconButtonStateGrid: View {
    private struct TileState {
        let name: String
        var isHovered = false
        var isPressed = false
        var isSelected = false
        var isEnabled = true
    }

    private static let glyphs = ["doc.on.doc", "arrow.down.to.line", "pencil", "minus.circle"]
    private static let states = [
        TileState(name: "Idle"),
        TileState(name: "Hover", isHovered: true),
        TileState(name: "Pressed", isPressed: true),
        TileState(name: "On", isSelected: true),
        TileState(name: "On+Hover", isHovered: true, isSelected: true),
        TileState(name: "Disabled", isEnabled: false)
    ]

    var body: some View {
        Grid(horizontalSpacing: 14, verticalSpacing: 6) {
            GridRow {
                ForEach(Self.states, id: \.name) { state in
                    Text(state.name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(Self.glyphs, id: \.self) { glyph in
                GridRow {
                    ForEach(Self.states, id: \.name) { state in
                        IconButtonTile(isHovered: state.isHovered, isPressed: state.isPressed, isSelected: state.isSelected) {
                            Image(systemName: glyph)
                        }
                        .disabled(!state.isEnabled)
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
