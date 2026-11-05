import AppKit
import CoreText
import ReqlingKit

/// One row as drawn: its bytes, the line CoreText typeset from them, and how the two index into each other.
struct CodeViewerRow {
    let bytes: Range<Int>
    /// The text as shown, kept to typeset it again in another color.
    let text: String
    /// The row ends its line, so a selection running past it covers the line break.
    let endsLine: Bool
    let line: CTLine
    let map: CodeViewerRowMap
}

/// How a row's bytes and its displayed text index into each other. A tab shows as spaces and a control character as
/// its control picture, so the two drift apart.
struct CodeViewerRowMap {
    let bytes: Range<Int>
    /// Per character shown, in order: where it starts in the displayed text (UTF-16) and in the bytes.
    let utf16Starts: [Int]
    let byteStarts: [Int]
    let utf16Length: Int

    /// The displayed text's index for a byte at a character boundary in this row.
    func utf16Index(ofByte offset: Int) -> Int {
        guard offset < bytes.upperBound else {
            return utf16Length
        }
        let index = Self.partition(byteStarts) { $0 < offset }
        return index < utf16Starts.count ? utf16Starts[index] : utf16Length
    }

    /// The byte where the character at a displayed-text index starts, or the row's end past the last.
    func byte(atUTF16 index: Int) -> Int {
        guard index < utf16Length else {
            return bytes.upperBound
        }
        let position = Self.partition(utf16Starts) { $0 <= index } - 1
        return position >= 0 ? byteStarts[position] : bytes.lowerBound
    }

    private static func partition(_ values: [Int], _ isBefore: (Int) -> Bool) -> Int {
        var low = 0
        var high = values.count
        while low < high {
            let middle = (low + high) / 2
            if isBefore(values[middle]) {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return low
    }
}

/// The syntax palette as `CGColor`s for one appearance; rows are typeset with these, so an appearance change
/// rebuilds them.
struct CodeViewerPalette {
    let base: CGColor
    let roles: [SyntaxRole: CGColor]
}

extension CodeViewerView {
    /// Draws the rows the clip view shows into the canvas, whose origin is the clip view's.
    func drawRows(in context: CGContext, size: CGSize) {
        guard let layout = wrapLayout, layout.rowCount > 0 else {
            return
        }
        let visible = scrollView.contentView.bounds
        let first = row(atY: visible.minY)
        let last = row(atY: visible.maxY)
        if rowCache.count > 2_000 {
            rowCache = [:]
        }
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        for row in first...last {
            let rendered = renderedRow(row, in: layout)
            let top = top(ofRow: row) - visible.minY
            let position = layout.position(ofRow: row)
            let style = diffStyle(ofLine: position.line)
            if let style {
                drawDiffBackground(style, top: top, width: size.width, in: context)
            }
            drawHighlights(for: rendered, top: top, width: size.width, in: context)
            context.textPosition = CGPoint(x: textInset, y: top + metrics.baseline)
            CTLineDraw(rendered.line, context)
            drawCurrentMatchText(in: rendered, top: top, in: context)
            if let style, position.chunk == 0 {
                drawDiffGutter(style, top: top, in: context)
            }
        }
    }

    func renderedRow(_ row: Int, in layout: WrapLayout) -> CodeViewerRow {
        if let cached = rowCache[row] {
            return cached
        }
        let rendered = buildRow(row, in: layout)
        rowCache[row] = rendered
        return rendered
    }

    private func buildRow(_ row: Int, in layout: WrapLayout) -> CodeViewerRow {
        guard let document, let highlighter else {
            let empty = CodeViewerRowMap(bytes: 0..<0, utf16Starts: [], byteStarts: [], utf16Length: 0)
            return CodeViewerRow(bytes: 0..<0, text: "", endsLine: true, line: CTLineCreateWithAttributedString(NSAttributedString()), map: empty)
        }
        let range = layout.byteRange(ofRow: row)
        let position = layout.position(ofRow: row)
        let (text, map) = Self.displayText(of: document, range: range, line: position.line)
        let palette = palette()
        let colorKey = NSAttributedString.Key(kCTForegroundColorAttributeName as String)
        // An omitted-lines row is a note, not text the body holds, so it takes no syntax colors.
        let isNote = diffStyle(ofLine: position.line)?.isOmitted == true
        let base = isNote ? diffPalette().note : palette.base
        let attributed = NSMutableAttributedString(string: text, attributes: [.font: metrics.font, colorKey: base])
        for token in highlighter.tokens(in: range, line: position.line) where !isNote {
            let start = map.utf16Index(ofByte: token.range.lowerBound)
            let end = map.utf16Index(ofByte: token.range.upperBound)
            if end > start, let color = palette.roles[token.role] {
                attributed.addAttribute(colorKey, value: color, range: NSRange(location: start, length: end - start))
            }
        }
        let endsLine = position.chunk == layout.rows(ofLine: position.line) - 1
        return CodeViewerRow(bytes: range, text: text, endsLine: endsLine, line: CTLineCreateWithAttributedString(attributed), map: map)
    }

    /// A row's text as shown, with how it maps back to the bytes.
    private static func displayText(of document: TextDocument, range: Range<Int>, line: Int) -> (String, CodeViewerRowMap) {
        var column = document.column(ofByte: range.lowerBound, line: line)
        var text = ""
        var utf16Starts: [Int] = []
        var byteStarts: [Int] = []
        var utf16Length = 0
        var offset = range.lowerBound
        for scalar in document.text(in: range).unicodeScalars {
            utf16Starts.append(utf16Length)
            byteStarts.append(offset)
            let shown = displayed(scalar, column: column)
            text.append(shown)
            utf16Length += shown.utf16.count
            column += scalar == "\t" ? shown.count : 1
            offset += scalar.utf8.count
        }
        return (text, CodeViewerRowMap(bytes: range, utf16Starts: utf16Starts, byteStarts: byteStarts, utf16Length: utf16Length))
    }

    /// What a character shows as: a tab as spaces to the next tab stop, a control character as its control picture
    /// (␀, ␍), anything else as itself.
    private static func displayed(_ scalar: Unicode.Scalar, column: Int) -> String {
        switch scalar.value {
        case 0x09:
            String(repeating: " ", count: 4 - column % 4)
        case 0x00..<0x20:
            String(Unicode.Scalar(0x2400 + scalar.value) ?? scalar)
        case 0x7F:
            "\u{2421}"
        default:
            String(scalar)
        }
    }

    private func palette() -> CodeViewerPalette {
        if let resolvedPalette {
            return resolvedPalette
        }
        var palette = CodeViewerPalette(base: CGColor(gray: 0, alpha: 1), roles: [:])
        effectiveAppearance.performAsCurrentDrawingAppearance {
            palette = CodeViewerPalette(
                base: SyntaxPalette.base.cgColor,
                roles: Dictionary(uniqueKeysWithValues: SyntaxRole.allCases.map { ($0, SyntaxPalette.color(for: $0).cgColor) })
            )
        }
        resolvedPalette = palette
        return palette
    }

    /// Fills behind the row: the selection, then search matches over it, so the current match, which the search also
    /// selects, keeps its full find highlight.
    private func drawHighlights(for row: CodeViewerRow, top: CGFloat, width: CGFloat, in context: CGContext) {
        drawSelection(for: row, top: top, width: width, in: context)
        for match in matches(overlapping: row.bytes) {
            let color = match == currentMatch ? NSColor.findHighlightColor : NSColor.findHighlightColor.withAlphaComponent(0.35)
            fill(match, in: row, at: top, color: color, in: context)
        }
    }

    /// Redraws the current match's characters in black over its find highlight, as the system's find indicator does;
    /// the syntax colors, light in dark mode, wash out on yellow.
    private func drawCurrentMatchText(in row: CodeViewerRow, top: CGFloat, in context: CGContext) {
        guard let currentMatch, currentMatch.lowerBound < row.bytes.upperBound, currentMatch.upperBound > row.bytes.lowerBound else {
            return
        }
        let start = row.map.utf16Index(ofByte: max(currentMatch.lowerBound, row.bytes.lowerBound))
        let end = row.map.utf16Index(ofByte: min(currentMatch.upperBound, row.bytes.upperBound))
        let startX = textInset + CTLineGetOffsetForStringIndex(row.line, start, nil)
        let endX = textInset + CTLineGetOffsetForStringIndex(row.line, end, nil)
        let black = NSAttributedString(string: row.text, attributes: [
            .font: metrics.font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)
        ])
        context.saveGState()
        context.clip(to: CGRect(x: startX, y: top, width: endX - startX, height: metrics.rowHeight))
        context.textPosition = CGPoint(x: textInset, y: top + metrics.baseline)
        CTLineDraw(CTLineCreateWithAttributedString(black), context)
        context.restoreGState()
    }

    private func drawSelection(for row: CodeViewerRow, top: CGFloat, width: CGFloat, in context: CGContext) {
        guard let selection, !selection.isEmpty, selection.upperBound > row.bytes.lowerBound else {
            return
        }
        // A selection running past the row fills to the edge: past the line break on the line's last row, or on to the
        // next row of a wrapped line, which a selection only starting there doesn't reach.
        let runsPast = selection.upperBound > row.bytes.upperBound
        let reaches = row.endsLine ? selection.lowerBound <= row.bytes.upperBound : selection.lowerBound < row.bytes.upperBound
        guard reaches else {
            return
        }
        let isActive = window?.firstResponder === documentView && window?.isKeyWindow == true
        let color = isActive ? accent.withAlphaComponent(0.3) : NSColor.unemphasizedSelectedTextBackgroundColor
        fill(selection, in: row, at: top, toEdge: runsPast ? width : nil, color: color, in: context)
    }

    /// Fills behind the part of `span` in `row`, drawn `top` points down the canvas, or from its start to `edge` when
    /// given.
    private func fill(
        _ span: Range<Int>,
        in row: CodeViewerRow,
        at top: CGFloat,
        toEdge edge: CGFloat? = nil,
        color: NSColor,
        in context: CGContext
    ) {
        let start = row.map.utf16Index(ofByte: max(span.lowerBound, row.bytes.lowerBound))
        let startX = textInset + CTLineGetOffsetForStringIndex(row.line, start, nil)
        let endX = edge ?? textInset
            + CTLineGetOffsetForStringIndex(row.line, row.map.utf16Index(ofByte: min(span.upperBound, row.bytes.upperBound)), nil)
        guard endX > startX else {
            return
        }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            context.setFillColor(color.cgColor)
        }
        context.fill(CGRect(x: startX, y: top, width: endX - startX, height: metrics.rowHeight))
    }

    /// The search matches overlapping `range`, from the sorted list.
    private func matches(overlapping range: Range<Int>) -> ArraySlice<Range<Int>> {
        var low = 0
        var high = matches.count
        while low < high {
            let middle = (low + high) / 2
            if matches[middle].upperBound <= range.lowerBound {
                low = middle + 1
            } else {
                high = middle
            }
        }
        var end = low
        while end < matches.count, matches[end].lowerBound < range.upperBound {
            end += 1
        }
        return matches[low..<end]
    }
}
