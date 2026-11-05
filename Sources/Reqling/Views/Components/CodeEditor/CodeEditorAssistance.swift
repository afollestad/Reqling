import AppKit
import SwiftUI

/// What shows the completion list and the hover card. Editor tests swap in a recorder; only the panels' own test puts
/// one on screen.
@MainActor
protocol CodeEditorPopupPresenting: AnyObject {
    /// `anchor` is in screen coordinates: the first character the list completes, or the name the card describes.
    func showCompletions(_ model: CodeCompletionModel, below anchor: NSRect, from view: NSView)
    func hideCompletions()
    func showHover(_ content: CodeHoverCardContent, below anchor: NSRect, from view: NSView)
    func hideHover()
}

/// One editor's completion and hover state, kept together so `CodeTextView` holds a single reference.
@MainActor
final class CodeEditorAssistance {
    weak var assistant: (any CodeEditorAssistant)?
    var presenter: any CodeEditorPopupPresenting = CodeEditorPopupPanels()
    /// The open list; nil when none is.
    var completion: Completion?
    /// What `insertText` is inserting, so `didChangeText` can tell typing from pastes, undo, and outside changes.
    var typing: String?
    /// Set while an accepted item is inserted, which must not reopen the list.
    var isAccepting = false
    /// How long the pointer rests on a name before its card shows.
    var hoverDelay: Duration = .milliseconds(600)
    var sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    var hoverTask: Task<Void, Never>?
    /// The character the pointer rests on, and the range the shown card describes.
    var hoverOffset: Int?
    var hoverRange: NSRange?
    var trackingArea: NSTrackingArea?
    /// Closes both when the window stops being key, as when the app is deactivated, which hides the panels.
    var windowObserver: (any NSObjectProtocol)?

    struct Completion {
        let model: CodeCompletionModel
        var replacementRange: NSRange
        /// Opened with ⌃Space, ⌥Esc, or F5: it stays open with nothing typed.
        let isForced: Bool
    }

    isolated deinit {
        windowObserver.map(NotificationCenter.default.removeObserver)
        hoverTask?.cancel()
        presenter.hideCompletions()
        presenter.hideHover()
    }
}

/// Shows the list and the card in borderless panels attached to the editor's window, which never take key focus, so
/// typing stays in the editor and the window keeps its look.
@MainActor
final class CodeEditorPopupPanels: CodeEditorPopupPresenting {
    private var completionPanel: CodeEditorPopupPanel?
    private var hoverPanel: CodeEditorPopupPanel?

    func showCompletions(_ model: CodeCompletionModel, below anchor: NSRect, from view: NSView) {
        guard let window = view.window, window.isVisible else {
            return
        }
        let panel = completionPanel ?? CodeEditorPopupPanel(ignoresMouse: false)
        completionPanel = panel
        // Each opening brings a new model, so the reused panel shows the one it is given, never the first it showed.
        panel.place(
            CodeCompletionListView(model: model).appAccent(Self.accent(of: view)),
            below: anchor,
            attachedTo: window,
            appearance: view.effectiveAppearance,
            width: CodeCompletionModel.width
        )
    }

    func hideCompletions() {
        completionPanel?.detach()
    }

    func showHover(_ content: CodeHoverCardContent, below anchor: NSRect, from view: NSView) {
        guard let window = view.window, window.isVisible else {
            return
        }
        hoverPanel?.detach()
        let panel = CodeEditorPopupPanel(ignoresMouse: true)
        hoverPanel = panel
        panel.place(
            CodeHoverCard(content: content).appAccent(Self.accent(of: view)),
            below: anchor,
            attachedTo: window,
            appearance: view.effectiveAppearance,
            width: CodeHoverCard.maxWidth
        )
    }

    func hideHover() {
        hoverPanel?.detach()
        hoverPanel = nil
    }

    /// The accent the editor draws with, which panel content cannot inherit from the window's SwiftUI environment.
    private static func accent(of view: NSView) -> NSColor {
        (view as? CodeTextView)?.accentColor ?? .controlAccentColor
    }
}

/// A panel that shows SwiftUI content beside a window without becoming key or main.
final class CodeEditorPopupPanel: NSPanel {
    private let host: NSHostingView<AnyView> = FirstMouseHostingView(rootView: AnyView(EmptyView()))

    init(ignoresMouse: Bool) {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = true
        ignoresMouseEvents = ignoresMouse
        contentView = host
    }

    override var canBecomeKey: Bool {
        false
    }

    override var canBecomeMain: Bool {
        false
    }

    /// Shows `content`, sized at `width`, under `anchor`, or above it when the screen ends first, and attaches the
    /// panel to `window` so it moves with it. `content` carries its own `appAccent`, which a panel cannot inherit from
    /// the window's SwiftUI environment.
    func place(_ content: some View, below anchor: NSRect, attachedTo window: NSWindow, appearance: NSAppearance, width: CGFloat) {
        self.appearance = appearance
        host.rootView = AnyView(content)
        let fitting = NSHostingController(rootView: host.rootView).sizeThatFits(in: CGSize(width: width, height: 2_000))
        let visible = window.screen?.visibleFrame ?? .infinite
        var origin = NSPoint(x: anchor.minX - 6, y: anchor.minY - fitting.height - 4)
        if origin.y < visible.minY {
            origin.y = anchor.maxY + 4
        }
        origin.x = min(max(origin.x, visible.minX), visible.maxX - fitting.width)
        setFrame(NSRect(origin: origin, size: fitting), display: true)
        if parent !== window {
            parent?.removeChildWindow(self)
            window.addChildWindow(self, ordered: .above)
        }
        orderFront(nil)
    }

    func detach() {
        parent?.removeChildWindow(self)
        orderOut(nil)
    }
}

/// Takes the click that first reaches an inactive panel, so one click on a suggestion accepts it.
private final class FirstMouseHostingView: NSHostingView<AnyView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}
