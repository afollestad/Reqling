import AppKit

extension SidebarDragMonitorView {
    /// Polls Escape and the mouse button through the drag, on `.common` so it fires during mouse tracking.
    ///
    /// AppKit's tracking loops dequeue only mouse events, so the event monitor may never see Escape; and a loop that
    /// swallows the mouse-up too would leave a drag nothing could end, which the button's state catches.
    func startEscapeWatch() {
        guard escapeWatchTimer == nil else {
            return
        }
        pointerReleasedTicks = 0
        let timer = Timer(timeInterval: 1 / 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.escapeWatchTick()
            }
        }
        escapeWatchTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func stopEscapeWatch() {
        escapeWatchTimer?.invalidate()
        escapeWatchTimer = nil
        pointerReleasedTicks = 0
    }

    private func escapeWatchTick() {
        guard state.session != nil, let drag else {
            pointerReleasedTicks = 0
            return
        }
        switch sidebarDragWatchAction(
            isEscapePressed: drag.system.isEscapePressed(),
            isPointerDown: drag.system.isPointerDown(),
            pointerReleasedTicks: pointerReleasedTicks
        ) {
        case .keepWatching:
            pointerReleasedTicks = 0
        case .countPointerRelease:
            pointerReleasedTicks += 1
        case .escape:
            stopAutoscroll()
            stopEscapeWatch()
            drag.escape()
        case .abandon:
            stopAutoscroll()
            stopEscapeWatch()
            drag.teardown()
        }
    }
}

/// What one watch tick does about a drag whose events may no longer arrive. A released button counts once before it
/// abandons the drag, so the ordinary mouse-up, which finishes the drag a turn later, wins the race.
func sidebarDragWatchAction(isEscapePressed: Bool, isPointerDown: Bool, pointerReleasedTicks: Int) -> SidebarDragWatchAction {
    if isEscapePressed {
        return .escape
    }
    guard !isPointerDown else {
        return .keepWatching
    }
    return pointerReleasedTicks >= 1 ? .abandon : .countPointerRelease
}

enum SidebarDragWatchAction: Equatable {
    case keepWatching
    case countPointerRelease
    /// Escape is down: cancel, but keep waiting for the real mouse-up.
    case escape
    /// The button came up unseen: drop the drag, since nothing else will end it.
    case abandon
}
