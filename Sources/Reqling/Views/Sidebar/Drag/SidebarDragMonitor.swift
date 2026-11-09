import AppKit
import SwiftUI

/// The AppKit event hook behind a sidebar drag, mounted over the whole list (Alveary's `SidebarDragMonitor`).
///
/// It stays at the list's root, above the rows: SwiftUI's gesture only gets a drag past its threshold, and the row can
/// then scroll out of the list, taking a hook it owned with it and leaving the drag without an end. Points arriving here
/// are in the list's own coordinates.
struct SidebarDragMonitor: NSViewRepresentable {
    let drag: SidebarDragController
    /// Read here, so the view updates as a drag starts and ends.
    let state: SidebarDragState

    func makeNSView(context: Context) -> SidebarDragMonitorView {
        let view = SidebarDragMonitorView()
        view.drag = drag
        view.update(state)
        return view
    }

    func updateNSView(_ view: SidebarDragMonitorView, context: Context) {
        view.drag = drag
        view.update(state)
    }

    static func dismantleNSView(_ view: SidebarDragMonitorView, coordinator: ()) {
        view.dismantle()
    }
}

@MainActor
final class SidebarDragMonitorView: NSView {
    weak var drag: SidebarDragController?
    private(set) var state = SidebarDragState.idle
    private var eventMonitor: Any?
    private var windowObservers: [NSObjectProtocol] = []
    private var autoscrollTimer: Timer?
    private var autoscrollSessionID: UUID?
    /// The escape watch's lifecycle lives in `SidebarDragMonitor+EscapeWatch.swift`.
    var escapeWatchTimer: Timer?
    /// Consecutive watch ticks that saw the button up.
    var pointerReleasedTicks = 0
    private var pointerLocation: CGPoint?

    override var isFlipped: Bool {
        true
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            removeEventMonitor()
            removeWindowObservers()
            stopAutoscroll()
        } else {
            installEventMonitor()
            installWindowObservers()
        }
    }

    func update(_ state: SidebarDragState) {
        let previousSessionID = self.state.session?.id
        self.state = state
        switch state {
        case .active(let session):
            if previousSessionID != session.id {
                pointerLocation = window.map { convert($0.mouseLocationOutsideOfEventStream, from: nil) }
            }
            updateAutoscroll()
            startEscapeWatch()
        case .cancelledUntilMouseUp, .idle:
            pointerLocation = nil
            stopAutoscroll()
            stopEscapeWatch()
        }
    }

    func dismantle() {
        state = .idle
        removeEventMonitor()
        removeWindowObservers()
        stopAutoscroll()
        stopEscapeWatch()
    }

    // MARK: - Events

    private func installEventMonitor() {
        guard eventMonitor == nil else {
            return
        }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            // Local monitors run on the main thread.
            let swallows = MainActor.assumeIsolated {
                self?.swallows(event) ?? false
            }
            return swallows ? nil : event
        }
    }

    private func removeEventMonitor() {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
    }

    /// Acts on `event`, and says whether to keep it from its views.
    private func swallows(_ event: NSEvent) -> Bool {
        let action = sidebarDragMonitorAction(
            eventType: event.type,
            keyCode: event.type == .keyDown ? event.keyCode : 0,
            state: state,
            originatesInWindow: event.window === window
        )
        switch action {
        case .passThrough:
            return false
        case .pointerMoved:
            let location = convert(event.locationInWindow, from: nil)
            pointerLocation = location
            drag?.monitorMoved(to: location)
            updateAutoscroll()
            return false
        case .mouseUp:
            stopAutoscroll()
            drag?.monitorMouseUp(at: convert(event.locationInWindow, from: nil))
            return false
        case .escape:
            stopAutoscroll()
            drag?.escape()
            return true
        case .consumeKey:
            return true
        }
    }

    private func installWindowObservers() {
        removeWindowObservers()
        guard let window else {
            return
        }
        for name in [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification] {
            windowObservers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.windowChanged()
                }
            })
        }
    }

    private func removeWindowObservers() {
        windowObservers.forEach(NotificationCenter.default.removeObserver)
        windowObservers.removeAll()
    }

    private func windowChanged() {
        guard state != .idle else {
            return
        }
        pointerLocation = nil
        stopAutoscroll()
        drag?.teardown()
    }

    // MARK: - Autoscroll

    /// The visible part of the list in this view's coordinates, which start at the list's origin in the window.
    private var visibleBounds: CGRect {
        guard let drag, let visible = drag.visibleFrame else {
            return bounds
        }
        return visible.offsetBy(dx: -drag.listOrigin.x, dy: -drag.listOrigin.y)
    }

    private func updateAutoscroll() {
        guard case .active(let session) = state, let pointerLocation,
              sidebarAutoscrollVelocity(location: pointerLocation, viewport: visibleBounds) != 0 else {
            stopAutoscroll()
            return
        }
        if autoscrollTimer != nil, autoscrollSessionID == session.id {
            return
        }
        stopAutoscroll()
        let sessionID = session.id
        let timer = Timer(timeInterval: 1 / 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.autoscrollTick(sessionID: sessionID)
            }
        }
        autoscrollTimer = timer
        autoscrollSessionID = sessionID
        RunLoop.main.add(timer, forMode: .common)
    }

    func stopAutoscroll() {
        autoscrollTimer?.invalidate()
        autoscrollTimer = nil
        autoscrollSessionID = nil
    }

    private func autoscrollTick(sessionID: UUID) {
        // A tick queued before the timer was replaced must not drive the replacement.
        guard autoscrollSessionID == sessionID else {
            return
        }
        guard state.session?.id == sessionID, let pointerLocation else {
            stopAutoscroll()
            return
        }
        let velocity = sidebarAutoscrollVelocity(location: pointerLocation, viewport: visibleBounds)
        guard velocity != 0, let scrollView = drag?.listHost.scrollView, let documentView = scrollView.documentView else {
            stopAutoscroll()
            return
        }
        let clipView = scrollView.contentView
        let originY = sidebarAutoscrollOriginY(clipView: clipView, velocity: velocity, documentIsFlipped: documentView.isFlipped)
        guard abs(originY - clipView.bounds.origin.y) > 0.01 else {
            stopAutoscroll()
            return
        }
        clipView.scroll(to: NSPoint(x: clipView.bounds.origin.x, y: originY))
        scrollView.reflectScrolledClipView(clipView)
        // Rows publish their moved frames on the next layout pass; retargeting now keeps the line on mounted rows.
        drag?.autoscrolled()
    }
}

enum SidebarDragMonitorAction: Equatable {
    case passThrough
    case pointerMoved
    case mouseUp
    case escape
    case consumeKey
}

/// What the monitor does with an event. Mouse events always go on to their views; keys are swallowed while a drag is
/// under way, Escape cancelling it.
func sidebarDragMonitorAction(
    eventType: NSEvent.EventType,
    keyCode: UInt16,
    state: SidebarDragState,
    originatesInWindow: Bool
) -> SidebarDragMonitorAction {
    guard originatesInWindow else {
        return .passThrough
    }
    switch eventType {
    case .keyDown:
        guard state != .idle else {
            return .passThrough
        }
        if keyCode == SidebarDragKeyCode.escape {
            return state.session == nil ? .consumeKey : .escape
        }
        return SidebarDragKeyCode.suppressedDuringDrag.contains(keyCode) ? .consumeKey : .passThrough
    case .leftMouseDragged:
        if case .cancelledUntilMouseUp = state {
            return .passThrough
        }
        return .pointerMoved
    case .leftMouseUp:
        return .mouseUp
    default:
        return .passThrough
    }
}
