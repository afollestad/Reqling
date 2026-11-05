import AppKit
import CoreText
import ReqlingKit

/// Drawing a `DiffDocument` in the viewer, after Alveary's diff rows: a gutter of old and new line numbers and a `+` or
/// `−`, a hairline, then the text. Added and removed lines wash the whole row green or red, a little stronger behind
/// the gutter, and an omitted-lines row reads as a muted note. The gutter is drawn, not text, so selecting and copying
/// see only the lines themselves.
extension CodeViewerView {
    func diffStyle(ofLine line: Int) -> DiffLineStyle? {
        guard let diff, diff.indices.contains(line) else {
            return nil
        }
        return diff[line]
    }

    /// Fills behind the row and its gutter, under any selection or find highlight.
    func drawDiffBackground(_ style: DiffLineStyle, top: CGFloat, width: CGFloat, in context: CGContext) {
        guard let gutter = diffGutter else {
            return
        }
        let palette = diffPalette()
        let wash: (row: CGColor?, gutter: CGColor) = switch style.kind {
        case .added: (palette.addedRow, palette.addedGutter)
        case .removed: (palette.removedRow, palette.removedGutter)
        case .omitted: (palette.omittedRow, palette.contextGutter)
        case .context: (nil, palette.contextGutter)
        }
        if let row = wash.row {
            context.setFillColor(row)
            context.fill(CGRect(x: 0, y: top, width: width, height: metrics.rowHeight))
        }
        context.setFillColor(wash.gutter)
        context.fill(CGRect(x: 0, y: top, width: gutter.width - 1, height: metrics.rowHeight))
        context.setFillColor(palette.separator)
        context.fill(CGRect(x: gutter.width - 1, y: top, width: 1, height: metrics.rowHeight))
    }

    /// The line numbers and marker, on a line's first row only, so a wrapped line numbers once.
    func drawDiffGutter(_ style: DiffLineStyle, top: CGFloat, in context: CGContext) {
        guard let gutter = diffGutter else {
            return
        }
        let palette = diffPalette()
        let numbers: (old: String, new: String) = if case .omitted = style.kind {
            ("⋯", "⋯")
        } else {
            (style.oldNumber.map(String.init) ?? "", style.newNumber.map(String.init) ?? "")
        }
        let marker: (text: String, color: CGColor) = switch style.kind {
        case .added: ("+", palette.addedMarker)
        case .removed: ("−", palette.removedMarker)
        case .context, .omitted: ("", palette.number)
        }
        drawGutterText(numbers.old, trailingAt: gutter.numberWidth - DiffGutterLayout.padding, top: top, color: palette.number, in: context)
        drawGutterText(numbers.new, trailingAt: 2 * gutter.numberWidth - DiffGutterLayout.padding, top: top, color: palette.number, in: context)
        drawGutterText(marker.text, trailingAt: gutter.width - 1 - DiffGutterLayout.padding, top: top, color: marker.color, in: context)
    }

    func diffPalette() -> DiffPalette {
        if let resolvedDiffPalette {
            return resolvedDiffPalette
        }
        var palette: DiffPalette?
        effectiveAppearance.performAsCurrentDrawingAppearance {
            palette = DiffPalette()
        }
        let resolved = palette ?? DiffPalette()
        resolvedDiffPalette = resolved
        return resolved
    }

    private func drawGutterText(_ text: String, trailingAt trailing: CGFloat, top: CGFloat, color: CGColor, in context: CGContext) {
        guard !text.isEmpty, let gutter = diffGutter else {
            return
        }
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
            .font: gutter.font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color
        ]))
        let width = CTLineGetTypographicBounds(line, nil, nil, nil)
        context.textPosition = CGPoint(x: trailing - width, y: top + metrics.baseline)
        CTLineDraw(line, context)
    }
}

/// The gutter's columns, sized for the widest line number: old, new, then the marker, then a 1-point hairline.
struct DiffGutterLayout {
    static let padding: CGFloat = 6

    let font: NSFont
    let numberWidth: CGFloat
    let width: CGFloat

    init(lines: [DiffLineStyle]) {
        font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        let widest = lines.reduce(0) { max($0, $1.oldNumber ?? 0, $1.newNumber ?? 0) }
        let digits = max(2, String(widest).count)
        let digitWidth = ("0" as NSString).size(withAttributes: [.font: font]).width
        numberWidth = ceil(CGFloat(digits) * digitWidth) + 2 * Self.padding
        let markerWidth = ceil(digitWidth) + 2 * Self.padding
        width = 2 * numberWidth + markerWidth + 1
    }
}

/// The diff's colors as `CGColor`s for one appearance. System colors at fixed opacities, as Alveary's are, so both
/// appearances read right.
struct DiffPalette {
    let addedRow: CGColor
    let addedGutter: CGColor
    let addedMarker: CGColor
    let removedRow: CGColor
    let removedGutter: CGColor
    let removedMarker: CGColor
    let contextGutter: CGColor
    let omittedRow: CGColor
    let separator: CGColor
    let number: CGColor
    /// An omitted-lines row's text.
    let note: CGColor

    /// Resolves against the current drawing appearance; call it inside `performAsCurrentDrawingAppearance`.
    init() {
        addedRow = NSColor.systemGreen.withAlphaComponent(0.12).cgColor
        addedGutter = NSColor.systemGreen.withAlphaComponent(0.18).cgColor
        addedMarker = NSColor.systemGreen.cgColor
        removedRow = NSColor.systemRed.withAlphaComponent(0.12).cgColor
        removedGutter = NSColor.systemRed.withAlphaComponent(0.18).cgColor
        removedMarker = NSColor.systemRed.cgColor
        contextGutter = NSColor.labelColor.withAlphaComponent(0.04).cgColor
        omittedRow = NSColor.labelColor.withAlphaComponent(0.03).cgColor
        separator = NSColor.labelColor.withAlphaComponent(0.06).cgColor
        number = NSColor.secondaryLabelColor.cgColor
        note = NSColor.secondaryLabelColor.cgColor
    }
}

extension DiffLineStyle {
    var isOmitted: Bool {
        if case .omitted = kind {
            return true
        }
        return false
    }
}
