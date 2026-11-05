import AppKit

/// Underlines for the problems `CodeEditor` hands down.
///
/// A set is adopted only when it was found in the text the view holds now. Between sets, each change moves the shown
/// underlines with it: one before the change keeps its place, one after shifts, and one the change touched is dropped,
/// since it no longer describes what is there. One that would cross a `{{variable}}` pill is left out.
///
/// They are drawn by `draw(_:)`, beneath the text, rather than as rendering attributes like the syntax colors:
/// TextKit 2 ignores `.underlineStyle` as a rendering attribute, and as a storage attribute it would enter the undo
/// stack and bleed into typed text.
extension CodeTextView {
    /// What is underlined now, and the text it describes.
    struct ShownDiagnostics {
        var text = ""
        var items: [CodeDiagnostic] = []
    }

    /// Shows the set from `CodeEditor` when it was found in this text, which may arrive after the set did (an undo
    /// back to it); otherwise moves the shown underlines through whatever changed since. Called from
    /// `refreshHighlighting()` after every change.
    func applyDiagnostics() {
        if diagnostics.text == string {
            shownDiagnostics = ShownDiagnostics(text: string, items: diagnostics.items)
        } else if shownDiagnostics.text != string {
            let edit = TextEdit.minimal(from: shownDiagnostics.text as NSString, to: string as NSString)
            shownDiagnostics.items = shownDiagnostics.items.compactMap { $0.moved(through: edit) }
            shownDiagnostics.text = string
        }
        needsDisplay = true
    }

    /// Draws a dotted line under each shown diagnostic in `dirtyRect`, in its severity's color.
    func drawDiagnostics(in dirtyRect: NSRect) {
        let length = (string as NSString).length
        for diagnostic in shownDiagnostics.items where NSMaxRange(diagnostic.range) <= length {
            guard !templateTokens.contains(where: { NSIntersectionRange($0.utf16Range, diagnostic.range).length > 0 }) else {
                continue
            }
            Self.underlineColor(diagnostic.severity).setStroke()
            for rect in segmentRects(for: diagnostic.range) where rect.intersects(dirtyRect.insetBy(dx: 0, dy: -4)) {
                let path = NSBezierPath()
                let baseline = isFlipped ? rect.maxY - 1 : rect.minY + 1
                path.move(to: NSPoint(x: rect.minX, y: baseline))
                path.line(to: NSPoint(x: max(rect.maxX, rect.minX + 4), y: baseline))
                path.lineWidth = 2
                path.setLineDash([2, 2], count: 2, phase: 0)
                path.stroke()
            }
        }
    }

    /// The shown diagnostics touching `offset`, for the hover card.
    func diagnostics(at offset: Int) -> [CodeDiagnostic] {
        shownDiagnostics.items.filter { NSLocationInRange(offset, $0.range) || NSMaxRange($0.range) == offset }
    }

    static func underlineColor(_ severity: CodeDiagnostic.Severity) -> NSColor {
        severity == .error ? .systemRed : .systemOrange
    }
}

extension CodeDiagnostic {
    /// Where this lands after `edit`: in place before it, shifted after it, and gone when the edit touched it.
    func moved(through edit: TextEdit) -> CodeDiagnostic? {
        if NSMaxRange(range) <= edit.range.location {
            return self
        }
        guard range.location >= NSMaxRange(edit.range) else {
            return nil
        }
        let delta = (edit.replacement as NSString).length - edit.range.length
        return CodeDiagnostic(range: NSRange(location: range.location + delta, length: range.length), message: message, severity: severity)
    }
}
