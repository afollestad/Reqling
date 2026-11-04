@preconcurrency import AppKit
import SwiftUI

/// An `info.circle` whose explanation opens in a popover on hover or click, ported from Alveary.
///
/// Plain `.help(...)` on a glyph is easy to miss: the system tooltip waits out a long hover delay, a click does
/// nothing, and inside a toggle row's button the click flips the setting instead. This AppKit button takes its own
/// mouse events, so it never reaches an enclosing SwiftUI button, and it stays enabled under a disabled row because it
/// explains disabled settings too.
struct AppHoverInfoIcon: View {
    let text: String

    var body: some View {
        AppHoverInfoIconRepresentable(text: text)
            .frame(width: 14, height: 14)
    }
}

@MainActor
final class AppKitHoverInfoButton: NSButton {
    private static let iconConfiguration = NSImage.SymbolConfiguration(pointSize: 10.5, weight: .medium)

    private var trackingArea: NSTrackingArea?
    private let hoverTooltip = AppKitHoverTooltipController()
    private var helpText: String?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 14, height: 14)
    }

    override var isEnabled: Bool {
        get { true }
        set {
            // A disabled row disables its subviews, but this explains why, so it ignores that and keeps its look.
            _ = newValue
            super.isEnabled = true
            alphaValue = 1
            refreshIconImage()
        }
    }

    func configure(helpText: String) {
        let changed = self.helpText != helpText
        self.helpText = helpText
        toolTip = nil
        setAccessibilityLabel("More information")
        setAccessibilityValue(helpText)
        setAccessibilityHelp(helpText)
        // Rebuild an open popover only when its text changes; hover-driven parent updates would otherwise collapse its
        // measured wrapped height.
        if changed, hoverTooltip.isShown {
            showHoverTooltip()
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        trackingArea = area
        addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) {
        showHoverTooltip()
    }

    override func mouseExited(with event: NSEvent) {
        closeHoverTooltip()
    }

    override func mouseDown(with event: NSEvent) {
        showHoverTooltip()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refreshIconImage()
        if window == nil {
            closeHoverTooltip()
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshIconImage()
        if hoverTooltip.isShown {
            showHoverTooltip()
        }
    }

    func closeHoverTooltip() {
        hoverTooltip.close()
    }

    /// Beside the icon when the screen has room on the right, else above it.
    func preferredTooltipEdge(for contentSize: NSSize) -> NSRectEdge {
        guard let window else {
            return .maxY
        }
        let visibleFrame = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let screenRect = window.convertToScreen(convert(bounds, to: nil))
        return visibleFrame.maxX - screenRect.maxX >= contentSize.width + 12 ? .maxX : .maxY
    }

    private func setup() {
        isBordered = false
        refusesFirstResponder = true
        imagePosition = .imageOnly
        imageScaling = .scaleNone
        alignment = .center
        setButtonType(.momentaryChange)
        (cell as? NSButtonCell)?.highlightsBy = []
        (cell as? NSButtonCell)?.showsStateBy = []
        refreshIconImage()
    }

    /// The glyph pre-tinted muted gray for the current appearance, so a row's selected or disabled state never
    /// recolors it.
    private func refreshIconImage() {
        let appearance = self.appearance ?? window?.effectiveAppearance ?? effectiveAppearance
        var color = NSColor.secondaryLabelColor
        // Keep the semantic color's own alpha; forcing it opaque makes the dark-mode glyph read white.
        appearance.performAsCurrentDrawingAppearance {
            color = NSColor.secondaryLabelColor.usingColorSpace(.sRGB) ?? NSColor.secondaryLabelColor
        }
        guard let symbol = NSImage(systemSymbolName: "info.circle", accessibilityDescription: "More information")?
            .withSymbolConfiguration(Self.iconConfiguration) else {
            image = nil
            return
        }
        let tinted = NSImage(size: symbol.size)
        tinted.lockFocus()
        let rect = NSRect(origin: .zero, size: symbol.size)
        color.setFill()
        rect.fill()
        symbol.draw(in: rect, from: .zero, operation: .destinationIn, fraction: 1)
        tinted.unlockFocus()
        image = tinted
        contentTintColor = nil
    }

    private func showHoverTooltip() {
        guard let helpText, !helpText.isEmpty, window != nil else {
            return
        }
        hoverTooltip.show(text: helpText, relativeTo: self)
    }
}

private struct AppHoverInfoIconRepresentable: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> AppKitHoverInfoButton {
        AppKitHoverInfoButton()
    }

    func updateNSView(_ nsView: AppKitHoverInfoButton, context: Context) {
        nsView.configure(helpText: text)
    }

    static func dismantleNSView(_ nsView: AppKitHoverInfoButton, coordinator: ()) {
        nsView.closeHoverTooltip()
    }
}

/// The popover behind `AppKitHoverInfoButton`. Its window ignores the mouse, so the pointer moving onto it can't
/// fire the button's exit and flicker it closed.
@MainActor
final class AppKitHoverTooltipController {
    private var popover: NSPopover?

    var isShown: Bool {
        popover?.isShown == true
    }

    func show(text: String, relativeTo sourceView: AppKitHoverInfoButton) {
        close()
        guard sourceView.window != nil else {
            return
        }
        let controller = NSHostingController(rootView: AppHoverTooltipContent(text: text))
        let size = controller.view.fittingSize
        controller.preferredContentSize = size
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = false
        popover.contentViewController = controller
        popover.contentSize = size
        self.popover = popover
        popover.show(relativeTo: sourceView.bounds, of: sourceView, preferredEdge: sourceView.preferredTooltipEdge(for: size))
        ignoreMouse(in: popover)
        // The popover's window can arrive a turn after `show`, so set it again once it has.
        Task { @MainActor [weak self, weak popover] in
            await Task.yield()
            guard let self, let popover, self.popover === popover else {
                return
            }
            self.ignoreMouse(in: popover)
        }
    }

    func close() {
        popover?.performClose(nil)
        popover = nil
    }

    private func ignoreMouse(in popover: NSPopover) {
        popover.contentViewController?.view.window?.ignoresMouseEvents = true
    }
}

/// The popover's text: one line when short, wrapped at 280pt when not.
struct AppHoverTooltipContent: View {
    private static let maxTextWidth: CGFloat = 280
    /// The font the text draws in (`.callout`, semibold), so the wrap decision matches what renders.
    private static let textFont = NSFont.systemFont(ofSize: NSFont.preferredFont(forTextStyle: .callout).pointSize, weight: .semibold)

    let text: String

    var body: some View {
        let wraps = Self.wraps(text)
        Text(text)
            .font(.callout.weight(.semibold))
            .foregroundStyle(.primary)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: !wraps, vertical: true)
            .frame(width: wraps ? Self.maxTextWidth : nil, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 15)
    }

    static func wraps(_ text: String) -> Bool {
        ceil((text as NSString).size(withAttributes: [.font: textFont]).width) > maxTextWidth
    }
}
