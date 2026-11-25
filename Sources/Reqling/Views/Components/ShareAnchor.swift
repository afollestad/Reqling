import AppKit
import SwiftUI

/// An empty view behind a sidebar row or Share button, standing for it in `ShareAnchors`.
struct ShareAnchor: NSViewRepresentable {
    /// Never the target of a click, which belongs to the row or button in front (`sidebarRowClick`).
    private final class AnchorView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }
    }

    let origin: ShareOrigin
    let anchors: ShareAnchors

    func makeNSView(context: Context) -> NSView {
        AnchorView()
    }

    func updateNSView(_ view: NSView, context: Context) {
        anchors.register(view, as: origin)
    }
}
