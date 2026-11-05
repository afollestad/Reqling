import AppKit
import ReqlingKit
import XCTest

@testable import Reqling

/// Underlines for diagnostics: drawn beneath their ranges, shown only for the text they were found in, and moved
/// through later edits.
extension CodeTextViewTests {
    func testADiagnosticDrawsAnUnderlineBeneathItsRange() throws {
        let textView = makeTextView(isSingleLine: false, text: "query { nmae }")
        let window = focus(textView)
        textView.frame = NSRect(x: 0, y: 0, width: 300, height: 60)
        let range = NSRange(location: 8, length: 4)
        let plain = try redPixels(in: textView, under: range)

        textView.diagnostics = CodeDiagnosticSet(text: textView.string, items: [CodeDiagnostic(range: range, message: "Unknown", severity: .error)])

        XCTAssertEqual(plain, 0)
        XCTAssertGreaterThan(try redPixels(in: textView, under: range), 0, "the underline is drawn")
        XCTAssertEqual(try redPixels(in: textView, under: NSRange(location: 0, length: 5)), 0, "only under its range")
        window.close()
    }

    func testASetFoundInAnotherVersionOfTheTextWaits() {
        let textView = makeTextView(isSingleLine: false, text: "{ nmae }")
        let item = CodeDiagnostic(range: NSRange(location: 2, length: 4), message: "m", severity: .error)
        let stale = CodeDiagnosticSet(text: "{ nmae x }", items: [item])

        textView.diagnostics = stale

        XCTAssertEqual(underlined(in: textView), [])
        textView.replaceText(with: "{ nmae x }")
        textView.diagnostics = CodeDiagnosticSet(text: textView.string, items: stale.items)
        XCTAssertEqual(underlined(in: textView), [NSRange(location: 2, length: 4)])
    }

    func testUnderlinesMoveWithEditsAndLeaveWhatTheyTouched() {
        let textView = makeTextView(isSingleLine: false, text: "{ ab cd }")
        textView.diagnostics = CodeDiagnosticSet(text: textView.string, items: [
            CodeDiagnostic(range: NSRange(location: 2, length: 2), message: "ab", severity: .error),
            CodeDiagnostic(range: NSRange(location: 5, length: 2), message: "cd", severity: .warning)
        ])

        textView.insertText("xx ", replacementRange: NSRange(location: 2, length: 0))
        XCTAssertEqual(underlined(in: textView), [NSRange(location: 5, length: 2), NSRange(location: 8, length: 2)])

        textView.insertText("Z", replacementRange: NSRange(location: 6, length: 0))
        XCTAssertEqual(underlined(in: textView), [NSRange(location: 9, length: 2)], "the edited one goes")

        textView.diagnostics = .none
        XCTAssertEqual(underlined(in: textView), [NSRange(location: 9, length: 2)], "an empty set for other text waits too")
        textView.diagnostics = CodeDiagnosticSet(text: textView.string, items: [])
        XCTAssertEqual(underlined(in: textView), [])
    }

    func testNoUnderlineCrossesAVariablePill() {
        let textView = makeTextView(isSingleLine: false, text: "{ node(id: {{token}}) }")
        textView.diagnostics = CodeDiagnosticSet(text: textView.string, items: [
            CodeDiagnostic(range: NSRange(location: 11, length: 9), message: "masked", severity: .error),
            CodeDiagnostic(range: NSRange(location: 2, length: 4), message: "node", severity: .error)
        ])

        XCTAssertEqual(underlined(in: textView), [NSRange(location: 2, length: 4)])
        XCTAssertEqual(textView.diagnostics(at: 4).map(\.message), ["node"])
    }

    func testRevealSelectsAndFocusesTheRange() {
        let textView = makeTextView(isSingleLine: false, text: "{ a b }")
        let other = makeTextView(isSingleLine: false, text: "")
        let window = focus(other, alongside: textView)
        let handle = CodeEditorHandle()
        handle.textView = textView

        handle.reveal(NSRange(location: 4, length: 1))

        XCTAssertTrue(window.firstResponder === textView)
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 4, length: 1))
        window.close()
    }

    // MARK: - Support

    /// The ranges underlined now.
    private func underlined(in textView: CodeTextView) -> [NSRange] {
        let length = (textView.string as NSString).length
        return textView.shownDiagnostics.items
            .filter { item in
                NSMaxRange(item.range) <= length && !textView.templateTokens.contains { NSIntersectionRange($0.utf16Range, item.range).length > 0 }
            }
            .map(\.range)
    }

    /// How many clearly red pixels the view draws within the rectangles `range` occupies.
    private func redPixels(in textView: CodeTextView, under range: NSRange) throws -> Int {
        textView.layoutSubtreeIfNeeded()
        if let layoutManager = textView.textLayoutManager, let content = layoutManager.textContentManager {
            layoutManager.ensureLayout(for: content.documentRange)
        }
        let rep = try XCTUnwrap(textView.bitmapImageRepForCachingDisplay(in: textView.bounds))
        textView.cacheDisplay(in: textView.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / textView.bounds.width
        var count = 0
        for rect in textView.segmentRects(for: range) {
            let expanded = rect.insetBy(dx: 0, dy: -3)
            for row in Int(expanded.minY * scale)..<Int(expanded.maxY * scale) where row >= 0 && row < rep.pixelsHigh {
                for column in Int(expanded.minX * scale)..<Int(expanded.maxX * scale) where column >= 0 && column < rep.pixelsWide {
                    guard let color = rep.colorAt(x: column, y: row)?.usingColorSpace(.sRGB) else {
                        continue
                    }
                    if color.redComponent > 0.7, color.greenComponent < 0.45, color.blueComponent < 0.45, color.alphaComponent > 0.5 {
                        count += 1
                    }
                }
            }
        }
        return count
    }
}
