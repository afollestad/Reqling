import AppKit
import ReqlingKit
import XCTest

@testable import Reqling

/// Drives `CodeViewerView` in an offscreen window.
@MainActor
final class CodeViewerTests: XCTestCase {
    private var window: NSWindow!
    private var viewer: CodeViewerView!

    override func setUp() async throws {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        viewer = CodeViewerView(frame: window.contentLayoutRect)
        window.contentView = viewer
    }

    override func tearDown() async throws {
        window.close()
        window = nil
        viewer = nil
    }

    private func show(_ text: String, _ language: SyntaxLanguage = .plainText) throws {
        viewer.setDocument(try XCTUnwrap(try TextDocument.make(Data(text.utf8), language: language)))
        viewer.layoutSubtreeIfNeeded()
    }

    /// A point in the document view at the middle of `row`, `columns` characters in.
    private func point(row: Int, columns: Double) -> NSPoint {
        NSPoint(
            x: CodeViewerMetrics.horizontalInset + viewer.metrics.characterWidth * columns,
            y: viewer.top(ofRow: row) + viewer.metrics.rowHeight / 2
        )
    }

    func testSizesTheDocumentToItsRowsAndScrollsNatively() throws {
        let lines = (0..<10_000).map { "line \($0)" }.joined(separator: "\n")
        try show(lines)

        let height = viewer.documentView.frame.height
        XCTAssertEqual(height, 2 * CodeViewerMetrics.verticalInset + 10_000 * viewer.metrics.rowHeight, accuracy: 0.5)

        viewer.scrollToReveal(try XCTUnwrap(lines.range(of: "line 9000")).lowerBound.utf16Offset(in: lines))
        XCTAssertTrue(viewer.visibleText.contains("line 9000"))
        XCTAssertFalse(viewer.visibleText.contains("line 10\n"))
    }

    func testClicksDragsAndDoubleClicksSelectByCharacter() throws {
        try show("hello wörld\nsecond line")

        viewer.beginSelection(at: point(row: 0, columns: 1.2), clickCount: 1, extending: false)
        viewer.extendSelection(to: viewer.byteOffset(at: point(row: 1, columns: 6.2)))
        XCTAssertEqual(viewer.selectedText, "ello wörld\nsecond")

        viewer.beginSelection(at: point(row: 0, columns: 8.5), clickCount: 2, extending: false)
        XCTAssertEqual(viewer.selectedText, "wörld")

        viewer.beginSelection(at: point(row: 1, columns: 2), clickCount: 3, extending: false)
        XCTAssertEqual(viewer.selectedText, "second line")

        viewer.selectAllText()
        viewer.copySelection()
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "hello wörld\nsecond line")
    }

    func testWrapsLongLinesToTheWidthAndKeepsSelectingAcrossRows() throws {
        let long = String(repeating: "abcdefghij", count: 30)
        try show(long)
        let rows = try XCTUnwrap(viewer.wrapLayout).rowCount
        XCTAssertGreaterThan(rows, 1)

        viewer.beginSelection(at: point(row: 0, columns: 0), clickCount: 1, extending: false)
        viewer.extendSelection(to: viewer.byteOffset(at: point(row: 1, columns: 0)))
        XCTAssertEqual(viewer.selectedText?.count, try XCTUnwrap(viewer.wrapLayout).columns)
    }

    func testColorsTheRowsInViewFromTheirTokens() throws {
        try show(#"{"key": [1, true]}"#, .json)
        let layout = try XCTUnwrap(viewer.wrapLayout)
        let row = viewer.renderedRow(0, in: layout)
        let runs = CTLineGetGlyphRuns(row.line) as? [CTRun] ?? []
        let colors = Set(runs.compactMap { run in
            (CTRunGetAttributes(run) as NSDictionary)[kCTForegroundColorAttributeName as String].map { $0 as! CGColor }
        })
        XCTAssertGreaterThanOrEqual(colors.count, 4, "key, symbols, number, and keyword each take a color")
    }

    func testRevealsAndSelectsTheCurrentMatch() throws {
        let lines = (0..<5_000).map { $0 == 4_000 ? "the needle" : "hay \($0)" }.joined(separator: "\n")
        try show(lines)
        let document = try XCTUnwrap(viewer.document)
        let matches = try document.find("needle").matches

        viewer.setMatches(matches, current: matches.first)

        XCTAssertEqual(viewer.selectedText, "needle")
        XCTAssertTrue(viewer.visibleText.contains("the needle"))
    }

    func testTheFindMenuReachesTheFocusedViewer() throws {
        try show("text")
        var received: [NSTextFinder.Action] = []
        viewer.onFind = { received.append($0) }
        XCTAssertTrue(window.makeFirstResponder(viewer.documentView))

        XCTAssertTrue(InPlaceFind.perform(.nextMatch, in: window))

        XCTAssertEqual(received, [.nextMatch])
    }

    /// A wheel scroll moves the clip view without redrawing the canvas behind it, whose layer only redraws when the
    /// viewer asks; layer-backed like every view in the app, since without layers AppKit would invalidate it anyway.
    func testWheelScrollingRedrawsTheCanvas() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let viewer = CodeViewerView(frame: window.contentLayoutRect)
        viewer.wantsLayer = true
        window.contentView = viewer
        let text = (0..<2_000).map { "line \($0)" }.joined(separator: "\n")
        viewer.setDocument(try XCTUnwrap(try TextDocument.make(Data(text.utf8), language: .plainText)))
        window.displayIfNeeded()
        let canvas = try XCTUnwrap(viewer.canvas.layer)
        canvas.displayIfNeeded()
        XCTAssertFalse(canvas.needsDisplay())
        let wheel = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -300, wheel2: 0, wheel3: 0))

        viewer.scrollView.scrollWheel(with: try XCTUnwrap(NSEvent(cgEvent: wheel)))

        XCTAssertGreaterThan(viewer.scrollView.contentView.bounds.minY, 0, "the scroll view moved")
        XCTAssertTrue(canvas.needsDisplay(), "the canvas redraws the rows now in view")
    }
}
