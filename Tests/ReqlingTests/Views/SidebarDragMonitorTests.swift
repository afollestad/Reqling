import AppKit
import ReqlingKit
import XCTest

@testable import Reqling

/// What the sidebar drag's event monitor does with events, its escape watch with the hardware state, and its autoscroll
/// with the pointer.
@MainActor
final class SidebarDragMonitorTests: XCTestCase {
    func testMouseEventsReachTheirViewsAndKeysAreSwallowedOnlyDuringADrag() {
        let active = SidebarDragState.active(SidebarDragSession(source: .project(ProjectID()), sourceNodes: []))
        let cancelled = SidebarDragState.cancelledUntilMouseUp(UUID())
        func action(_ type: NSEvent.EventType, key: UInt16 = 0, _ state: SidebarDragState, inWindow: Bool = true) -> SidebarDragMonitorAction {
            sidebarDragMonitorAction(eventType: type, keyCode: key, state: state, originatesInWindow: inWindow)
        }

        XCTAssertEqual(action(.leftMouseDragged, .idle), .pointerMoved, "The pointer is seen before the row's gesture starts")
        XCTAssertEqual(action(.leftMouseDragged, cancelled), .passThrough)
        XCTAssertEqual(action(.leftMouseUp, active), .mouseUp)
        XCTAssertEqual(action(.leftMouseUp, active, inWindow: false), .passThrough)
        XCTAssertEqual(action(.keyDown, key: 36, .idle), .passThrough, "Return renames when nothing is dragged")
        XCTAssertEqual(action(.keyDown, key: 36, active), .consumeKey)
        XCTAssertEqual(action(.keyDown, key: 125, active), .consumeKey)
        XCTAssertEqual(action(.keyDown, key: 0, active), .passThrough, "Only keys that would act on the sidebar are held")
        XCTAssertEqual(action(.keyDown, key: SidebarDragKeyCode.escape, active), .escape)
        XCTAssertEqual(action(.keyDown, key: SidebarDragKeyCode.escape, cancelled), .consumeKey)
    }

    /// A released button counts once before abandoning, so the real mouse-up, a turn behind, wins the race.
    func testTheWatchAbandonsADragOnlyOnTheSecondTickWithTheButtonUp() {
        XCTAssertEqual(sidebarDragWatchAction(isEscapePressed: true, isPointerDown: true, pointerReleasedTicks: 0), .escape)
        XCTAssertEqual(sidebarDragWatchAction(isEscapePressed: false, isPointerDown: true, pointerReleasedTicks: 1), .keepWatching)
        XCTAssertEqual(sidebarDragWatchAction(isEscapePressed: false, isPointerDown: false, pointerReleasedTicks: 0), .countPointerRelease)
        XCTAssertEqual(sidebarDragWatchAction(isEscapePressed: false, isPointerDown: false, pointerReleasedTicks: 1), .abandon)
    }

    func testAutoscrollRampsUpTowardEitherEdgeOnly() {
        let viewport = CGRect(x: 0, y: 100, width: 200, height: 200)

        XCTAssertEqual(sidebarAutoscrollVelocity(location: CGPoint(x: 100, y: 100), viewport: viewport), -12)
        XCTAssertEqual(sidebarAutoscrollVelocity(location: CGPoint(x: 100, y: 116), viewport: viewport), -6)
        XCTAssertEqual(sidebarAutoscrollVelocity(location: CGPoint(x: 100, y: 200), viewport: viewport), 0)
        XCTAssertEqual(sidebarAutoscrollVelocity(location: CGPoint(x: 100, y: 284), viewport: viewport), 6)
        XCTAssertEqual(sidebarAutoscrollVelocity(location: CGPoint(x: 100, y: 99), viewport: viewport), 0, "Above the list")
        XCTAssertEqual(sidebarAutoscrollVelocity(location: CGPoint(x: 201, y: 100), viewport: viewport), 0, "Beside the list")
    }

    func testAutoscrollFollowsTheDocumentsDirectionAndStopsAtItsEnds() {
        let flipped = scrollView(documentHeight: 300, isFlipped: true)
        flipped.contentView.scroll(to: NSPoint(x: 0, y: 4))
        XCTAssertEqual(sidebarAutoscrollOriginY(clipView: flipped.contentView, velocity: -12, documentIsFlipped: true), 0)
        flipped.contentView.scroll(to: NSPoint(x: 0, y: 196))
        XCTAssertEqual(sidebarAutoscrollOriginY(clipView: flipped.contentView, velocity: 12, documentIsFlipped: true), 200)

        let unflipped = scrollView(documentHeight: 300, isFlipped: false)
        unflipped.contentView.scroll(to: NSPoint(x: 0, y: 100))
        XCTAssertEqual(sidebarAutoscrollOriginY(clipView: unflipped.contentView, velocity: 12, documentIsFlipped: false), 88)
    }

    /// A short document with insets rests at a negative origin, which a range from zero would scroll it away from.
    func testAutoscrollLeavesAShortInsetDocumentWhereItRests() {
        let view = scrollView(documentHeight: 80, isFlipped: true, insets: NSEdgeInsets(top: 12, left: 0, bottom: 8, right: 0))

        XCTAssertEqual(view.contentView.bounds.origin.y, -12)
        XCTAssertEqual(sidebarAutoscrollOriginY(clipView: view.contentView, velocity: 12, documentIsFlipped: true), -12)
    }

    private func scrollView(documentHeight: CGFloat, isFlipped: Bool, insets: NSEdgeInsets = NSEdgeInsets()) -> NSScrollView {
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = insets
        scrollView.documentView = TestDocumentView(frame: NSRect(x: 0, y: 0, width: 200, height: documentHeight), isFlipped: isFlipped)
        scrollView.tile()
        scrollView.layoutSubtreeIfNeeded()
        return scrollView
    }
}

private final class TestDocumentView: NSView {
    private let flips: Bool

    override var isFlipped: Bool {
        flips
    }

    init(frame: NSRect, isFlipped: Bool) {
        flips = isFlipped
        super.init(frame: frame)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }
}
