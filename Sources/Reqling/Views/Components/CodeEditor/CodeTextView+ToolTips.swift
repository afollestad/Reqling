import AppKit

/// Hovering a `{{variable}}` pill or a URL bar's `:name` segment explains it. One tooltip rectangle per line a token
/// spans, rebuilt whenever the tokens move (`refreshTokens`, a width change).
extension CodeTextView {
    func refreshToolTips() {
        removeAllToolTips()
        for range in templateTokens.map(\.utf16Range) + pathVariableSegments.map(\.utf16Range) {
            for rect in segmentRects(for: range) {
                addToolTip(rect, owner: self, userData: nil)
            }
        }
    }

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        let token = templateTokens.first { token in
            segmentRects(for: token.utf16Range).contains { $0.insetBy(dx: -2, dy: -2).contains(point) }
        }
        return token.map(tokenContext.tooltip(for:)) ?? pathVariableToolTip(at: point) ?? ""
    }
}
