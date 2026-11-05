import AppKit
import CoreText
import ReqlingKit

/// Selecting text: points to bytes, words and lines around a byte, and copying.
extension CodeViewerView {
    /// The character boundary nearest `point`, in the document view's coordinates.
    func byteOffset(at point: NSPoint) -> Int {
        guard let layout = wrapLayout, let document else {
            return 0
        }
        if point.y < CodeViewerMetrics.verticalInset {
            return 0
        }
        if point.y >= top(ofRow: layout.rowCount) {
            return document.length
        }
        let rendered = renderedRow(row(atY: point.y), in: layout)
        let index = CTLineGetStringIndexForPosition(rendered.line, CGPoint(x: point.x - textInset, y: 0))
        return index == kCFNotFound ? rendered.bytes.lowerBound : rendered.map.byte(atUTF16: index)
    }

    /// Starts a selection at `point`: a caret, the word there on a double-click, the line on a triple-click, or an
    /// extension of the current selection with Shift.
    func beginSelection(at point: NSPoint, clickCount: Int, extending: Bool) {
        let offset = byteOffset(at: point)
        if extending, selection != nil {
            extendSelection(to: offset)
            return
        }
        switch clickCount {
        case 2:
            selection = word(around: offset)
        case 3...:
            selection = line(around: offset)
        default:
            selection = offset..<offset
        }
        selectionAnchor = selection?.lowerBound ?? offset
    }

    func extendSelection(to offset: Int) {
        selection = min(selectionAnchor, offset)..<max(selectionAnchor, offset)
    }

    func selectAllText() {
        guard let document else {
            return
        }
        selection = 0..<document.length
        selectionAnchor = 0
    }

    var hasSelection: Bool {
        selection.map { !$0.isEmpty } ?? false
    }

    /// The whole selection, which can be the whole body; build it only to copy.
    var selectedText: String? {
        guard let document, let selection, !selection.isEmpty else {
            return nil
        }
        return document.text(in: selection)
    }

    /// The selection's first 64 KB, for VoiceOver, which asks often.
    var selectedTextPrefix: String? {
        guard let document, let selection, !selection.isEmpty else {
            return nil
        }
        var end = min(selection.upperBound, selection.lowerBound + 65_536)
        document.withBytes { bytes in
            // Back off to a character boundary.
            while end > selection.lowerBound, end < document.length, bytes[end] & 0xC0 == 0x80 {
                end -= 1
            }
        }
        return document.text(in: selection.lowerBound..<end)
    }

    /// The text of the rows in view, one per line, for VoiceOver.
    var visibleText: String {
        guard let layout = wrapLayout, let document, layout.rowCount > 0 else {
            return ""
        }
        let visible = scrollView.contentView.bounds
        return (row(atY: visible.minY)...row(atY: visible.maxY))
            .map { row in
                let text = document.text(in: layout.byteRange(ofRow: row))
                // A diff's markers are only drawn, so VoiceOver hears which lines were added or removed from here.
                let position = layout.position(ofRow: row)
                guard position.chunk == 0, let style = diffStyle(ofLine: position.line) else {
                    return text
                }
                return switch style.kind {
                case .added: "Added: " + text
                case .removed: "Removed: " + text
                case .context, .omitted: text
                }
            }
            .joined(separator: "\n")
    }

    func copySelection() {
        guard let text = selectedText else {
            NSSound.beep()
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// The run of word characters (letters, digits, `_`, and anything outside ASCII) around `offset`, or the single
    /// character there when it isn't one.
    private func word(around offset: Int) -> Range<Int> {
        guard let document else {
            return offset..<offset
        }
        let line = document.byteRange(ofLine: document.line(containing: offset))
        return document.withBytes { bytes in
            func isWord(_ index: Int) -> Bool {
                let byte = bytes[index]
                return byte >= 0x80 || byte == UInt8(ascii: "_") || (byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9"))
                    || (byte | 0x20 >= UInt8(ascii: "a") && byte | 0x20 <= UInt8(ascii: "z"))
            }
            guard offset < line.upperBound else {
                return offset..<offset
            }
            guard isWord(offset) else {
                // One character; a multi-byte one runs through its continuation bytes.
                var end = offset + 1
                while end < line.upperBound, bytes[end] & 0xC0 == 0x80 {
                    end += 1
                }
                return offset..<end
            }
            var start = offset
            while start > line.lowerBound, isWord(start - 1) {
                start -= 1
            }
            var end = offset
            while end < line.upperBound, isWord(end) {
                end += 1
            }
            return start..<end
        }
    }

    /// The line holding `offset`, with its line break.
    private func line(around offset: Int) -> Range<Int> {
        guard let document else {
            return offset..<offset
        }
        let line = document.line(containing: offset)
        let start = document.byteRange(ofLine: line).lowerBound
        let end = line + 1 < document.lineCount ? document.byteRange(ofLine: line + 1).lowerBound : document.length
        return start..<end
    }
}
